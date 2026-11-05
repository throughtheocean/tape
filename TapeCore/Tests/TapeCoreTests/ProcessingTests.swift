import XCTest
@testable import TapeCore

final class LoudnessTests: XCTestCase {
    private func sine(_ hz: Double, amplitude: Double, seconds: Double, rate: Double, phase: Double = 0) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate + phase)) }
    }

    private func dB(_ v: Double) -> Double { pow(10, v / 20) }

    /// Section 11: a 997 Hz sine at -20 dBFS in one channel measures -20.0 LUFS.
    /// dBFS here is the sine's RMS relative to full scale (peak 0.1414). A sine with a -20 dBFS peak reads
    /// -23.01 LUFS, consistent with BS.1770's -3.01 LUFS for a full scale sine; both are checked.
    func testSineInOneChannelAtEveryRate() {
        for rate in [44100.0, 48000, 96000] {
            let rms = sine(997, amplitude: dB(-20) * sqrt(2), seconds: 10, rate: rate)
            let silent = [Float](repeating: 0, count: rms.count)
            let l = Loudness.integrated(AudioBuffer(channels: [rms, silent], sampleRate: rate))
            print(String(format: "997 Hz RMS -20 dBFS one channel at %.0f Hz: %.3f LUFS", rate, l))
            XCTAssertEqual(l, -20.0, accuracy: 0.1, "RMS -20 dBFS at \(rate)")

            let peak = sine(997, amplitude: dB(-20), seconds: 10, rate: rate)
            let lp = Loudness.integrated(AudioBuffer(channels: [peak, silent], sampleRate: rate))
            XCTAssertEqual(lp, -23.01, accuracy: 0.1, "peak -20 dBFS at \(rate)")
        }
    }

    /// EBU Tech 3341 cases 1 to 5: 1 kHz stereo, levels per channel in dBFS peak.
    func testEBUTech3341GatingCases() {
        let rate = 48000.0
        func program(_ parts: [(Double, Double)]) -> AudioBuffer {
            var s: [Float] = []
            for (level, seconds) in parts { s += sine(1000, amplitude: dB(level), seconds: seconds, rate: rate) }
            return AudioBuffer(channels: [s, s], sampleRate: rate)
        }
        let cases: [(String, [(Double, Double)], Double)] = [
            ("1", [(-23, 20)], -23),
            ("2", [(-33, 20)], -33),
            ("3", [(-36, 10), (-23, 60), (-36, 10)], -23),
            ("4", [(-72, 10), (-36, 10), (-23, 60), (-36, 10), (-72, 10)], -23),
            ("5", [(-26, 20), (-20, 20.1), (-26, 20)], -23),
        ]
        for (name, parts, expected) in cases {
            let l = Loudness.integrated(program(parts))
            print(String(format: "EBU 3341 case %@: %.3f LUFS (expected %.1f)", name, l, expected))
            XCTAssertEqual(l, expected, accuracy: 0.1, "case \(name)")
        }
    }

    func testSilenceIsMinusInfinity() {
        let l = Loudness.integrated(AudioBuffer(frames: 48000 * 2, channelCount: 2, sampleRate: 48000))
        XCTAssertEqual(l, -.infinity)
    }

    /// Section 11: adjacent samples at 0.9 and -0.9 at 44.1 kHz. Read as the classic pattern
    /// 0.9, 0.9, -0.9, -0.9 (a quarter rate sine sampled 45 degrees off its peaks), whose true peak is
    /// 0.9 times the square root of 2, about +2.1 dBTP, while the sample peak is -0.9 dBFS.
    func testInterSamplePeakReadsAboveZero() {
        let pattern: [Float] = [0.9, 0.9, -0.9, -0.9]
        let s = (0..<44100).map { pattern[$0 % 4] }
        let buffer = AudioBuffer(channels: [s], sampleRate: 44100)
        let tp = Loudness.truePeakDB(buffer)
        print(String(format: "Inter-sample peak case: %.3f dBTP", tp))
        XCTAssertGreaterThan(tp, 0)
        XCTAssertEqual(tp, 20 * log10(0.9 * sqrt(2)), accuracy: 0.1)
        XCTAssertLessThan(20 * log10(Double(buffer.peak())), 0)
    }

    func testTruePeakOfLowSineEqualsSamplePeak() {
        let s = sine(100, amplitude: 0.5, seconds: 1, rate: 48000)
        XCTAssertEqual(Double(Loudness.truePeak(AudioBuffer(channels: [s], sampleRate: 48000))), 0.5, accuracy: 0.001)
    }
}

