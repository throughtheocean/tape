import AVFoundation
import XCTest
@testable import TapeCore

final class MultitrackTests: XCTestCase {
    let n = 4800

    private func source(_ channels: [[Float]]) -> (UUID, MemorySource) {
        (UUID(), MemorySource(samples: channels))
    }

    private func render(_ list: EditList, frames: Int? = nil) -> [[Float]] {
        let count = frames ?? Int(list.length)
        let out = SampleBuffer(channelCount: list.channelCount, capacity: count)
        EditListRenderer(maxFrames: 1024).render(list, start: 0, frames: count, into: out)
        return (0..<list.channelCount).map { Array(UnsafeBufferPointer(start: out.channels[$0], count: count)) }
    }

    private func ramp(_ scale: Float, _ offset: Float = 0) -> [Float] {
        (0..<n).map { Float(sin(Double($0) * 0.031 + Double(offset))) * scale }
    }

    // MARK: Pan law

    /// Constant power with unity at centre: a centred mono region renders both channels at exactly the source level,
    /// a hard pan puts it +3 dB on one side, and power stays constant in between.
    func testMonoPanCentreIsUnityAndHardLeftIsPlusThreeDB() {
        let (id, src) = source([ramp(0.8)])
        let track = Track(name: "A")
        let region = Region(name: "r", trackId: track.id, sourceId: id, sourceIn: 0, sourceOut: Int64(n), position: 0)
        func out(_ pan: Double) -> [[Float]] {
            var t = TrackMix(track)
            t.pan = pan
            return render(EditList(regions: [region], sources: [id: src], channelCount: 2, tracks: [t]))
        }
        let centre = out(0)
        XCTAssertEqual(centre[0], src.samples[0], "centre is the source level, exactly")
        XCTAssertEqual(centre[1], src.samples[0], "centre is the source level, exactly")
        let left = out(-1)
        let g = Float(2.0.squareRoot())
        for i in 0..<n {
            XCTAssertEqual(left[0][i], src.samples[0][i] * g, accuracy: 1e-6)
            XCTAssertEqual(left[1][i], 0, accuracy: 1e-7)
        }
        let right = out(1)
        XCTAssertEqual(right[0].map(abs).max()!, 0, accuracy: 1e-7)
        for pan in [-0.7, -0.3, 0.2, 0.9] {
            let (l, r) = TrackMix.panGains(pan: pan, sourceChannels: 1)
            XCTAssertEqual(l * l + r * r, 2, accuracy: 1e-5, "constant power at pan \(pan)")
        }
    }

    func testStereoBalanceAttenuatesOneSide() {
        let (id, src) = source([ramp(0.5), ramp(0.4, 1)])
        var t = TrackMix(id: UUID())
        let region = Region(name: "r", trackId: t.id, sourceId: id, sourceIn: 0, sourceOut: Int64(n), position: 0)
        let centre = render(EditList(regions: [region], sources: [id: src], channelCount: 2, tracks: [t]))
        XCTAssertEqual(centre[0], src.samples[0])
        XCTAssertEqual(centre[1], src.samples[1])
        t.pan = 1
        let right = render(EditList(regions: [region], sources: [id: src], channelCount: 2, tracks: [t]))
        XCTAssertEqual(right[0].map(abs).max()!, 0, accuracy: 1e-7)
        XCTAssertEqual(right[1], src.samples[1])
        t.pan = -0.5
        let half = render(EditList(regions: [region], sources: [id: src], channelCount: 2, tracks: [t]))
        XCTAssertEqual(half[0], src.samples[0])
        XCTAssertEqual(half[1][100], src.samples[1][100] * Float(cos(0.25 * Double.pi)), accuracy: 1e-6)
    }

    // MARK: Sum, mute, solo

