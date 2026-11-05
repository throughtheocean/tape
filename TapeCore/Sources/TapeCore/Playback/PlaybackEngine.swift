import Accelerate
import AVFoundation
import Foundation

/// Plays the edit list through `AVAudioEngine`.
///
/// A producer thread renders through `EditListRenderer` into a `ChunkRing` a few tens of
/// milliseconds ahead; the `AVAudioSourceNode` render block only copies from the ring, so the
/// realtime thread never reads files or takes locks. Shuttle speeds and reverse are rendered
/// by the producer in blocks.
public final class PlaybackEngine: @unchecked Sendable {
    public static let chunkFrames = 512
    static let slotCount = 16
    static let targetFill = 6

    public private(set) var sessionRate: Double = 48000
    public private(set) var channelCount: Int = 2
    public private(set) var isPlaying = false
    public private(set) var speed = 1

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var ring: ChunkRing?
    private var producer: Thread?

    private struct Command {
        var generation: Int64 = 0
        var start: Int64 = 0
        var speed: Int64 = 1
        var playing = false
    }

    private let lock = NSLock()
    private var command = Command()
    private var editList = EditList.empty
    private var loopRange: SampleRange?
    private let wake = DispatchSemaphore(value: 0)
    private var stopProducer = AtomicInt64(0)

    // Shared with the render block.
    private let generation = AtomicInt64(0)
    /// Timeline position of the first frame of the last rendered buffer.
    private let bufferPosition = AtomicInt64(0)
    private let bufferHostTime = AtomicInt64(0)
    private let bufferFrames = AtomicInt64(0)
    private let bufferSpeed = AtomicInt64(1)
    private let firstAudioHostTime = AtomicInt64(0)
    private var playRequestHostTime: UInt64 = 0
    private var pausedPosition: Int64 = 0
    private var configObserver: NSObjectProtocol?

    /// Milliseconds from the last `play` call until its first frame reached the output, plus output latency.
    public private(set) var lastStartLatencyMs: Double?

