import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// Input capture with a pre-roll history, metering and file writing.
///
/// Threads: the input tap (or `push` in tests) copies frames into a lock-free ring and never
/// waits. A dedicated serial writer queue drains the ring every 10 ms, updates meters, keeps the
/// pre-roll history and, while recording, writes to the file.
public final class RecordEngine: @unchecked Sendable {
    public struct ChannelMeter: Equatable, Sendable {
        /// Linear sample peak of the last drained block.
        public var peak: Float = 0
        /// Linear RMS over roughly the last 300 ms.
        public var rms: Float = 0
        /// Highest peak within the last 1.5 s.
        public var hold: Float = 0
        /// Latched when a sample reached full scale, until `resetClip`.
        public var clipped = false
    }

    public struct Status: Equatable, Sendable {
        public var isMonitoring = false
        public var isRecording = false
        public var sampleRate: Double = 0
        public var meters: [ChannelMeter] = []
        /// Frames in the file so far, pre-roll included.
        public var recordedFrames: Int64 = 0
        public var preRollFrames: Int64 = 0
        public var dropouts: Int64 = 0
        public var error: String?
    }

    public struct Recording: Sendable {
        public var url: URL
        public var frames: Int64
        public var preRollFrames: Int64
        public var sampleRate: Double
        public var channelCount: Int
        public var dropouts: Int64
    }

    public static let peakHoldSeconds = 1.5
    public static let clipLevel: Float = 0.9999
    static let chunkFrames = 4096

    private let queue = DispatchQueue(label: "tape.record.writer", qos: .userInitiated)
    private let statusLock = NSLock()
    private var status = Status()

    /// Producer side, replaced on every configuration.
    private let producerLock = NSLock()
    private var producer: Producer?
    private var engine: AVAudioEngine?
    /// Through monitoring plays on its own engine: an engine's input and output unit share one device.
    private var monitor: AVAudioEngine?

    // Writer queue state.
    private var ring: PCMRingBuffer?
    private var history: PreRollBuffer?
    private var chunk: AVAudioPCMBuffer?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var recordedFrames: Int64 = 0
    private var preRollFrames: Int64 = 0
    private var dropoutsAtStart: Int64 = 0
    private var monitoredFrames: Int64 = 0
    private var holdTimes: [Int64] = []
    private var meters: [ChannelMeter] = []
    private var timer: DispatchSourceTimer?
    private var sampleRate: Double = 0

    public init() {}

    deinit {
        engine?.stop()
        timer?.cancel()
    }

    // MARK: Configuration

