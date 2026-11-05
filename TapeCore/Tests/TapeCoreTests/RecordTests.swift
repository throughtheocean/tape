import AVFoundation
import XCTest
@testable import TapeCore

final class RingBufferTests: XCTestCase {
    func testPreRollKeepsExactlyTheLastTenSecondsOfFifteen() {
        let rate = 48000
        let ring = PreRollBuffer(channelCount: 2, capacity: 10 * rate)
        let total = 15 * rate
        let left = (0..<total).map { Float($0) }
        let right = (0..<total).map { -Float($0) }
        // Odd chunk sizes so writes straddle the wrap point.
        var pos = 0, step = 777
        while pos < total {
            let n = min(step, total - pos)
            left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in
                    ring.write([l.baseAddress! + pos, r.baseAddress! + pos], frames: n)
                }
            }
            pos += n
            step = step == 777 ? 48_001 : 777
        }
        XCTAssertEqual(ring.count, 10 * rate)
        let back = ring.toArrays()
        XCTAssertEqual(back[0], Array(left[(5 * rate)...]))
        XCTAssertEqual(back[1], Array(right[(5 * rate)...]))
    }

    func testPreRollWriteLargerThanCapacityKeepsTail() {
        let ring = PreRollBuffer(channelCount: 1, capacity: 100)
        let data = (0..<1000).map { Float($0) }
        data.withUnsafeBufferPointer { ring.write([$0.baseAddress!], frames: 1000) }
        XCTAssertEqual(ring.toArrays()[0], Array(data[900...]))
    }

    func testTransferRingWrapsAndRefusesOverflow() {
        let ring = PCMRingBuffer(channelCount: 1, capacity: 1000)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 1000)
        defer { out.deallocate() }
        var next: Float = 0, expected: Float = 0
        for _ in 0..<50 {
            let block = (0..<700).map { _ -> Float in next += 1; return next }
            XCTAssertTrue(block.withUnsafeBufferPointer { ring.write([$0.baseAddress!], frames: 700) })
            XCTAssertFalse(block.withUnsafeBufferPointer { ring.write([$0.baseAddress!], frames: 400) }, "must refuse, not overwrite")
            XCTAssertEqual(ring.read(into: [out], maxFrames: 1000), 700)
            for i in 0..<700 {
                expected += 1
                if out[i] != expected { XCTFail("mismatch at \(i)"); return }
            }
        }
    }
}

final class RecordEngineTests: XCTestCase {
    /// Pushes `seconds` of the generator through the engine in tap sized blocks.
    private func push(_ engine: RecordEngine, from start: Int, frames: Int, channels: Int,
                      _ sample: (Int, Int) -> Float) {
        let buffers = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        defer { buffers.forEach { $0.deallocate() } }
        var pos = 0
        while pos < frames {
            let n = min(4096, frames - pos)
            for c in 0..<channels { for i in 0..<n { buffers[c][i] = sample(c, start + pos + i) } }
            engine.push(buffers.map { UnsafePointer($0) }, frames: n)
            pos += n
            if pos % (4096 * 32) == 0 { engine.flush() }
        }
        engine.flush()
    }

    func testClapThreeSecondsBeforeRecordIsInFileWithTenSecondPreRoll() throws {
        let rate = 48000
        let engine = RecordEngine()
        engine.startMonitoring(sampleRate: Double(rate), deviceChannelCount: 2, channels: [0, 1], preRollSeconds: 10)
        let clap = 15 * rate
        let signal: (Int, Int) -> Float = { _, i in (i >= clap && i < clap + 200) ? 0.8 : 0.001 * Float(i % 7) }
        push(engine, from: 0, frames: 18 * rate, channels: 2, signal)

        let url = TestAudio.tempDirectory().appendingPathComponent("take.wav")
        let preRoll = try engine.startRecording(to: url, container: .wav, sampleFormat: .int24)
        XCTAssertEqual(preRoll, Int64(10 * rate))
        push(engine, from: 18 * rate, frames: 2 * rate, channels: 2, signal)
        let result = try XCTUnwrap(engine.stopRecording())
        XCTAssertEqual(result.frames, Int64(12 * rate))
        XCTAssertEqual(result.preRollFrames, Int64(10 * rate))
        XCTAssertEqual(result.dropouts, 0)

        let audio = try TestAudio.read(url)
        XCTAssertEqual(audio[0].count, 12 * rate)
        let clapInFile = clap - 8 * rate
        XCTAssertEqual(audio[0][clapInFile], 0.8, accuracy: 1e-5)
        XCTAssertEqual(audio[1][clapInFile + 199], 0.8, accuracy: 1e-5)
        XCTAssertLessThan(audio[0][clapInFile - 1], 0.01)
        // Continuity across the moment R was pressed.
        for i in (10 * rate - 3)...(10 * rate + 3) {
            XCTAssertEqual(audio[0][i], signal(0, 8 * rate + i), accuracy: 1e-6)
        }
        engine.stopInput()
    }

