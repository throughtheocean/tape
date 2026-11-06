import AVFoundation
import HardwarePresets
import XCTest
@testable import TapeCore

final class ExportTests: XCTestCase {
    let rate = 48000.0
    let src = UUID()
    var dir: URL!

    override func setUp() { dir = TestAudio.tempDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// 2 s stereo: different sines per channel, cut into three regions with fades, gain and a gap.
    func editList(channels: Int = 2) -> EditList {
        let n = 96000
        let samples: [[Float]] = (0..<channels).map { c in
            let step = 0.031 + 0.017 * Double(c)
            return (0..<n).map { i -> Float in Float(sin(Double(i) * step)) * 0.6 }
        }
        var p = Project(sessionRate: rate, channelCount: channels)
        p.regions = [Region(name: "Take", sourceId: src, sourceIn: 0, sourceOut: Int64(n), position: 0)]
        EditOperations.blade(&p, at: [30000, 60000])
        EditOperations.setFadeLength(&p, ids: Set(p.regions.map(\.id)), end: .fadeIn, length: 2000)
        EditOperations.setFadeShape(&p, ids: Set(p.regions.map(\.id)), end: .fadeIn, continuous: 1.4)
        EditOperations.setFadeLength(&p, ids: Set(p.regions.map(\.id)), end: .fadeOut, length: 3000)
        EditOperations.setGain(&p, ids: [p.regions[1].id], dB: -4.5)
        _ = EditOperations.move(&p, ids: [p.regions[2].id], by: 7000)
        return EditList(regions: p.regions, sources: [src: MemorySource(samples: samples)], channelCount: channels)
    }

    func render(_ list: EditList, _ span: SampleRange) -> [[Float]] {
        let out = SampleBuffer(channelCount: list.channelCount, capacity: Int(span.length))
        EditListRenderer().render(list, start: span.start, frames: Int(span.length), into: out)
        return out.toArrays(count: Int(span.length))
    }

    func export(_ list: EditList, _ settings: ExportSettings, scope: ExportScope = .document, name: String = "out") throws -> [URL] {
        let jobs = Exporter.jobs(list: list, scope: scope, directory: dir, fileName: name, pattern: Exporter.defaultPattern,
                                 documentName: "Tape", date: Date(), settings: settings)
        return try Exporter.export(jobs, sessionRate: rate, settings: settings)
    }

    func maxDiff(_ a: [[Float]], _ b: [[Float]]) -> Float {
        XCTAssertEqual(a.count, b.count)
        var m: Float = 0
        for c in 0..<min(a.count, b.count) {
            XCTAssertEqual(a[c].count, b[c].count, "channel \(c) length")
            for i in 0..<min(a[c].count, b[c].count) { m = max(m, abs(a[c][i] - b[c][i])) }
        }
        return m
    }

    // MARK: Equality with playback

    func testFloatExportEqualsPlaybackSampleForSample() throws {
        let list = editList()
        let url = try export(list, ExportSettings(container: .wav, sampleFormat: .float32, sampleRate: rate))[0]
        let file = try TestAudio.read(url)

        let engine = PlaybackEngine()
        try engine.configure(sessionRate: rate, channelCount: 2, manualRendering: true)
        engine.setEditList(list)
        engine.play(from: 0, speed: 1)
        var playback = [[Float]](repeating: [], count: 2)
        while playback[0].count < Int(list.length) {
            let block = try engine.renderManual(frames: 1024)
            for c in 0..<2 { playback[c] += block[c] }
        }
        engine.shutdown()
        playback = playback.map { Array($0.prefix(Int(list.length))) }

        XCTAssertEqual(file[0].count, Int(list.length))
        XCTAssertEqual(maxDiff(file, playback), 0)
        XCTAssertEqual(maxDiff(file, render(list, SampleRange(start: 0, end: list.length))), 0)
    }

    // MARK: Roundtrips

    func testRoundtripsAreLosslessWithinQuantization() throws {
        let list = editList()
        let reference = render(list, SampleRange(start: 0, end: list.length))
        let caf = try TestAudio.read(export(list, ExportSettings(container: .caf, sampleFormat: .float32, sampleRate: rate), name: "f")[0])
        XCTAssertEqual(maxDiff(caf, reference), 0)

        let wav24 = try TestAudio.read(export(list, ExportSettings(container: .wav, sampleFormat: .int24, sampleRate: rate), name: "w24")[0])
        XCTAssertLessThanOrEqual(maxDiff(wav24, reference), 1.0 / 8_388_608)
        let aiff24 = try TestAudio.read(export(list, ExportSettings(container: .aiff, sampleFormat: .int24, sampleRate: rate), name: "a24")[0])
        XCTAssertEqual(maxDiff(aiff24, wav24), 0)
        let flac24 = try TestAudio.read(export(list, ExportSettings(container: .flac, sampleFormat: .int24, sampleRate: rate), name: "fl24")[0])
        XCTAssertEqual(maxDiff(flac24, wav24), 0, "FLAC is lossless")
        let alac24 = try TestAudio.read(export(list, ExportSettings(container: .alac, sampleFormat: .int24, sampleRate: rate), name: "al24")[0])
        XCTAssertEqual(maxDiff(alac24, wav24), 0, "ALAC is lossless")

        let plain16 = ExportSettings(container: .wav, sampleFormat: .int16, sampleRate: rate, dither: false)
        let wav16 = try TestAudio.read(export(list, plain16, name: "w16")[0])
        XCTAssertLessThanOrEqual(maxDiff(wav16, reference), 1.0 / 32768)
        var flac16 = plain16
        flac16.container = .flac
        XCTAssertEqual(maxDiff(try TestAudio.read(export(list, flac16, name: "fl16")[0]), wav16), 0)
        var alac16 = plain16
        alac16.container = .alac
        XCTAssertEqual(maxDiff(try TestAudio.read(export(list, alac16, name: "al16")[0]), wav16), 0)
    }

    func testAACWritesAPlayableFileOfTheRightLength() throws {
        let list = editList()
        let url = try export(list, ExportSettings(container: .aac, sampleRate: rate, bitRate: 256_000))[0]
        XCTAssertEqual(url.pathExtension, "m4a")
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Double(file.length), Double(list.length), accuracy: 2048)
    }