    private func twoTracks() -> (EditList, [Float], [Float]) {
        let a = ramp(0.3), b = ramp(0.25, 2)
        let (ia, sa) = source([a, a])
        let (ib, sb) = source([b, b])
        let ta = TrackMix(id: UUID(), gainDB: -2), tb = TrackMix(id: UUID(), gainDB: 1.5)
        let regions = [Region(name: "a", trackId: ta.id, sourceId: ia, sourceIn: 0, sourceOut: Int64(n), position: 0),
                       Region(name: "b", trackId: tb.id, sourceId: ib, sourceIn: 0, sourceOut: Int64(n), position: 0)]
        return (EditList(regions: regions, sources: [ia: sa, ib: sb], channelCount: 2, tracks: [ta, tb]), a, b)
    }

    func testTwoTracksSumThenMasterGain() {
        var (list, a, b) = twoTracks()
        let ga = Float(pow(10, -2.0 / 20)), gb = Float(pow(10, 1.5 / 20))
        let mix = render(list)
        for c in 0..<2 {
            for i in 0..<n { XCTAssertEqual(mix[c][i], a[i] * ga + b[i] * gb, accuracy: 1e-6) }
        }
        list.masterGainDB = -6
        let gm = Float(pow(10, -6.0 / 20))
        let mastered = render(list)
        for i in 0..<n { XCTAssertEqual(mastered[0][i], (a[i] * ga + b[i] * gb) * gm, accuracy: 1e-6) }
    }

    func testSoloSilencesOthersAndMuteWins() {
        var (list, _, b) = twoTracks()
        let gb = Float(pow(10, 1.5 / 20))
        list.tracks[1].solo = true
        let solo = render(list)
        for i in 0..<n { XCTAssertEqual(solo[0][i], b[i] * gb, accuracy: 1e-6) }
        list.tracks[1].mute = true
        XCTAssertEqual(render(list)[0].map(abs).max()!, 0)
        list.tracks[1].solo = false
        list.tracks[1].mute = false
        list.tracks[0].mute = true
        for (x, y) in zip(render(list)[1], solo[1]) { XCTAssertEqual(x, y, accuracy: 1e-6) }
    }

    /// "Only" plays the isolated track alone with its own gain and pan, even when muted or not soloed, and leaves
    /// the flags alone; an export of a list with the flag set equals one without it.
    func testOnlyIsolatesPlaybackButNotExport() throws {
        var (list, a, b) = twoTracks()
        let ga = Float(pow(10, -2.0 / 20)), gb = Float(pow(10, 1.5 / 20))
        list.tracks[0].solo = true
        list.tracks[1].mute = true
        let flags = list.tracks
        let only = list.isolating(list.tracks[1].id)
        let out = render(only)
        for i in 0..<n { XCTAssertEqual(out[0][i], b[i] * gb, accuracy: 1e-6) }
        XCTAssertEqual(only.tracks, flags)
        XCTAssertEqual(only.with(regions: only.regions).isolatedTrack, list.tracks[1].id, "previews keep the isolation")

        let dir = TestAudio.tempDirectory()
        let settings = ExportSettings(container: .caf, sampleFormat: .float32)
        func export(_ l: EditList, _ name: String) throws -> [[Float]] {
            let jobs = Exporter.jobs(list: l, scope: .mix, directory: dir, fileName: name, pattern: "", documentName: "",
                                     date: Date(), settings: settings)
            try Exporter.export(jobs, sessionRate: 48000, settings: settings)
            return try TestAudio.read(jobs[0].url)
        }
        let plain = try export(list, "plain"), isolated = try export(only, "only")
        XCTAssertEqual(plain, isolated)
        for i in 0..<n { XCTAssertEqual(plain[0][i], a[i] * ga, accuracy: 1e-6, "export follows solo on A") }
    }

    func testSilentGainIsSilence() {
        var (list, _, _) = twoTracks()
        list.tracks[0].gainDB = Track.silentDB
        list.tracks[1].gainDB = -200
        XCTAssertEqual(render(list)[0].map(abs).max()!, 0)
    }

    // MARK: Stems