    /// Starts monitoring without hardware; frames arrive through `push`. Used by tests and by `startInput`.
    public func startMonitoring(sampleRate: Double, deviceChannelCount: Int, channels: [Int], preRollSeconds: Double) {
        let selected = channels.filter { $0 < deviceChannelCount }
        let channelCount = max(1, selected.count)
        let ring = PCMRingBuffer(channelCount: channelCount, capacity: Int(sampleRate * 4))
        queue.sync {
            closeFile()
            self.sampleRate = sampleRate
            self.ring = ring
            history = PreRollBuffer(channelCount: channelCount, capacity: Int(sampleRate * min(max(preRollSeconds, 0), 60)))
            let format = AVAudioFormat.deinterleavedFloat(sampleRate: sampleRate, channels: channelCount)
            chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunkFrames))
            monitoredFrames = 0
            meters = Array(repeating: ChannelMeter(), count: channelCount)
            holdTimes = Array(repeating: 0, count: channelCount)
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
                t.setEventHandler { [weak self] in self?.drain() }
                t.resume()
                timer = t
            }
        }
        producerLock.withLock { producer = Producer(ring: ring, selected: selected.isEmpty ? [0] : selected, dropouts: dropouts) }
        updateStatus { s in
            s.isMonitoring = true
            s.isRecording = false
            s.sampleRate = sampleRate
            s.meters = Array(repeating: ChannelMeter(), count: channelCount)
            s.recordedFrames = 0
            s.preRollFrames = 0
            s.error = nil
        }
    }

    /// Opens `device` through AVAudioEngine and starts monitoring the chosen channels (zero based).
    /// Only the engine's own input unit is pointed at the device; system defaults are not touched.
    /// With `through`, the chosen channels also play on the default output (a mono channel on both sides).
    public func startInput(device: InputDevice, channels: [Int], preRollSeconds: Double, through: Bool = false) throws {
        stopInput()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.auAudioUnit.setDeviceID(device.id)
        // After a device change only the input side format is current; the output side keeps the old one.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw TapeError.failed("\(device.name) has no input format") }
        let format = AVAudioFormat.deinterleavedFloat(sampleRate: hardware.sampleRate, channels: Int(hardware.channelCount))
        startMonitoring(sampleRate: format.sampleRate, deviceChannelCount: Int(format.channelCount), channels: channels,
                        preRollSeconds: preRollSeconds)
        guard let producer = producerLock.withLock({ producer }) else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            producer.push(buffer, when: when)
        }
        let monitor = through ? connectThrough(engine, input: format, selected: producer.selected) : nil
        engine.prepare()
        try engine.start()
        self.engine = engine
        if let monitor {
            monitor.prepare()
            try monitor.start()
            self.monitor = monitor
        }
    }

    /// Level of Through monitoring, 1 is unity.
    public var monitorVolume: Float = 1 {
        didSet { monitor?.mainMixerNode.outputVolume = monitorVolume }
    }

    /// Frames Through monitoring has played since the input started, and the device it plays on.
    public var throughFrames: Int { throughCount.withLock { $0 } }
    public var throughDevice: AudioDeviceID? { monitor?.outputNode.auAudioUnit.deviceID }
    private let throughCount = OSAllocatedUnfairLock(initialState: 0)

    /// Input monitoring: a sink on the input engine takes the chosen channels each IO cycle into a small ring,
    /// a source on an output engine (default output) plays them. The ring is kept short, so the delay stays at
    /// about one buffer on top of the devices' own latency; drift between the two devices drops or pads frames.
    private func connectThrough(_ engine: AVAudioEngine, input format: AVAudioFormat, selected: [Int]) -> AVAudioEngine {
        let picked = selected.map { min($0, Int(format.channelCount) - 1) }
        let ring = PCMRingBuffer(channelCount: picked.count, capacity: 16384)
        let sink = AVAudioSinkNode { _, frames, list -> OSStatus in
            ring.write(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)), channels: picked, frames: Int(frames))
            return noErr
        }
        let stereo = AVAudioFormat.deinterleavedFloat(sampleRate: format.sampleRate, channels: 2)
        let scratch = SampleBuffer(channelCount: picked.count, capacity: 8192)
        let count = throughCount
        count.withLock { $0 = 0 }
        let source = AVAudioSourceNode(format: stereo) { _, _, frames, list -> OSStatus in
            let out = UnsafeMutableAudioBufferListPointer(list)
            let n = Int(frames)
            // More than two buffers waiting means the input ran ahead: drop the excess to keep the delay short.
            let excess = ring.available - 2 * n
            if excess > 0 { _ = ring.read(into: scratch.channels, maxFrames: min(excess, scratch.capacity)) }
            let got = ring.read(into: scratch.channels, maxFrames: min(n, scratch.capacity))
            for c in 0..<min(2, out.count) {
                guard let dst = out[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                dst.update(from: scratch.channels[min(c, picked.count - 1)], count: got)
                (dst + got).update(repeating: 0, count: n - got)
            }
            count.withLock { $0 += got }
            return noErr
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: format)
        let monitor = AVAudioEngine()
        monitor.attach(source)
        monitor.connect(source, to: monitor.mainMixerNode, format: stereo)
        monitor.mainMixerNode.outputVolume = monitorVolume
        return monitor
    }

    public func stopInput() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        monitor?.stop()
        monitor = nil
        producerLock.withLock { producer = nil }
        queue.sync {
            timer?.cancel()
            timer = nil
            drain()
            closeFile()
            ring = nil
        }
        updateStatus { s in
            s.isMonitoring = false
            s.isRecording = false
            s.meters = s.meters.map { _ in ChannelMeter() }
        }
    }

    // MARK: Input

    /// Total refused writes and input discontinuities since monitoring started.
    public let dropouts = AtomicInt64()

    /// Feeds frames as the tap would: one pointer per device channel, optionally with the host time (seconds) of
    /// the first frame.
    public func push(_ deviceChannels: [UnsafePointer<Float>], frames: Int, hostSeconds: Double? = nil) {
        producerLock.withLock { producer }?.push(deviceChannels, frames: frames, hostSeconds: hostSeconds)
    }

    // MARK: Recording

    /// Starts writing: the pre-roll history first, then live input. Returns the pre-roll frame count.
    @discardableResult
    public func startRecording(to url: URL, container: AudioContainer, sampleFormat: SampleFormat) throws -> Int64 {
        try queue.sync {
            guard let history, let chunk else { throw TapeError.failed("No input is selected") }
            drain()
            let format = AudioFileFormat(container: container, sampleFormat: sampleFormat, sampleRate: sampleRate,
                                         channelCount: history.channelCount)
            let file = try format.createFile(at: url)
            let preRoll = history.count
            try history.forEachPiece { pointers, frames in
                var done = 0
                while done < frames {
                    let n = min(Self.chunkFrames, frames - done)
                    for c in 0..<pointers.count { chunk.floatChannelData![c].update(from: pointers[c] + done, count: n) }
                    chunk.frameLength = AVAudioFrameCount(n)
                    try file.write(from: chunk)
                    done += n
                }
            }
            self.file = file
            fileURL = url
            let live = monitoredFrames
            lastLiveStartHostSeconds = producerLock.withLock { producer }?.hostSeconds(ofFrame: live, sampleRate: sampleRate)
            recordedFrames = Int64(preRoll)
            preRollFrames = Int64(preRoll)
            dropoutsAtStart = dropouts.load()
            let frames = recordedFrames
            updateStatus { s in
                s.isRecording = true
                s.recordedFrames = frames
                s.preRollFrames = Int64(preRoll)
                s.dropouts = 0
                s.error = nil
            }
            return Int64(preRoll)
        }
    }

    /// Host time, in seconds, the first live frame (after the pre-roll) of the last recording reached the input
    /// IO buffer; nil when the input gives no timestamps (tests that push frames without one).
    public private(set) var lastLiveStartHostSeconds: Double?

    /// Writes what is buffered, closes the file and returns what was recorded.
    public func stopRecording() -> Recording? {
        queue.sync {
            drain()
            guard file != nil, let url = fileURL else { return nil }
            let result = Recording(url: url, frames: recordedFrames, preRollFrames: preRollFrames, sampleRate: sampleRate,
                                   channelCount: history?.channelCount ?? 1, dropouts: dropouts.load() - dropoutsAtStart)
            closeFile()
            updateStatus { $0.isRecording = false }
            return result
        }
    }

    public func currentStatus() -> Status {
        statusLock.withLock { status }
    }

    public func resetClip() {
        queue.async { [self] in
            for i in meters.indices { meters[i].clipped = false }
            let m = meters
            updateStatus { $0.meters = m }
        }
    }

    /// Waits until everything pushed so far has been processed.
    public func flush() {
        queue.sync { drain() }
    }

    // MARK: Writer queue

    private func closeFile() {
        file = nil
        fileURL = nil
    }

    private func drain() {
        guard let ring, let chunk, let history else { return }
        let channels = (0..<ring.channelCount).map { chunk.floatChannelData![$0] }
        while true {
            let n = ring.read(into: channels, maxFrames: Self.chunkFrames)
            if n == 0 { break }
            chunk.frameLength = AVAudioFrameCount(n)
            meter(channels, frames: n)
            history.write(channels.map { UnsafePointer($0) }, frames: n)
            monitoredFrames += Int64(n)
            if let file {
                do {
                    try file.write(from: chunk)
                    recordedFrames += Int64(n)
                } catch {
                    closeFile()
                    let message = "Recording stopped: \(error.localizedDescription)"
                    updateStatus { s in
                        s.isRecording = false
                        s.error = message
                    }
                }
            }
        }
        let m = meters, frames = recordedFrames, drops = dropouts.load() - (file != nil ? dropoutsAtStart : 0)
        updateStatus { s in
            s.meters = m
            if s.isRecording { s.recordedFrames = frames }
            s.dropouts = drops
        }
    }

    private func meter(_ channels: [UnsafeMutablePointer<Float>], frames: Int) {
        let holdFrames = Int64(Self.peakHoldSeconds * sampleRate)
        // Exponential RMS with a time constant of about 300 ms.
        let alpha = Float(1 - Foundation.exp(-Double(frames) / (0.3 * max(sampleRate, 1))))
        for c in 0..<channels.count {
            var peak: Float = 0
            vDSP_maxmgv(channels[c], 1, &peak, vDSP_Length(frames))
            var meanSquare: Float = 0
            vDSP_measqv(channels[c], 1, &meanSquare, vDSP_Length(frames))
            var m = meters[c]
            m.peak = peak
            let ms = m.rms * m.rms + alpha * (meanSquare - m.rms * m.rms)
            m.rms = sqrt(max(ms, 0))
            if peak >= m.hold || monitoredFrames - holdTimes[c] > holdFrames {
                m.hold = peak
                holdTimes[c] = monitoredFrames
            }
            if peak >= Self.clipLevel { m.clipped = true }
            meters[c] = m
        }
    }

    private func updateStatus(_ change: (inout Status) -> Void) {
        statusLock.withLock { change(&status) }
    }
}