    public init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        shutdown()
    }

    // MARK: Setup

    /// Offline manual rendering instead of the output device; used by tests.
    public private(set) var isManual = false

    public func configure(sessionRate: Double, channelCount: Int, manualRendering: Bool = false) throws {
        if sourceNode != nil, sessionRate == self.sessionRate, channelCount == self.channelCount, manualRendering == isManual { return }
        shutdown()
        self.sessionRate = sessionRate
        self.channelCount = max(1, channelCount)
        let ring = ChunkRing(slotCount: Self.slotCount, chunkFrames: Self.chunkFrames, channelCount: self.channelCount)
        self.ring = ring
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate,
                                         channels: AVAudioChannelCount(self.channelCount), interleaved: false) else {
            throw TapeError.unreadable(URL(fileURLWithPath: "/"), "Unsupported session format")
        }
        let node = makeSourceNode(format: format, ring: ring)
        sourceNode = node
        isManual = manualRendering
        if manualRendering {
            if engine.isInManualRenderingMode { engine.disableManualRenderingMode() }
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        stopProducer = AtomicInt64(0)
        let stopFlag = stopProducer
        let thread = Thread { [weak self] in
            self?.producerLoop(ring: ring, stop: stopFlag)
        }
        thread.qualityOfService = .userInteractive
        thread.name = "tape.playback.producer"
        producer = thread
        thread.start()
    }

    /// Pulls `frames` of transport output in manual rendering mode. Waits for the producer
    /// before each block so the result does not depend on thread timing.
    public func renderManual(frames: Int) throws -> [[Float]] {
        precondition(isManual, "configure with manualRendering first")
        let format = engine.manualRenderingFormat
        let block = 512
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
        var out = [[Float]](repeating: [], count: channelCount)
        var done = 0
        while done < frames {
            let n = min(block, frames - done)
            waitForProducer(frames: n)
            let status = try engine.renderOffline(AVAudioFrameCount(n), to: buffer)
            guard status == .success else { throw TapeError.unreadable(URL(fileURLWithPath: "/"), "Manual render status \(status.rawValue)") }
            for c in 0..<channelCount {
                out[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength)))
            }
            done += n
        }
        return out
    }

    private func waitForProducer(frames: Int) {
        guard let ring, isPlaying else { return }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let r = ring.readIndex.load(), w = ring.writeIndex.load()
            var available = 0
            var i = r
            while i < w {
                let h = ring.headers[Int(i % Int64(ring.slotCount))]
                if h.generation == generation.load() { available += Int(h.frames) }
                i += 1
            }
            if available >= frames + ring.chunkFrames || ring.slotCount - Int(w - r) <= 1 { return }
            if lock.withLock({ producerEnded }) { return }
            usleep(200)
        }
    }

    /// Set by the producer when the current generation reached the end without a loop.
    private var producerEnded = false

    /// Output gain after the edit list, 0 to 1.
    public var outputVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    public func shutdown() {
        stopProducer.store(1)
        wake.signal()
        producer = nil
        if engine.isRunning { engine.stop() }
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        isPlaying = false
    }

    private func restartAfterConfigurationChange() {
        guard sourceNode != nil, !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    // MARK: Transport

    public func setEditList(_ list: EditList) {
        lock.withLock { editList = list }
        wake.signal()
    }

    /// Range playback loops over, or nil for no loop.
    public func setLoop(_ range: SampleRange?) {
        lock.withLock { loopRange = range }
    }

    public func play(from position: Int64, speed: Int = 1) {
        let s = speed == 0 ? 1 : speed
        playRequestHostTime = mach_absolute_time()
        firstAudioHostTime.store(0)
        lastStartLatencyMs = nil
        lock.withLock {
            command.generation += 1
            command.start = position
            command.speed = Int64(s)
            command.playing = true
            producerEnded = false
            publishGeneration(command.generation)
        }
        bufferPosition.store(position)
        bufferFrames.store(0)
        bufferSpeed.store(Int64(s))
        isPlaying = true
        self.speed = s
        wake.signal()
    }

    public func pause() {
        let p = position
        lock.withLock {
            command.generation += 1
            command.playing = false
            publishGeneration(command.generation)
        }
        pausedPosition = p
        isPlaying = false
    }

    /// Moves the stopped transport.
    public func locate(_ position: Int64) {
        if isPlaying {
            play(from: position, speed: speed)
        } else {
            pausedPosition = position
        }
    }

    private func publishGeneration(_ g: Int64) { generation.store(g) }

    /// Audible position, extrapolated from the last render callback at display rate.
    public var position: Int64 {
        guard isPlaying else { return pausedPosition }
        let host = bufferHostTime.load()
        let start = bufferPosition.load()
        let frames = bufferFrames.load()
        let spd = bufferSpeed.load()
        guard host != 0 else { return start }
        let now = mach_absolute_time()
        let elapsed = now > UInt64(host) ? Self.seconds(now - UInt64(host)) : 0
        let advanced = min(Int64(elapsed * sessionRate), frames)
        return start + advanced * spd
    }

    /// Milliseconds from the last `play` call until its first frame was handed to the output unit.
    public private(set) var lastEngineLatencyMs: Double?

    /// Latency the output device and driver add after the engine, in milliseconds.
    public var outputLatencyMs: Double { engine.outputNode.presentationLatency * 1000 }

    public func updateStartLatency() {
        guard lastStartLatencyMs == nil else { return }
        let first = firstAudioHostTime.load()
        guard first != 0, UInt64(first) > playRequestHostTime else { return }
        let engineMs = Self.seconds(UInt64(first) - playRequestHostTime) * 1000
        lastEngineLatencyMs = engineMs
        lastStartLatencyMs = engineMs + outputLatencyMs
    }

    static func seconds(_ hostTicks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(hostTicks) * Double(info.numer) / Double(info.denom) / 1e9
    }

    // MARK: Render thread

    private func makeSourceNode(format: AVAudioFormat, ring: ChunkRing) -> AVAudioSourceNode {
        let generation = self.generation
        let bufferPosition = self.bufferPosition
        let bufferHostTime = self.bufferHostTime
        let bufferFrames = self.bufferFrames
        let bufferSpeed = self.bufferSpeed
        let firstAudio = self.firstAudioHostTime
        let consumerOffset = AtomicInt64(0)
        let channels = ring.channelCount

        return AVAudioSourceNode(format: format) { _, timestamp, frameCount, ablPointer -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
            let total = Int(frameCount)
            let gen = generation.load()
            var out = 0
            var offset = consumerOffset.load()
            var firstPosition: Int64 = .min
            var lastSpeed: Int64 = 1
            while out < total {
                let r = ring.readIndex.load()
                if r == ring.writeIndex.load() { break }
                let slot = Int(r % Int64(ring.slotCount))
                let header = ring.headers[slot]
                if header.generation != gen {
                    ring.readIndex.store(r + 1)
                    offset = 0
                    continue
                }
                if firstPosition == .min { firstPosition = header.startPosition + offset * header.speed }
                lastSpeed = header.speed
                let n = min(Int(header.frames - offset), total - out)
                for c in 0..<min(channels, abl.count) {
                    guard let dst = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    (dst + out).update(from: ring.channel(slot: slot, channel: c) + Int(offset), count: n)
                }
                out += n
                offset += Int64(n)
                if offset >= header.frames {
                    ring.readIndex.store(r + 1)
                    offset = 0
                }
            }
            consumerOffset.store(offset)
            if out < total {
                for c in 0..<abl.count {
                    guard let dst = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    (dst + out).update(repeating: 0, count: total - out)
                }
            }
            if out > 0 {
                bufferPosition.store(firstPosition)
                bufferFrames.store(Int64(out))
                bufferSpeed.store(lastSpeed)
                let host = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : mach_absolute_time()
                bufferHostTime.store(Int64(host))
                if firstAudio.load() == 0 { firstAudio.store(Int64(mach_absolute_time())) }
            }
            return noErr
        }
    }

    // MARK: Producer thread

    private func producerLoop(ring: ChunkRing, stop: AtomicInt64) {
        let renderer = EditListRenderer(maxFrames: 8192)
        let maxSpeed = 8
        let work = SampleBuffer(channelCount: ring.channelCount, capacity: ring.chunkFrames * maxSpeed)
        var myGeneration: Int64 = -1
        var genStartIndex: Int64 = 0
        var pos: Int64 = 0
        var speed: Int64 = 1
        var ended = false

        while stop.load() == 0 {
            lock.lock()
            let cmd = command
            let list = editList
            let loop = loopRange
            if cmd.generation != myGeneration { producerEnded = false }
            lock.unlock()

            if cmd.generation != myGeneration {
                myGeneration = cmd.generation
                genStartIndex = ring.writeIndex.load()
                pos = cmd.start
                speed = cmd.speed
                ended = false
            }
            if !cmd.playing || ended {
                _ = wake.wait(timeout: .now() + .milliseconds(20))
                continue
            }
            let w = ring.writeIndex.load()
            let r = ring.readIndex.load()
            let ownFill = w - max(r, genStartIndex)
            if ownFill >= Int64(Self.targetFill) || w - r >= Int64(ring.slotCount) {
                _ = wake.wait(timeout: .now() + .milliseconds(2))
                continue
            }

            let step = abs(speed)
            let length = list.length
            var outFrames = Int64(ring.chunkFrames)
            var spanStart: Int64
            var span: Int64
            if speed > 0 {
                let loopLimited = loop.map { pos < $0.end } ?? false
                let limit = loopLimited ? loop!.end : length
                span = min(outFrames * step, limit - pos)
                if span < step {
                    if loopLimited, let loop, loop.length >= step {
                        pos = loop.start
                    } else {
                        ended = true
                        lock.withLock { producerEnded = true }
                    }
                    continue
                }
                spanStart = pos
            } else {
                let loopLimited = loop.map { pos > $0.start } ?? false
                let limit = loopLimited ? loop!.start : 0
                span = min(outFrames * step, pos - limit)
                if span < step {
                    if loopLimited, let loop, loop.length >= step {
                        pos = loop.end
                    } else {
                        ended = true
                        lock.withLock { producerEnded = true }
                    }
                    continue
                }
                spanStart = pos - (span / step) * step
            }
            outFrames = span / step
            span = outFrames * step

            renderer.render(list, start: spanStart, frames: Int(span), into: work)
            let slot = Int(w % Int64(ring.slotCount))
            let n = Int(outFrames)
            let filter = [Float](repeating: 1 / Float(step), count: Int(step))
            for c in 0..<ring.channelCount {
                let dst = ring.channel(slot: slot, channel: c)
                let src = work.channels[c]
                if step == 1 {
                    dst.update(from: src, count: n)
                } else {
                    // Box filter decimation.
                    vDSP_desamp(src, vDSP_Stride(step), filter, dst, vDSP_Length(n), vDSP_Length(step))
                }
                if speed < 0 { vDSP_vrvrs(dst, 1, vDSP_Length(n)) }
            }
            ring.headers[slot] = ChunkRing.Header(generation: myGeneration, startPosition: pos, speed: speed, frames: outFrames)
            ring.writeIndex.store(w + 1)
            pos += speed > 0 ? span : -span
            if let loop {
                if speed > 0, pos >= loop.end, spanStart < loop.end { pos = loop.start }
                if speed < 0, pos <= loop.start, spanStart + span > loop.start { pos = loop.end }
            }
        }
    }
}