    func testStemsEqualThePerTrackRenderOfTheMix() throws {
        var (list, _, _) = twoTracks()
        list.tracks[0].pan = -0.4
        list.tracks[1].solo = true
        list.masterGainDB = -3
        var third = TrackMix(id: UUID())
        third.mute = true
        list.tracks.append(third)
        let dir = TestAudio.tempDirectory()
        let names = Dictionary(uniqueKeysWithValues: list.tracks.enumerated().map { ($1.id, "T\($0 + 1)") })
        let settings = ExportSettings(container: .caf, sampleFormat: .float32)
        let jobs = Exporter.jobs(list: list, scope: .stems(list.tracks.map(\.id)), directory: dir, fileName: "",
                                 pattern: Exporter.defaultStemPattern, documentName: "Song", date: Date(), settings: settings,
                                 trackNames: names)
        XCTAssertEqual(jobs.map { $0.url.lastPathComponent }, ["Song-T1.caf", "Song-T2.caf"], "muted track has no stem")
        try Exporter.export(jobs, sessionRate: 48000, settings: settings)

        var sum = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        for (k, t) in list.tracks.prefix(2).enumerated() {
            let file = try TestAudio.read(jobs[k].url)
            let expected = render(list.stem(t.id))
            XCTAssertEqual(file[0].count, n)
            for c in 0..<2 {
                XCTAssertEqual(file[c], expected[c], "stem \(k) channel \(c)")
                for i in 0..<n { sum[c][i] += file[c][i] }
            }
        }
        // The stems through the master equal the mix when nothing is soloed.
        list.tracks[1].solo = false
        let mix = render(list)
        let gm = Float(pow(10, -3.0 / 20))
        for c in 0..<2 {
            for i in 0..<n { XCTAssertEqual(mix[c][i], sum[c][i] * gm, accuracy: 1e-6) }
        }
    }

    func testTrackTokenInRegionAndStemNames() {
        XCTAssertEqual(Exporter.fileName(pattern: "{name}-{track}-{region}", name: "Song", index: 1, region: "Take",
                                         track: "Bass", date: Date()), "Song-Bass-Take")
        let (list, _, _) = twoTracks()
        let names = [list.tracks[0].id: "Same", list.tracks[1].id: "Same"]
        let jobs = Exporter.jobs(list: list, scope: .eachRegion(list.regions.map(\.id)), directory: URL(fileURLWithPath: "/tmp"),
                                 fileName: "", pattern: "{track}", documentName: "", date: Date(), settings: ExportSettings(),
                                 trackNames: names)
        XCTAssertEqual(jobs.map { $0.url.lastPathComponent }, ["Same.wav", "Same 2.wav"])
    }

    // MARK: Model

    func testRegionMoveBetweenTracksChangesOnlyTrackId() {
        var p = Project(sessionRate: 48000, channelCount: 2)
        let t2 = EditOperations.addTrack(&p)
        let t3 = EditOperations.addTrack(&p)
        XCTAssertEqual(p.tracks.map(\.name), ["Track 1", "Track 2", "Track 3"])
        XCTAssertEqual(p.tracks.map(\.color), [0, 1, 2])
        let r = Region(name: "x", trackId: Track.firstID, sourceId: UUID(), sourceIn: 10, sourceOut: 900, position: 77, gainDB: -4,
                       fadeIn: Fade(length: 30, shape: .log, blend: 0.3), fadeOut: Fade(length: 50, shape: .exp))
        p.regions = [r]
        XCTAssertEqual(EditOperations.moveToTrack(&p, ids: [r.id], byLanes: 1), 1)
        var expected = r
        expected.trackId = t2
        XCTAssertEqual(p.regions, [expected])
        XCTAssertEqual(EditOperations.moveToTrack(&p, ids: [r.id], byLanes: 5), 1, "limited at the last track")
        XCTAssertEqual(p.regions[0].trackId, t3)
        XCTAssertEqual(EditOperations.moveToTrack(&p, ids: [r.id], byLanes: -9), -2)
        XCTAssertEqual(p.regions[0].trackId, Track.firstID)
    }