    // MARK: Dither

    /// A -60 dBFS sine at 16 bit: with TPDF dither the error is noise of about half an LSB RMS, uncorrelated with
    /// the signal. A sine below one LSB comes out as noise with dither, and as silence without.
    func testDitherGivesNoiseFloorNotSilenceOrSteps() throws {
        let n = 48000
        let lsb: Float = 1.0 / 32768
        func list(amplitude: Float) -> EditList {
            let s = (0..<n).map { amplitude * Float(sin(2 * Double.pi * 997 * Double($0) / rate)) }
            let r = Region(name: "Sine", sourceId: src, sourceIn: 0, sourceOut: Int64(n), position: 0)
            return EditList(regions: [r], sources: [src: MemorySource(samples: [s])], channelCount: 1)
        }
        let quiet = list(amplitude: 0.001)
        let dithered = try TestAudio.read(export(quiet, ExportSettings(container: .wav, sampleFormat: .int16, sampleRate: rate), name: "d")[0])[0]
        let original = render(quiet, SampleRange(start: 0, end: Int64(n)))[0]
        let error = zip(dithered, original).map { $0 - $1 }
        let rms = sqrt(error.reduce(0) { $0 + $1 * $1 } / Float(n)) / lsb
        let corr = zip(error, original).reduce(0) { $0 + $1.0 * $1.1 }
            / sqrt(error.reduce(0) { $0 + $1 * $1 } * original.reduce(0) { $0 + $1 * $1 })
        print("dither -60 dBFS: error \(rms) LSB RMS, correlation \(corr)")
        XCTAssertEqual(rms, 0.5, accuracy: 0.1)
        XCTAssertLessThan(abs(corr), 0.02)
        XCTAssertGreaterThan(Set(dithered).count, 40, "many levels, not a few steps")

        let tiny = list(amplitude: lsb * 0.3)
        let noise = try TestAudio.read(export(tiny, ExportSettings(container: .wav, sampleFormat: .int16, sampleRate: rate), name: "t")[0])[0]
        let silent = try TestAudio.read(export(tiny, ExportSettings(container: .wav, sampleFormat: .int16, sampleRate: rate, dither: false),
                                               name: "s")[0])[0]
        XCTAssertGreaterThan(noise.filter { $0 != 0 }.count, n / 5)
        XCTAssertEqual(silent.filter { $0 != 0 }.count, 0)
    }

