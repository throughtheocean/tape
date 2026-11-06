import AVFoundation
import XCTest
@testable import TapeCore

final class DocumentTests: XCTestCase {
    func testSaveReopenKeepsEveryRegionAndVersion() throws {
        let dir = TestAudio.tempDirectory()
        let pkg = try TapePackage.create(at: dir.appendingPathComponent("Doc.tape"))
        let src = SourceRef(name: "a.wav", location: .external(path: "/tmp/a.wav", bookmark: nil),
                            sampleRate: 48000, channelCount: 2, frameCount: 480_000)
        var project = Project(sessionRate: 48000, channelCount: 2, sources: [src])
        for i in 0..<20 {
            project.regions.append(Region(name: "r\(i)", sourceId: src.id, sourceIn: Int64(i * 100), sourceOut: Int64(i * 100 + 5000),
                                          position: Int64(i * 6000), gainDB: Double(i) * -0.5,
                                          fadeIn: Fade(length: Int64(i * 10), shape: FadeShape.allCases[i % 4], blend: 0.25),
                                          fadeOut: Fade(length: 480, shape: .exp)))
        }
        var view = ViewState()
        view.range = SampleRange(start: 10, end: 2000)
        view.loopEnabled = true
        try pkg.save(ProjectFile(document: project, view: view))

        let reopened = try TapePackage(url: pkg.url).load()
        XCTAssertEqual(reopened.version, 2)
        XCTAssertEqual(reopened.document, project)
        XCTAssertEqual(reopened.document.regions, project.regions)
        XCTAssertEqual(reopened.view, view)

        let json = try String(contentsOf: pkg.projectURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"version\" : 2"))
    }

    func testNewerVersionIsRejected() throws {
        let pkg = try TapePackage.create(at: TestAudio.tempDirectory().appendingPathComponent("New.tape"))
        let json = try String(contentsOf: pkg.projectURL, encoding: .utf8).replacingOccurrences(of: "\"version\" : 2", with: "\"version\" : 99")
        try json.write(to: pkg.projectURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try pkg.load())
    }

    func testMissingPeaksAreRebuilt() throws {
        let dir = TestAudio.tempDirectory()
        let pkg = try TapePackage.create(at: dir.appendingPathComponent("Peaks.tape"))
        let audio = dir.appendingPathComponent("tone.wav")
        let signal = [(0..<100_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }]
        try TestAudio.write(signal, sampleRate: 48000, to: audio, bitDepth: 24)
        let ref = SourceRef(name: "tone.wav", location: .external(path: audio.path, bookmark: TapePackage.bookmark(for: audio)),
                            sampleRate: 48000, channelCount: 1, frameCount: 100_000)

        let first = try SourceLoader.load(ref, in: pkg, sessionRate: 48000)
        XCTAssertNotNil(first.peakBuildSeconds)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.peakURL(for: ref.id).path))

        let cached = try SourceLoader.load(ref, in: pkg, sessionRate: 48000)
        XCTAssertNil(cached.peakBuildSeconds, "second load should use the cache")

        try FileManager.default.removeItem(at: pkg.peaksURL)
        let rebuilt = try SourceLoader.load(ref, in: pkg, sessionRate: 48000)
        XCTAssertNotNil(rebuilt.peakBuildSeconds)
        XCTAssertEqual(rebuilt.peaks.frameCount, 100_000)
        XCTAssertEqual(rebuilt.peaks.minMax(level: 3, block: 0, channel: 0).max, 0.5, accuracy: 0.001)
    }

    func testSourceAtOtherRateIsResampledToSessionRate() throws {
        let dir = TestAudio.tempDirectory()
        let pkg = try TapePackage.create(at: dir.appendingPathComponent("Rate.tape"))
        let audio = dir.appendingPathComponent("tone44.wav")
        let n = 44100
        try TestAudio.write([(0..<n).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 44100)) * 0.5 }],
                            sampleRate: 44100, to: audio)
        let ref = SourceRef(name: "tone44.wav", location: .external(path: audio.path, bookmark: nil),
                            sampleRate: 44100, channelCount: 1, frameCount: Int64(n))
        let loaded = try SourceLoader.load(ref, in: pkg, sessionRate: 48000)
        XCTAssertEqual(loaded.source.sampleRate, 48000)
        XCTAssertEqual(Double(loaded.source.frameCount), 48000, accuracy: 2)
    }

    func testLoadsWavAiffCafFlacAndM4a() throws {
        let dir = TestAudio.tempDirectory()
        let pkg = try TapePackage.create(at: dir.appendingPathComponent("Formats.tape"))
        let n = 48000
        let tone = (0..<n).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) * 0.5 }
        let pcm = [tone, tone.map { $0 * 0.5 }]
        let wav = dir.appendingPathComponent("t.wav"), aiff = dir.appendingPathComponent("t.aiff"), caf = dir.appendingPathComponent("t.caf")
        try TestAudio.write(pcm, sampleRate: 48000, to: wav, bitDepth: 24)
        try TestAudio.write(pcm, sampleRate: 48000, to: aiff, bitDepth: 16)
        try TestAudio.write(pcm, sampleRate: 48000, to: caf)
        func encode(_ url: URL, _ settings: [String: Any]) throws {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
            for c in 0..<2 { pcm[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: n) } }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
        }
        let flac = dir.appendingPathComponent("t.flac"), m4a = dir.appendingPathComponent("t.m4a")
        try encode(flac, [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2,
                          AVEncoderBitDepthHintKey: 24])
        try encode(m4a, [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2,
                         AVEncoderBitRateKey: 256_000])

        for url in [wav, aiff, caf, flac, m4a] {
            let info = try AudioFileInfo(url: url)
            let ref = SourceRef(name: url.lastPathComponent, location: .external(path: url.path, bookmark: nil),
                                sampleRate: info.sampleRate, channelCount: info.channelCount, frameCount: info.frameCount)
            let loaded = try SourceLoader.load(ref, in: pkg, sessionRate: 48000)
            XCTAssertEqual(loaded.source.channelCount, 2, url.lastPathComponent)
            XCTAssertEqual(Double(loaded.source.frameCount), Double(n), accuracy: 2048, url.lastPathComponent)
            let peak = loaded.peaks.minMax(level: 3, block: 0, channel: 0).max
            XCTAssertEqual(peak, 0.5, accuracy: 0.03, url.lastPathComponent)
        }
    }

    func testFileSourceReadsAcrossBlocksAndPastEnd() throws {
        let dir = TestAudio.tempDirectory()
        let audio = dir.appendingPathComponent("ramp.caf")
        let n = 100_000
        let ramp = (0..<n).map { Float($0) / Float(n) }
        try TestAudio.write([ramp, ramp.map { -$0 }], sampleRate: 48000, to: audio)
        let src = try FileSource(url: audio)
        let buf = SampleBuffer(channelCount: 2, capacity: 70000)
        src.read(start: 32000, count: 70000, into: buf, offset: 0)
        for i in stride(from: 0, to: 68000, by: 997) {
            XCTAssertEqual(buf.channels[0][i], ramp[32000 + i])
            XCTAssertEqual(buf.channels[1][i], -ramp[32000 + i])
        }
        XCTAssertEqual(buf.channels[0][69999], 0, "past end must be zero")
        src.read(start: -10, count: 20, into: buf, offset: 0)
        XCTAssertEqual(buf.channels[0][5], 0)
        XCTAssertEqual(buf.channels[0][15], ramp[5])
    }
}