    func testTrackAddRemoveReorder() {
        var p = Project(sessionRate: 48000, channelCount: 2)
        let t2 = EditOperations.addTrack(&p)
        p.regions = [Region(name: "a", sourceId: UUID(), sourceIn: 0, sourceOut: 10, position: 0),
                     Region(name: "b", trackId: t2, sourceId: UUID(), sourceIn: 0, sourceOut: 10, position: 0)]
        EditOperations.moveTrack(&p, id: t2, to: 0)
        XCTAssertEqual(p.tracks.map(\.id), [t2, Track.firstID])
        EditOperations.removeTrack(&p, id: t2)
        XCTAssertEqual(p.tracks.map(\.id), [Track.firstID])
        XCTAssertEqual(p.regions.map(\.name), ["a"])
        EditOperations.removeTrack(&p, id: Track.firstID)
        XCTAssertEqual(p.tracks.count, 1, "the last track stays")
        EditOperations.updateTrack(&p, id: Track.firstID) { $0.gainDB = 40; $0.pan = -3 }
        XCTAssertEqual(p.tracks[0].gainDB, Track.maxGainDB)
        XCTAssertEqual(p.tracks[0].pan, -1)
    }

    func testRippleDeleteStaysOnItsTrack() {
        var p = Project(sessionRate: 48000, channelCount: 1)
        let t2 = EditOperations.addTrack(&p)
        let s = UUID()
        let a = Region(name: "a", sourceId: s, sourceIn: 0, sourceOut: 100, position: 0)
        let b = Region(name: "b", sourceId: s, sourceIn: 0, sourceOut: 100, position: 100)
        let c = Region(name: "c", trackId: t2, sourceId: s, sourceIn: 0, sourceOut: 100, position: 150)
        p.regions = [a, b, c]
        EditOperations.delete(&p, ids: [a.id], ripple: true)
        XCTAssertEqual(p.regions.first { $0.name == "b" }?.position, 0)
        XCTAssertEqual(p.regions.first { $0.name == "c" }?.position, 150)
        EditOperations.duplicate(&p, ids: [p.regions.first { $0.name == "b" }!.id])
        XCTAssertEqual(p.regions.first { $0.name == "c" }?.position, 150, "duplicate does not push other tracks")
    }

    func testVersionTwoRoundTripNestsRegionsInTracks() throws {
        var p = Project(sessionRate: 48000, channelCount: 2)
        let t2 = EditOperations.addTrack(&p)
        EditOperations.updateTrack(&p, id: t2) { $0.gainDB = -7; $0.pan = 0.25; $0.mute = true; $0.solo = true; $0.name = "Bass" }
        EditOperations.updateTrack(&p, id: Track.firstID) { $0.gainDB = -1000 }
        EditOperations.setMasterGain(&p, dB: -1.5)
        p.regions = [Region(name: "a", sourceId: UUID(), sourceIn: 0, sourceOut: 10, position: 5),
                     Region(name: "b", trackId: t2, sourceId: UUID(), sourceIn: 0, sourceOut: 10, position: 0)]
        p.sortRegions()
        let data = try JSONEncoder().encode(ProjectFile(document: p))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let doc = json["document"] as! [String: Any]
        XCTAssertNil(doc["regions"])
        let tracks = doc["tracks"] as! [[String: Any]]
        XCTAssertEqual(tracks.map { ($0["regions"] as! [Any]).count }, [1, 1])
        XCTAssertEqual((doc["master"] as! [String: Any])["gainDB"] as? Double, -1.5)
        let back = try JSONDecoder().decode(ProjectFile.self, from: data)
        XCTAssertEqual(back.version, 2)
        XCTAssertEqual(back.document, p)
    }

    // MARK: Migration