    // MARK: Rates

    func testRateConversionKeepsDurationPitchAndLevel() throws {
        let n = 48000
        let s = (0..<n).map { 0.5 * Float(sin(2 * Double.pi * 1000 * Double($0) / rate)) }
        let r = Region(name: "Sine", sourceId: src, sourceIn: 0, sourceOut: Int64(n), position: 0)
        let list = EditList(regions: [r], sources: [src: MemorySource(samples: [s])], channelCount: 1)
        for target in ExportSettings.rates where target != rate {
            let url = try export(list, ExportSettings(container: .wav, sampleFormat: .float32, sampleRate: target),
                                 name: "r\(Int(target))")[0]
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, target)
            let x = try TestAudio.read(url)[0]
            XCTAssertEqual(x.count, Int((Double(n) * target / rate).rounded()))
            let middle = x[x.count / 4 ..< x.count * 3 / 4]
            var crossings = 0
            for i in middle.indices.dropFirst() where (middle[i - 1] < 0) != (middle[i] < 0) { crossings += 1 }
            let seconds = Double(middle.count) / target
            XCTAssertEqual(Double(crossings) / 2 / seconds, 1000, accuracy: 2, "\(target)")
            XCTAssertEqual(middle.map(abs).max()!, 0.5, accuracy: 0.005, "\(target)")
        }
    }

    // MARK: Layouts

    func testMonoStereoAndSplitLayouts() throws {
        let list = editList()
        let reference = render(list, SampleRange(start: 0, end: list.length))
        let mono = try TestAudio.read(export(list, ExportSettings(container: .wav, sampleFormat: .float32, sampleRate: rate, layout: .mono),
                                             name: "m")[0])
        XCTAssertEqual(mono.count, 1)
        XCTAssertEqual(maxDiff(mono, [zip(reference[0], reference[1]).map { ($0 + $1) * 0.5 }]), 0)

        let split = try export(list, ExportSettings(container: .wav, sampleFormat: .float32, sampleRate: rate, layout: .split), name: "sp")
        XCTAssertEqual(split.map(\.lastPathComponent), ["sp-L.wav", "sp-R.wav"])
        XCTAssertEqual(maxDiff(try TestAudio.read(split[0]), [reference[0]]), 0)
        XCTAssertEqual(maxDiff(try TestAudio.read(split[1]), [reference[1]]), 0)

        let monoList = editList(channels: 1)
        let monoRef = render(monoList, SampleRange(start: 0, end: monoList.length))[0]
        let stereo = try TestAudio.read(export(monoList, ExportSettings(container: .wav, sampleFormat: .float32, sampleRate: rate,
                                                                        layout: .stereo), name: "st")[0])
        XCTAssertEqual(maxDiff(stereo, [monoRef, monoRef]), 0)
    }

    // MARK: Scopes and naming

    func testRangeAndSelectionScopes() throws {
        let list = editList()
        let float = ExportSettings(container: .wav, sampleFormat: .float32, sampleRate: rate)
        let range = SampleRange(start: 25000, end: 41000)
        let ranged = try TestAudio.read(export(list, float, scope: .range(range), name: "range")[0])
        XCTAssertEqual(maxDiff(ranged, render(list, range)), 0)

        let picked = [list.regions[0].id, list.regions[2].id]
        let selection = try TestAudio.read(export(list, float, scope: .selection(picked), name: "sel")[0])
        let only = EditList(regions: list.regions.filter { picked.contains($0.id) }, sources: list.sources, channelCount: 2)
        XCTAssertEqual(maxDiff(selection, render(only, SampleRange(start: 0, end: list.length))), 0)
        XCTAssertEqual(selection[0][45000], 0, "the unselected middle region is silent")
    }

    /// 64 regions placed out of order export as Tape-01 to Tape-64 in timeline order, each with its own audio.
    func testEachRegionExportNamesAndOrders64Regions() throws {
        let n = 64, length: Int64 = 600
        let samples = (0..<(n * Int(length))).map { Float($0 / Int(length) + 1) / 100 }
        var regions = (0..<n).map { i in
            Region(name: "R\(i)", sourceId: src, sourceIn: Int64(i) * length, sourceOut: Int64(i + 1) * length,
                   position: Int64(i) * (length + 100))
        }
        regions.shuffle()
        let list = EditList(regions: regions, sources: [src: MemorySource(samples: [samples])], channelCount: 1)
        let urls = try export(list, ExportSettings(container: .wav, sampleFormat: .float32, sampleRate: rate),
                              scope: .eachRegion(regions.map(\.id)))
        XCTAssertEqual(urls.map(\.lastPathComponent), (1...n).map { String(format: "Tape-%02d.wav", $0) })
        for (i, url) in urls.enumerated() {
            let x = try TestAudio.read(url)[0]
            XCTAssertEqual(x.count, Int(length))
            XCTAssertEqual(x[300], Float(i + 1) / 100, "file \(i + 1) holds region R\(i)")
        }
    }

    func testFileNamePatternTokens() {
        var c = DateComponents()
        (c.year, c.month, c.day) = (2026, 11, 6)
        let date = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(Exporter.fileName(pattern: "{name}-{index:02}", name: "Song", index: 3, region: "Kick", date: date), "Song-03")
        XCTAssertEqual(Exporter.fileName(pattern: "{region}_{index:03}_{date}", name: "Song", index: 12, region: "Kick", date: date),
                       "Kick_012_261106")
        XCTAssertEqual(Exporter.fileName(pattern: "{index} {other} {name", name: "S", index: 7, region: "", date: date), "7 {other} {name")
        XCTAssertEqual(Exporter.fileName(pattern: "{region}", name: "S", index: 1, region: "a/b:c", date: date), "a-b-c")
        let list = EditList(regions: (0..<3).map { Region(name: "Same", sourceId: src, sourceIn: 0, sourceOut: 10, position: Int64($0) * 20) },
                            sources: [:], channelCount: 1)
        let jobs = Exporter.jobs(list: list, scope: .eachRegion(list.regions.map(\.id)), directory: dir, fileName: "", pattern: "{region}",
                                 documentName: "", date: date, settings: ExportSettings())
        XCTAssertEqual(jobs.map(\.url.lastPathComponent), ["Same.wav", "Same 2.wav", "Same 3.wav"])
    }

    // MARK: Progress and cancel

    func testCancelLeavesNoFiles() throws {
        let list = editList()
        let calls = AtomicInt64(0)
        XCTAssertThrowsError(try Exporter.export(
            Exporter.jobs(list: list, scope: .eachRegion(list.regions.map(\.id)), directory: dir, fileName: "", pattern: "{index}",
                          documentName: "", date: Date(), settings: ExportSettings()),
            sessionRate: rate, settings: ExportSettings(), progress: { _ in _ = calls.add(1) }, isCancelled: { calls.load() > 20 }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    // MARK: Presets

    func testEveryPresetWritesItsFormat() throws {
        let list = editList()
        for preset in ExportPreset.builtIn {
            let settings = ExportSettings(preset: preset)
            XCTAssertTrue(settings.matches(preset))
            let url = try export(list, settings, name: preset.id)[0]
            let file = try AVAudioFile(forReading: url)
            let asbd = file.fileFormat.streamDescription.pointee
            XCTAssertEqual(url.pathExtension, "wav", preset.name)
            XCTAssertEqual(asbd.mSampleRate, preset.format.sampleRate, preset.name)
            XCTAssertEqual(Int(asbd.mBitsPerChannel), preset.format.bitDepth.bits, preset.name)
            XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, preset.format.bitDepth.isFloat, preset.name)
            XCTAssertEqual(Int(asbd.mChannelsPerFrame), preset.format.channels.resolvedChannelCount(sourceChannels: 2), preset.name)
        }
        let reel = ExportPreset.preset(for: "morphagene")!
        XCTAssertNil(reel.violation(fileSeconds: [170]))
        XCTAssertNotNil(reel.violation(fileSeconds: [175]))
        XCTAssertNotNil(reel.violation(fileSeconds: Array(repeating: 1, count: 10)))
        XCTAssertNotNil(ExportPreset.preset(for: "octatrack")!.violation(fileSeconds: Array(repeating: 1, count: 65)))
    }
}
