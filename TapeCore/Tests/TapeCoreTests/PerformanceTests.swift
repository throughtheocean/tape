import AVFoundation
import XCTest
@testable import TapeCore

/// Long running measurements, enabled with TAPE_PERF=1.
/// TAPE_PERF_HOURS sets the file length (default 1, acceptance runs use 3).
final class PerformanceTests: XCTestCase {
    func testPyramidBuildTimeForLongStereoFile() throws {
        guard ProcessInfo.processInfo.environment["TAPE_PERF"] == "1" else { throw XCTSkip("set TAPE_PERF=1") }
        let hours = Double(ProcessInfo.processInfo.environment["TAPE_PERF_HOURS"] ?? "1") ?? 1
        let url = try Self.longFile(hours: hours)
        let t0 = CFAbsoluteTimeGetCurrent()
        let pyramid = try PeakPyramid.build(url: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        print("PERF pyramid \(hours) h 48 kHz stereo 24 bit WAV: \(String(format: "%.2f", elapsed)) s, \(pyramid.frameCount) frames")
        XCTAssertLessThan(elapsed, hours * 2)
        // Envelope is 0.5 + 0.45 sin(t / 7): every 65536 frame block near a crest peaks close to 0.95.
        let top = pyramid.levels.count - 1
        let peak = (0..<pyramid.levels[top].blockCount).map { pyramid.minMax(level: top, block: $0, channel: 0).max }.max() ?? 0
        let last = pyramid.minMax(level: top, block: pyramid.levels[top].blockCount - 1, channel: 1)
        print("PERF sanity: max \(peak), last block ch1 \(last)")
        XCTAssertEqual(peak, 0.95, accuracy: 0.01)
        XCTAssertGreaterThan(last.max, 0.01)
    }

    /// Loudness analysis, a gain apply to a new CAF and an offline AU compressor over 10 minutes of 48 kHz stereo.
    func testProcessingTimeForTenMinutes() throws {
        guard ProcessInfo.processInfo.environment["TAPE_PERF"] == "1" else { throw XCTSkip("set TAPE_PERF=1") }
        let rate = 48000.0, frames = 10 * 60 * 48000
        let channels = (0..<2).map { c in
            (0..<frames).map { i in Float(0.3 * sin(2 * Double.pi * (220 + 110 * Double(c)) * Double(i) / rate)) }
        }
        let source = MemorySource(samples: channels)
        let buffer = AudioBuffer(channels: channels, sampleRate: rate)
        func time(_ label: String, _ body: () throws -> Void) rethrows {
            let t0 = CFAbsoluteTimeGetCurrent()
            try body()
            print("PERF \(label): \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0)) s")
        }
        time("integrated loudness 10 min") { _ = Loudness.integrated(buffer) }
        time("true peak 10 min") { _ = Loudness.truePeakDB(buffer) }
        let url = TestAudio.tempDirectory().appendingPathComponent("perf.caf")
        try time("gain apply 10 min to CAF") {
            _ = try ProcessApplier.render(source: source, sampleRate: rate, process: Gain(dB: -3),
                                          range: SampleRange(start: 0, end: Int64(frames)), crossfade: false, to: url)
        }
        try time("AU compressor 10 min offline") { _ = try Dynamics.compressor().render(input: buffer, range: buffer.all) }
    }

    /// Export of 10 minutes of 48 kHz stereo through the engine in manual rendering mode.
    func testExportTimeForTenMinutes() throws {
        guard ProcessInfo.processInfo.environment["TAPE_PERF"] == "1" else { throw XCTSkip("set TAPE_PERF=1") }
        let rate = 48000.0, frames = 10 * 60 * 48000
        let channels = (0..<2).map { c in
            (0..<frames).map { i in Float(0.3 * sin(2 * Double.pi * (220 + 110 * Double(c)) * Double(i) / rate)) }
        }
        let id = UUID()
        let region = Region(name: "Long", sourceId: id, sourceIn: 0, sourceOut: Int64(frames), position: 0)
        let list = EditList(regions: [region], sources: [id: MemorySource(samples: channels)], channelCount: 2)
        let dir = TestAudio.tempDirectory()
        for (label, settings) in [
            ("WAV 24 bit 48 kHz", ExportSettings(container: .wav, sampleFormat: .int24, sampleRate: 48000)),
            ("WAV 16 bit 44.1 kHz dithered", ExportSettings(container: .wav, sampleFormat: .int16, sampleRate: 44100)),
            ("FLAC 24 bit 96 kHz", ExportSettings(container: .flac, sampleFormat: .int24, sampleRate: 96000)),
            ("AAC 256 kbps", ExportSettings(container: .aac, sampleRate: 48000)),
        ] {
            let jobs = Exporter.jobs(list: list, scope: .mix, directory: dir, fileName: label, pattern: "", documentName: "",
                                     date: Date(), settings: settings)
            let t0 = CFAbsoluteTimeGetCurrent()
            try Exporter.export(jobs, sessionRate: rate, settings: settings)
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            print("PERF export 10 min \(label): \(String(format: "%.2f", elapsed)) s (\(String(format: "%.0f", 600 / elapsed))x real time)")
        }
    }

    /// 48 kHz stereo 24 bit WAV of a swept sine with noise, cached in /tmp.
    static func longFile(hours: Double) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/tape-perf-\(hours)h.wav")
        let frames = Int64(hours * 3600 * 48000)
        if let info = try? AudioFileInfo(url: url), info.frameCount == frames { return url }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 20
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var pos: Int64 = 0
        var phase = 0.0
        while pos < frames {
            let n = Int(min(Int64(chunk), frames - pos))
            let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
            for i in 0..<n {
                let t = Double(pos + Int64(i)) / 48000
                phase += 2 * Double.pi * (100 + 50 * sin(t / 60)) / 48000
                let env = Float(0.5 + 0.45 * sin(t / 7))
                l[i] = Float(sin(phase)) * env
                r[i] = Float(sin(phase * 1.5)) * env * 0.7
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            pos += Int64(n)
        }
        return url
    }
}