    /// Version 1 packages saved by M5 with their M5 renders (`Fixtures`, made with the M5 code before tracks existed).
    func testVersionOneDocumentsPlayAsInM5AndSaveAsVersionTwo() throws {
        let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        for name in ["m5-stereo", "m5-mono", "m5-mixed"] {
            let dir = TestAudio.tempDirectory()
            let url = dir.appendingPathComponent("\(name).tape")
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent("\(name).tape"), to: url)
            let json = try String(contentsOf: url.appendingPathComponent("project.json"), encoding: .utf8)
            XCTAssertTrue(json.contains("\"version\" : 1"), name)
            let package = TapePackage(url: url)
            let file = try package.load()
            XCTAssertEqual(file.document.tracks.count, 1)
            XCTAssertEqual(file.document.tracks[0].name, "Track 1")
            XCTAssertTrue(file.document.regions.allSatisfy { $0.trackId == file.document.tracks[0].id })

            var sources: [UUID: SampleSource] = [:]
            for ref in file.document.sources { sources[ref.id] = try FileSource(url: package.resolve(ref)) }
            let list = EditList(project: file.document, sources: sources)
            let engine = PlaybackEngine()
            try engine.configure(sessionRate: 48000, channelCount: list.channelCount, manualRendering: true)
            engine.setEditList(list)
            engine.play(from: 0)
            let now = try engine.renderManual(frames: Int(list.length))
            engine.shutdown()
            let m5 = try TestAudio.read(fixtures.appendingPathComponent("\(name)-render.caf"))
            // Every session plays in stereo now; a mono M5 session plays its channel on both sides.
            XCTAssertEqual(now.count, 2)
            XCTAssertEqual(now[0].count, m5[0].count)
            for c in 0..<2 {
                XCTAssertEqual(now[c], m5[min(c, m5.count - 1)], "\(name) channel \(c) is sample identical")
            }

            try package.save(file)
            let saved = try String(contentsOf: package.projectURL, encoding: .utf8)
            XCTAssertTrue(saved.contains("\"version\" : 2"), name)
            XCTAssertTrue(saved.contains("\"tracks\""), name)
            XCTAssertEqual(try package.load().document, file.document)
        }
    }

    // MARK: Meters

    func testMeterReportsMinusSixDBFS() throws {
        let rate = 48000.0
        // Hard left puts a mono source +3.01 dB on the left: a tone at -9.01 dBFS meters -6.
        let amplitude = Float(pow(10, (-6.0 - 3.0103) / 20))
        let tone = (0..<48000).map { amplitude * Float(sin(2 * Double.pi * 1000 * Double($0) / rate)) }
        let (id, src) = source([tone])
        let t = TrackMix(id: UUID(), pan: -1)
        let region = Region(name: "r", trackId: t.id, sourceId: id, sourceIn: 0, sourceOut: 48000, position: 0)
        let list = EditList(regions: [region], sources: [id: src], channelCount: 2, tracks: [t])
        let engine = PlaybackEngine()
        try engine.configure(sessionRate: rate, channelCount: 2, manualRendering: true)
        engine.setEditList(list)
        engine.play(from: 0)
        _ = try engine.renderManual(frames: 24000)
        let peaks = try XCTUnwrap(engine.meters.drain())
        engine.shutdown()
        XCTAssertEqual(MeterBallistics.dB(peaks.tracks[0]), -6.0, accuracy: 0.1)
        XCTAssertEqual(MeterBallistics.dB(peaks.master[0]), -6.0, accuracy: 0.1)
        XCTAssertEqual(MeterBallistics.dB(peaks.master[1]), MeterBallistics.floorDB)

        var m = MeterBallistics()
        m.update(peak: peaks.tracks[0], now: 0)
        XCTAssertEqual(m.levelDB, -6.0, accuracy: 0.1)
        m.update(peak: 0, now: 1)
        XCTAssertEqual(m.holdDB, -6.0, accuracy: 0.1, "held for 1.5 s")
        XCTAssertEqual(m.levelDB, -30.0, accuracy: 0.1, "falls 24 dB per second")
        m.update(peak: 0, now: 1.6)
        XCTAssertLessThan(m.holdDB, -40)
        m.update(peak: 1.0, now: 2)
        m.update(peak: 0, now: 10)
        XCTAssertTrue(m.clipped, "clip stays latched")
        m.resetClip()
        XCTAssertFalse(m.clipped)
    }
}
