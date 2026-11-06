import XCTest
@testable import TapeCore

final class PeakPyramidTests: XCTestCase {
    /// Value exactly representable in Float16 so stored extremes compare exactly.
    private func q(_ v: Float) -> Float { Float(Float16(v)) }

    /// Signal with a distinct, known minimum and maximum placed inside every 16 frame block.
    private func synthesize(frames: Int, channels: Int) -> [[Float]] {
        (0..<channels).map { c in
            var s = [Float](repeating: 0, count: frames)
            for b in 0..<(frames + 15) / 16 {
                let lo = q(-Float((b * 7 + c * 13) % 900 + 50) / 1024)
                let hi = q(Float((b * 11 + c * 5) % 900 + 50) / 1024)
                let start = b * 16
                let len = min(16, frames - start)
                for i in 0..<len { s[start + i] = q((lo + hi) / 2 * 0.25) }
                s[start + (b * 3) % len] = lo
                s[start + (b * 5 + 1) % len] = hi
            }
            return s
        }
    }

    private func expected(_ samples: [Float], blockSize: Int) -> [(Float, Float)] {
        stride(from: 0, to: samples.count, by: blockSize).map { start in
            let slice = samples[start..<min(samples.count, start + blockSize)]
            return (slice.min()!, slice.max()!)
        }
    }

    private func check(_ pyramid: PeakPyramid, against signal: [[Float]], file: StaticString = #filePath, line: UInt = #line) {
        for (li, bs) in PeakPyramid.blockSizes.enumerated() {
            for c in 0..<signal.count {
                let exp = expected(signal[c], blockSize: bs)
                XCTAssertEqual(pyramid.levels[li].blockCount, exp.count, file: file, line: line)
                for (b, e) in exp.enumerated() {
                    let got = pyramid.minMax(level: li, block: b, channel: c)
                    if got.min != e.0 || got.max != e.1 {
                        XCTFail("level \(bs) block \(b) ch \(c): got \(got) want \(e)", file: file, line: line)
                        return
                    }
                }
            }
        }
    }

    func testEveryLevelReproducesKnownExtremesFromMemory() throws {
        // Not a multiple of 65536, so every level has a partial tail block.
        let signal = synthesize(frames: 65536 * 9 + 12345, channels: 2)
        let pyramid = try PeakPyramid.build(source: MemorySource(samples: signal), sampleRate: 48000)
        check(pyramid, against: signal)
    }

    func testEveryLevelReproducesKnownExtremesFromFileAndRoundtrips() throws {
        let dir = TestAudio.tempDirectory()
        let url = dir.appendingPathComponent("signal.caf")
        let signal = synthesize(frames: 65536 * 5 + 777, channels: 2)
        try TestAudio.write(signal, sampleRate: 44100, to: url)
        let pyramid = try PeakPyramid.build(url: url)
        check(pyramid, against: signal)

        let peaksURL = dir.appendingPathComponent("signal.peaks")
        try pyramid.write(to: peaksURL)
        let reread = try PeakPyramid.read(from: peaksURL)
        XCTAssertEqual(reread.frameCount, pyramid.frameCount)
        XCTAssertEqual(reread.sampleRate, 44100)
        check(reread, against: signal)
    }

    func testColumnsAggregateBlocks() throws {
        var s = [Float](repeating: 0, count: 4096)
        s[100] = 0.5
        s[3000] = -0.25
        let pyramid = try PeakPyramid.build(source: MemorySource(samples: [s]), sampleRate: 48000)
        var mins = [Float](repeating: 0, count: 2), maxs = [Float](repeating: 0, count: 2)
        pyramid.columns(start: 0, framesPerColumn: 2048, count: 2, channel: 0, level: 0, mins: &mins, maxs: &maxs)
        XCTAssertEqual(maxs[0], 0.5)
        XCTAssertEqual(mins[1], -0.25)
        XCTAssertEqual(pyramid.levelIndex(framesPerColumn: 300), 1)
        XCTAssertNil(pyramid.levelIndex(framesPerColumn: 8))
    }

    func testCorruptPeakFileIsRejected() throws {
        let url = TestAudio.tempDirectory().appendingPathComponent("bad.peaks")
        try Data(repeating: 7, count: 1000).write(to: url)
        XCTAssertThrowsError(try PeakPyramid.read(from: url))
    }

    /// AVAudioFile returns mono float32 WAV in multiples of 1024 frames; the last partial block must still be read.
    func testMonoFloatFileTailIsRead() throws {
        let n = 48000
        let s = (0..<n).map { 0.25 + Float($0 % 7) / 100 }
        let url = TestAudio.tempDirectory().appendingPathComponent("tail.wav")
        try TestAudio.write([s], sampleRate: 48000, to: url, bitDepth: 32)
        let pyramid = try PeakPyramid.build(url: url)
        let last = pyramid.minMax(level: 0, block: pyramid.levels[0].blockCount - 1, channel: 0)
        XCTAssertEqual(last.min, 0.25, accuracy: 1e-6)
        let out = SampleBuffer(channelCount: 1, capacity: n)
        try FileSource(url: url).read(start: 0, count: n, into: out, offset: 0)
        XCTAssertEqual(out.toArrays(count: n)[0], s)
    }
}