final class ProcessTests: XCTestCase {
    private func music(seconds: Double, rate: Double = 48000, level: Double = 0.1) -> AudioBuffer {
        let n = Int(seconds * rate)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let t = Double(i) / rate
            let env = 0.6 + 0.4 * sin(2 * .pi * 0.5 * t)
            l[i] = Float(level * env * (sin(2 * .pi * 220 * t) + 0.5 * sin(2 * .pi * 1100 * t) + 0.25 * sin(2 * .pi * 4400 * t)))
            r[i] = Float(level * env * (sin(2 * .pi * 330 * t) + 0.4 * sin(2 * .pi * 2200 * t)))
        }
        return AudioBuffer(channels: [l, r], sampleRate: rate)
    }

    /// Section 11: output peak equals the target within 0.01 dB.
    func testNormalizePeak() throws {
        let input = music(seconds: 3)
        let out = try Normalize(mode: .peak(targetDB: -1)).render(input: input, range: input.all)
        XCTAssertEqual(20 * log10(Double(out.peak())), -1, accuracy: 0.01)
    }

    /// M4 acceptance: a loudness normalize to -14 LUFS measures -14.0 within 0.1 when re-analysed.
    func testNormalizeLoudnessRemeasures() throws {
        let input = music(seconds: 20, level: 0.02)
        XCTAssertLessThan(Loudness.integrated(input), -25)
        let out = try Normalize(mode: .loudness(targetLUFS: -14, ceilingDBTP: -1)).render(input: input, range: input.all)
        print(String(format: "Normalize to -14 LUFS re-measures %.3f LUFS, %.2f dBTP", Loudness.integrated(out), Loudness.truePeakDB(out)))
        XCTAssertEqual(Loudness.integrated(out), -14, accuracy: 0.1)
        XCTAssertLessThanOrEqual(Loudness.truePeakDB(out), -1 + 0.01)
    }

    func testNormalizeLoudnessHonoursTheTruePeakCeiling() throws {
        // Sparse clicks: loud peaks, low loudness, so reaching -14 LUFS would clip.
        var s = [Float](repeating: 0, count: 48000 * 5)
        for i in stride(from: 0, to: s.count, by: 4800) { s[i] = 0.5 }
        let input = AudioBuffer(channels: [s, s], sampleRate: 48000)
        let out = try Normalize(mode: .loudness(targetLUFS: -14, ceilingDBTP: -1)).render(input: input, range: input.all)
        XCTAssertEqual(Loudness.truePeakDB(out), -1, accuracy: 0.05)
        XCTAssertLessThan(Loudness.integrated(out), -14)
    }

    func testGainOnlyInsideRange() throws {
        let input = music(seconds: 1)
        let range = SampleRange(start: 1000, end: 2000)
        let out = try Gain(dB: -6).render(input: input, range: range)
        XCTAssertEqual(out.channels[0][999], input.channels[0][999])
        XCTAssertEqual(out.channels[0][1500], input.channels[0][1500] * Float(pow(10, -6.0 / 20)), accuracy: 1e-7)
        XCTAssertEqual(out.channels[1][2000], input.channels[1][2000])
    }

    func testRemoveDC() throws {
        var input = music(seconds: 1)
        input.channels[0] = input.channels[0].map { $0 + 0.2 }
        let out = try RemoveDC().render(input: input, range: input.all)
        let mean = out.channels[0].reduce(0, +) / Float(out.frameCount)
        XCTAssertEqual(mean, 0, accuracy: 1e-4)
    }

    func testReverseTwiceIsIdentity() throws {
        let input = music(seconds: 0.5)
        let range = SampleRange(start: 100, end: 9000)
        let once = try Reverse().render(input: input, range: range)
        XCTAssertEqual(once.channels[0][100], input.channels[0][8999])
        XCTAssertEqual(try Reverse().render(input: once, range: range), input)
    }

    func testTrimSilenceBoundsKeepHold() {
        var s = [Float](repeating: 0.0001, count: 48000)
        for i in 10000..<20000 { s[i] = 0.5 }
        let buffer = AudioBuffer(channels: [s], sampleRate: 48000)
        let keep = TrimSilence(thresholdDB: -60, holdMs: 10).bounds(buffer, range: buffer.all)
        XCTAssertEqual(keep, SampleRange(start: 10000 - 480, end: 20000 + 480))
    }

    func testCompressorReducesLoudSignal() throws {
        let rate = 48000.0
        let s = (0..<Int(rate)).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / rate)) }
        let input = AudioBuffer(channels: [s, s], sampleRate: rate)
        let out = try Dynamics.compressor(threshold: -30, headroom: 5, attack: 0.001, release: 0.05).render(input: input, range: input.all)
        XCTAssertEqual(out.frameCount, input.frameCount)
        let tail = SampleRange(start: 24000, end: 48000)
        XCTAssertLessThan(out.peak(in: tail), input.peak(in: tail) * 0.7)
    }

    /// The limiter's look-ahead latency is removed: a signal below its threshold comes out aligned and unchanged.
    func testLimiterIsLatencyCompensated() throws {
        let rate = 48000.0
        let s = (0..<Int(rate)).map { Float(0.1 * sin(2 * .pi * 440 * Double($0) / rate)) }
        let input = AudioBuffer(channels: [s], sampleRate: rate)
        let out = try Dynamics.limiter().render(input: input, range: input.all)
        var worst: Float = 0
        for i in 4800..<43200 { worst = max(worst, abs(out.channels[0][i] - s[i])) }
        XCTAssertLessThan(worst, 0.005)
    }

    func testResampleKeepsDurationAndPitch() throws {
        let input = AudioBuffer(channels: [(0..<48000).map { Float(sin(2 * .pi * 1000 * Double($0) / 48000)) }], sampleRate: 48000)
        let out = try Resample(sampleRate: 44100).render(input: input, range: input.all)
        XCTAssertEqual(out.sampleRate, 44100)
        XCTAssertEqual(out.frameCount, 44100)
        var crossings = 0
        for i in 1000..<43000 where out.channels[0][i - 1] < 0 && out.channels[0][i] >= 0 { crossings += 1 }
        XCTAssertEqual(Double(crossings), 1000 * 42000 / 44100, accuracy: 2)
    }

    /// A partial process leaves everything outside the range untouched and blends over 2 ms at its edges.
    func testApplierWritesWholeSourceWithCrossfadedRange() throws {
        let input = music(seconds: 2)
        let source = MemorySource(samples: input.channels)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apply-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let range = SampleRange(start: 20000, end: 60000)
        let result = try ProcessApplier.render(source: source, sampleRate: 48000, process: Gain(dB: -12), range: range,
                                               crossfade: true, to: url)
        XCTAssertEqual(result.frames, Int64(input.frameCount))
        let back = try FileSource(url: url)
        let read = ProcessApplier.read(back, range: SampleRange(start: 0, end: back.frameCount), sampleRate: 48000)
        let g = Float(pow(10, -12.0 / 20))
        for i in [0, 19999, 60000, 95999] { XCTAssertEqual(read.channels[0][i], input.channels[0][i]) }
        for i in [20096, 40000, 59903] { XCTAssertEqual(read.channels[0][i], input.channels[0][i] * g, accuracy: 1e-6) }
        // Inside the first 2 ms the level is between original and processed.
        let k = 20048
        let lo = min(input.channels[0][k], input.channels[0][k] * g), hi = max(input.channels[0][k], input.channels[0][k] * g)
        XCTAssertTrue(read.channels[0][k] >= lo - 1e-6 && read.channels[0][k] <= hi + 1e-6)
    }
}