/// Tap side: picks the selected channels and copies them into the ring without blocking.
private final class Producer: @unchecked Sendable {
    let ring: PCMRingBuffer
    let selected: [Int]
    let dropouts: AtomicInt64
    private var expectedSampleTime: Int64?
    /// Frames accepted into the ring so far, and the host time of one of them, to place recordings in time.
    private let anchorLock = NSLock()
    private var acceptedFrames: Int64 = 0
    private var anchor: (frame: Int64, hostSeconds: Double)?

    init(ring: PCMRingBuffer, selected: [Int], dropouts: AtomicInt64) {
        self.ring = ring
        self.selected = selected
        self.dropouts = dropouts
    }

    func push(_ deviceChannels: [UnsafePointer<Float>], frames: Int, hostSeconds: Double? = nil) {
        let picked = selected.map { deviceChannels[min($0, deviceChannels.count - 1)] }
        guard ring.write(picked, frames: frames) else {
            dropouts.add(1)
            return
        }
        anchorLock.withLock {
            if let hostSeconds { anchor = (acceptedFrames, hostSeconds) }
            acceptedFrames += Int64(frames)
        }
    }

    /// Host time of the `index`th frame accepted into the ring.
    func hostSeconds(ofFrame index: Int64, sampleRate: Double) -> Double? {
        anchorLock.withLock {
            anchor.map { Overdub.hostSeconds(ofFrame: index, anchorFrame: $0.frame, anchorHostSeconds: $0.hostSeconds, sampleRate: sampleRate) }
        }
    }

    func push(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        if when.isSampleTimeValid {
            if let expected = expectedSampleTime, when.sampleTime != expected { dropouts.add(1) }
            expectedSampleTime = when.sampleTime + Int64(frames)
        }
        let count = Int(buffer.format.channelCount)
        let host = when.isHostTimeValid ? Double.hostSeconds(when.hostTime) : nil
        push((0..<count).map { UnsafePointer(data[$0]) }, frames: frames, hostSeconds: host)
    }
}
