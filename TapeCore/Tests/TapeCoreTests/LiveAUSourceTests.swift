import XCTest
@testable import TapeCore

/// The AU preview source sounds like Apply: read in playback sized blocks, it matches the offline render, also for a
/// range that does not start on a block boundary.
final class LiveAUSourceTests: XCTestCase {
    private let rate = 48000.0

    private func tone(channels: Int) -> [[Float]] {
        let one = (0..<48000).map { i -> Float in
            let env: Float = i < 12000 ? 0.1 : i < 30000 ? 0.9 : 0.3
            return env * Float(sin(2 * Double.pi * 220 * Double(i) / rate))
        }
        return Array(repeating: one, count: channels)
    }

    private func check(_ process: AUProcess, channels: Int, processed: SampleRange, file: StaticString = #filePath, line: UInt = #line) throws {
        let samples = tone(channels: channels)
        let original = AudioBuffer(channels: samples, sampleRate: rate)
        var offline = try process.render(input: original, range: processed)
        let fade = processed == SampleRange(start: 0, end: Int64(samples[0].count)) ? 0 : 96
        ProcessCrossfade.apply(original: original, processed: &offline, range: processed, frames: fade)
        let live = try LiveAUSource(base: MemorySource(samples: samples), processed: processed, process: process,
                                    sampleRate: rate, crossfade: fade)
        let block = 512
        let out = SampleBuffer(channelCount: channels, capacity: samples[0].count)
        var at = 0
        while at < samples[0].count {
            let n = min(block, samples[0].count - at)
            live.read(start: Int64(at), count: n, into: out, offset: at)
            at += n
        }
        var worst: Float = 0
        for c in 0..<channels {
            for i in 0..<samples[0].count { worst = max(worst, abs(out.channels[c][i] - offline.channels[c][i])) }
        }
        XCTAssertLessThan(worst, 1e-6, "\(process.name) \(channels) ch differs by \(worst)", file: file, line: line)
        XCTAssertGreaterThan(zip(offline.channels[0], samples[0]).map { abs($0 - $1) }.max()!, 0.01, "the process changes the audio",
                             file: file, line: line)
    }

    func testCompressorMatchesOfflineRender() throws {
        try check(Dynamics.compressor(threshold: -30, headroom: 5, attack: 0.001, release: 0.05), channels: 2,
                  processed: SampleRange(start: 0, end: 48000))
        try check(Dynamics.compressor(threshold: -30, headroom: 5, attack: 0.001, release: 0.05), channels: 1,
                  processed: SampleRange(start: 6000, end: 40000))
    }

    func testLimiterMatchesOfflineRender() throws {
        try check(Dynamics.limiter(preGain: 12), channels: 2, processed: SampleRange(start: 10000, end: 45000))
    }

    /// A jump (loop wrap) resets the unit, so the second pass sounds like the first.
    func testJumpRestartsLikeTheFirstPass() throws {
        let samples = tone(channels: 2)
        let live = try LiveAUSource(base: MemorySource(samples: samples), processed: SampleRange(start: 0, end: 48000),
                                    process: Dynamics.compressor(threshold: -30), sampleRate: rate)
        let a = SampleBuffer(channelCount: 2, capacity: 24000), b = SampleBuffer(channelCount: 2, capacity: 24000)
        for k in 0..<2 {
            let out = k == 0 ? a : b
            var at = 0
            while at < 24000 {
                live.read(start: Int64(12000 + at), count: 512, into: out, offset: at)
                at += 512
            }
        }
        for i in 0..<23552 { XCTAssertEqual(a.channels[0][i], b.channels[0][i], accuracy: 1e-5) }
    }
}
