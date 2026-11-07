import XCTest
@testable import TapeCore

/// Placement of a recording made while playing.
final class OverdubTests: XCTestCase {
    /// A fake device: 10 ms input latency (device, safety offset, stream), 5 ms output latency.
    private let input = DeviceLatency(deviceFrames: 336, safetyFrames: 96, streamFrames: 48, bufferFrames: 256, sampleRate: 48000)
    private let output = DeviceLatency(deviceFrames: 160, safetyFrames: 64, streamFrames: 16, bufferFrames: 256, sampleRate: 48000)

    func testDeviceLatencySeconds() {
        XCTAssertEqual(input.hardwareSeconds, 0.010, accuracy: 1e-12)
        XCTAssertEqual(output.hardwareSeconds, 0.005, accuracy: 1e-12)
        XCTAssertEqual(input.bufferSeconds, 256.0 / 48000, accuracy: 1e-12)
        XCTAssertEqual(Overdub.monitoringSeconds(input: input, output: output), 0.015 + 512.0 / 48000, accuracy: 1e-12)
    }

    /// Playback hands frame 96000 to the output at 100 s. A frame captured at 100.5 s was played against what was
    /// audible 10 ms earlier, which playback had rendered 5 ms before that: 100.485 s, frame 96000 + 0.485 · 48000.
    func testPlacementSubtractsInputAndOutputLatency() {
        let render = Overdub.RenderAnchor(position: 96000, hostSeconds: 100)
        let p = Overdub.position(of: 100.5, render: render, inputLatency: input.hardwareSeconds, outputLatency: output.hardwareSeconds,
                                 sessionRate: 48000)
        XCTAssertEqual(p, 96000 + 23280)
        let none = Overdub.position(of: 100.5, render: render, inputLatency: 0, outputLatency: 0, sessionRate: 48000)
        XCTAssertEqual(none - p, 720, "15 ms at 48 kHz")
    }

    /// The input stamps each tap buffer; the first live frame after the pre-roll gets the host time of its own
    /// position in the stream, whichever buffer it falls in.
    func testFirstLiveFrameHostTimeFromBufferStamps() throws {
        let rate = 48000.0
        let engine = RecordEngine()
        engine.startMonitoring(sampleRate: rate, deviceChannelCount: 1, channels: [0], preRollSeconds: 1)
        let block = [Float](repeating: 0.25, count: 4096)
        for i in 0..<3 {
            block.withUnsafeBufferPointer { engine.push([$0.baseAddress!], frames: 4096, hostSeconds: 10 + Double(i * 4096) / rate) }
        }
        engine.flush()
        let url = TestAudio.tempDirectory().appendingPathComponent("overdub.wav")
        let preRoll = try engine.startRecording(to: url, container: .wav, sampleFormat: .int24)
        XCTAssertEqual(preRoll, 12288)
        let live = try XCTUnwrap(engine.lastLiveStartHostSeconds)
        XCTAssertEqual(live, 10 + 12288 / rate, accuracy: 1e-9)

        // That frame was played against playback frame 48000 + 1.256 s · 48000 - 15 ms.
        let render = Overdub.RenderAnchor(position: 48000, hostSeconds: 9)
        let p = Overdub.position(of: live, render: render, inputLatency: input.hardwareSeconds, outputLatency: output.hardwareSeconds,
                                 sessionRate: rate)
        XCTAssertEqual(p, 48000 + Int64(((10 + 12288 / rate - 9 - 0.015) * rate).rounded()))
        _ = engine.stopRecording()
        engine.stopInput()
    }

    /// An input at 44.1 kHz in a 48 kHz session: host times are in seconds, so the rates do not mix.
    func testInputRateDiffersFromSession() {
        let live = Overdub.hostSeconds(ofFrame: 44100, anchorFrame: 0, anchorHostSeconds: 50, sampleRate: 44100)
        XCTAssertEqual(live, 51, accuracy: 1e-12)
        let p = Overdub.position(of: live, render: Overdub.RenderAnchor(position: 0, hostSeconds: 50), inputLatency: 0.010,
                                 outputLatency: 0, sessionRate: 48000)
        XCTAssertEqual(p, 48000 - 480)
    }
}