    func testEveryRecordableFormatRoundTrips() throws {
        let rate = 44100
        let dir = TestAudio.tempDirectory()
        let signal: (Int, Int) -> Float = { c, i in Float(sin(Double(i) * 0.03 + Double(c))) * 0.5 }
        for container in AudioContainer.recordable {
            for format in container.sampleFormats {
                let engine = RecordEngine()
                engine.startMonitoring(sampleRate: Double(rate), deviceChannelCount: 2, channels: [0, 1], preRollSeconds: 0)
                let url = dir.appendingPathComponent("t-\(format.rawValue).\(container.fileExtension(format))")
                try engine.startRecording(to: url, container: container, sampleFormat: format)
                push(engine, from: 0, frames: rate, channels: 2, signal)
                let result = try XCTUnwrap(engine.stopRecording())
                engine.stopInput()
                XCTAssertEqual(result.frames, Int64(rate))
                let audio = try TestAudio.read(url)
                let label = "\(container) \(format)"
                XCTAssertEqual(audio.count, 2, label)
                XCTAssertEqual(audio[0].count, rate, label)
                let tolerance: Float = format == .int16 ? 1.0 / 16000 : (format == .int24 ? 1e-6 : 0)
                var worst: Float = 0
                for i in 0..<rate { worst = max(worst, abs(audio[1][i] - signal(1, i))) }
                XCTAssertLessThanOrEqual(worst, tolerance, label)
            }
        }
    }

    func testRecordsOnlyTheSelectedChannels() throws {
        let engine = RecordEngine()
        engine.startMonitoring(sampleRate: 48000, deviceChannelCount: 4, channels: [2, 3], preRollSeconds: 1)
        let url = TestAudio.tempDirectory().appendingPathComponent("ch.caf")
        try engine.startRecording(to: url, container: .caf, sampleFormat: .float32)
        push(engine, from: 0, frames: 1000, channels: 4) { c, _ in Float(c) / 10 }
        _ = engine.stopRecording()
        let audio = try TestAudio.read(url)
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(audio[0][500], 0.2, accuracy: 1e-7)
        XCTAssertEqual(audio[1][500], 0.3, accuracy: 1e-7)
    }

    func testMetersHoldPeakAndLatchClip() {
        let engine = RecordEngine()
        engine.startMonitoring(sampleRate: 48000, deviceChannelCount: 1, channels: [0], preRollSeconds: 0)
        push(engine, from: 0, frames: 4800, channels: 1) { _, i in i == 100 ? 1.0 : 0.25 }
        var m = engine.currentStatus().meters[0]
        XCTAssertTrue(m.clipped)
        XCTAssertEqual(m.hold, 1.0)
        // Within 1.5 s the hold stays; after it, the hold falls to the current peak.
        push(engine, from: 4800, frames: 48000, channels: 1) { _, _ in 0.25 }
        XCTAssertEqual(engine.currentStatus().meters[0].hold, 1.0)
        push(engine, from: 52800, frames: 48000, channels: 1) { _, _ in 0.25 }
        m = engine.currentStatus().meters[0]
        XCTAssertEqual(m.hold, 0.25, accuracy: 1e-6)
        XCTAssertEqual(m.rms, 0.25, accuracy: 0.01)
        XCTAssertTrue(m.clipped, "clip stays latched")
        engine.resetClip()
        engine.flush()
        XCTAssertFalse(engine.currentStatus().meters[0].clipped)
    }

