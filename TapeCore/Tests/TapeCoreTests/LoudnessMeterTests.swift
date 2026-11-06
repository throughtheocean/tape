import XCTest
@testable import TapeCore

/// Live loudness through the playback engine, against EBU Tech 3341 and the offline BS.1770 measurement.
final class LoudnessMeterTests: XCTestCase {
    private let rate = 48000.0

    private func sine(dBFS: Double, seconds: Double, frequency: Double = 1000) -> [Float] {
        let a = pow(10, dBFS / 20)
        return (0..<Int(seconds * rate)).map { Float(a * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    /// Plays `channels` through a manual engine from the start and feeds the meter as the UI does.
    private func play(_ channels: [[Float]], meter: inout LoudnessMeter) throws {
        let id = UUID()
        let frames = channels[0].count
        let region = Region(name: "r", sourceId: id, sourceIn: 0, sourceOut: Int64(frames), position: 0)
        let list = EditList(regions: [region], sources: [id: MemorySource(samples: channels)], channelCount: channels.count,
                            tracks: [TrackMix(id: Track.firstID)])
        let engine = PlaybackEngine()
        try engine.configure(sessionRate: rate, channelCount: channels.count, manualRendering: true)
        engine.setEditList(list)
        engine.play(from: 0)
        var done = 0
        while done < frames {
            let n = min(24000, frames - done)
            _ = try engine.renderManual(frames: n)
            done += n
            for e in engine.meters.drain()?.loudness ?? [] { meter.add(energy: e.energy, frames: e.frames) }
        }
        engine.shutdown()
    }

    /// EBU 3341 cases 1 and 2: a stereo 1 kHz sine at -23 and -33 dBFS per channel reads -23 and -33 LUFS.
    func testSteadySineReadsItsLevel() throws {
        for level in [-23.0, -33.0] {
            let tone = sine(dBFS: level, seconds: 20)
            var meter = LoudnessMeter(sampleRate: rate)
            try play([tone, tone], meter: &meter)
            XCTAssertEqual(meter.momentary, level, accuracy: 0.1)
            XCTAssertEqual(meter.shortTerm, level, accuracy: 0.1)
            XCTAssertEqual(meter.integrated, level, accuracy: 0.1)
        }
    }

    /// EBU 3341 case 3: -36, -23, -36 dBFS for 10, 60 and 10 s. The relative gate keeps the quiet parts out.
    func testRelativeGate() throws {
        let tone = sine(dBFS: -36, seconds: 10) + sine(dBFS: -23, seconds: 60) + sine(dBFS: -36, seconds: 10)
        var meter = LoudnessMeter(sampleRate: rate)
        try play([tone, tone], meter: &meter)
        XCTAssertEqual(meter.integrated, -23, accuracy: 0.1)
        XCTAssertEqual(meter.shortTerm, -36, accuracy: 0.1)
    }

    /// The live meter agrees with the offline measurement Normalize uses, on material with level changes.
    func testIntegratedMatchesOfflineMeasurement() throws {
        var generator = SystemRandomNumberGenerator()
        let frames = Int(rate * 12)
        let left = (0..<frames).map { i -> Float in
            let gain: Float = i < frames / 3 ? 0.05 : (i < 2 * frames / 3 ? 0.3 : 0.1)
            return gain * Float.random(in: -1...1, using: &generator)
        }
        let right = left.enumerated().map { $1 * 0.5 + 0.1 * sin(Float($0) * 0.05) }
        var meter = LoudnessMeter(sampleRate: rate)
        try play([left, right], meter: &meter)
        let offline = Loudness.integrated(AudioBuffer(channels: [left, right], sampleRate: rate))
        XCTAssertEqual(meter.integrated, offline, accuracy: 0.1)
    }

    func testChunksSplitAcrossSteps() {
        // 1000 frame chunks of a constant mean square 0.01 do not line up with the 4800 frame steps.
        var meter = LoudnessMeter(sampleRate: rate)
        for _ in 0..<48 { meter.add(energy: 0.01 * 1000, frames: 1000) }
        let expected = -0.691 + 10 * log10(0.01)
        XCTAssertEqual(meter.momentary, expected, accuracy: 1e-9)
        XCTAssertEqual(meter.integrated, expected, accuracy: 1e-9)
        meter.clearRunning()
        XCTAssertEqual(meter.momentary, -.infinity)
        XCTAssertEqual(meter.integrated, expected, accuracy: 1e-9, "integrated holds after stop")
        meter.reset()
        XCTAssertEqual(meter.integrated, -.infinity)
    }

    func testSilenceIsMinusInfinity() {
        var meter = LoudnessMeter(sampleRate: rate)
        meter.add(energy: 0, frames: 48000)
        XCTAssertEqual(meter.momentary, -.infinity)
        XCTAssertEqual(meter.integrated, -.infinity)
    }
}