    func testOverflowCountsDropouts() {
        let engine = RecordEngine()
        engine.startMonitoring(sampleRate: 1000, deviceChannelCount: 1, channels: [0], preRollSeconds: 0)
        let block = [Float](repeating: 0, count: 5000)
        block.withUnsafeBufferPointer { engine.push([$0.baseAddress!], frames: 5000) } // ring holds 4 s = 4000
        XCTAssertEqual(engine.dropouts.load(), 1)
        engine.flush()
        XCTAssertEqual(engine.currentStatus().dropouts, 1)
    }

    func testDeviceListingLeavesSystemDefaultsAlone() {
        let output = AudioDevices.defaultOutputDevice, input = AudioDevices.defaultInputDevice
        let devices = AudioDevices.inputDevices()
        for d in devices {
            XCTAssertGreaterThan(d.channelCount, 0)
            XCTAssertFalse(d.channelChoices.isEmpty)
        }
        XCTAssertEqual(AudioDevices.defaultOutputDevice, output)
        XCTAssertEqual(AudioDevices.defaultInputDevice, input)
    }

    /// Opt in: TAPE_HW=1. Records 2 s from every input device through AVAudioEngine.
    func testRecordsFromHardwareWithoutChangingSystemDevices() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAPE_HW"] == "1", "set TAPE_HW=1")
        let output = AudioDevices.defaultOutputDevice, input = AudioDevices.defaultInputDevice
        let dir = TestAudio.tempDirectory()
        for device in AudioDevices.inputDevices() {
            let engine = RecordEngine()
            let channels = device.channelChoices[0]
            try engine.startInput(device: device, channels: channels, preRollSeconds: 1)
            Thread.sleep(forTimeInterval: 1.2)
            let url = dir.appendingPathComponent("\(device.id).wav")
            let preRoll = try engine.startRecording(to: url, container: .wav, sampleFormat: .int24)
            Thread.sleep(forTimeInterval: 1)
            let result = try XCTUnwrap(engine.stopRecording())
            engine.stopInput()
            print("hardware \(device.name): \(device.channelCount) ch at \(result.sampleRate) Hz, channels \(InputDevice.label(channels)), "
                + "pre-roll \(preRoll), frames \(result.frames), dropouts \(result.dropouts)")
            XCTAssertEqual(Double(preRoll), result.sampleRate, accuracy: result.sampleRate * 0.05, device.name)
            XCTAssertEqual(Double(result.frames), 2 * result.sampleRate, accuracy: result.sampleRate * 0.25, device.name)
            XCTAssertEqual(result.channelCount, channels.count)
            XCTAssertEqual(result.dropouts, 0, device.name)
            XCTAssertEqual(AudioDevices.defaultOutputDevice, output)
            XCTAssertEqual(AudioDevices.defaultInputDevice, input)
        }
    }

    /// Opt in: TAPE_PERF=1. 30 minutes of 96 kHz stereo 24 bit pushed at 30x real time in tap sized blocks.
    func testThirtyMinutesAt96kHasNoDropouts() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAPE_PERF"] == "1", "set TAPE_PERF=1")
        let rate = 96000, minutes = 30, speedup = 30.0
        let engine = RecordEngine()
        engine.startMonitoring(sampleRate: Double(rate), deviceChannelCount: 2, channels: [0, 1], preRollSeconds: 10)
        let url = TestAudio.tempDirectory().appendingPathComponent("long.wav")
        try engine.startRecording(to: url, container: .wav, sampleFormat: .int24)
        let block = 4096
        let data = (0..<2).map { c in (0..<block).map { Float(sin(Double($0 + c) * 0.01)) * 0.5 } }
        let total = rate * 60 * minutes
        let start = Date()
        var pushed = 0
        while pushed < total {
            data[0].withUnsafeBufferPointer { l in
                data[1].withUnsafeBufferPointer { r in engine.push([l.baseAddress!, r.baseAddress!], frames: block) }
            }
            pushed += block
            let due = Double(pushed) / Double(rate) / speedup
            let wait = due - Date().timeIntervalSince(start)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        let result = try XCTUnwrap(engine.stopRecording())
        print("30 min 96k stereo 24 bit: \(result.frames) frames, dropouts \(result.dropouts), wall \(Date().timeIntervalSince(start)) s")
        XCTAssertEqual(result.dropouts, 0)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, Int64(pushed + 0))
        try? FileManager.default.removeItem(at: url)
    }
}
