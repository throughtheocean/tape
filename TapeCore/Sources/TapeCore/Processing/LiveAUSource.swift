import AVFoundation
import AudioToolbox

/// A source played through an Audio Unit as it is read, for previewing an AU process in context: the preview list
/// swaps a target region's source for one of these, so region gain, fades, track gain and pan and the master apply
/// after the process, as they do after Apply.
///
/// Matches `AUProcess.render`: only `processed` (source frames) goes through the unit, the unit sees silence
/// outside it, it renders in the same slices, and its latency is compensated by reading ahead. Reads are expected
/// to be sequential, as playback makes them; a jump resets the unit and primes it with the slice before.
public final class LiveAUSource: SampleSource, @unchecked Sendable {
    public let base: SampleSource
    public let processed: SampleRange
    /// Frames blended from the original into the processed audio at each edge of `processed`, as
    /// `ProcessCrossfade` does after a partial Apply.
    public let crossfade: Int
    public var channelCount: Int { base.channelCount }
    public var frameCount: Int64 { base.frameCount }

    private let unit: AudioUnit
    private var latency: Int
    /// Apply renders in slices of this size from the range start; the unit's result depends on the slicing.
    private let slice = 4096
    fileprivate let input: SampleBuffer
    private let output: SampleBuffer
    private let outputList: UnsafeMutableAudioBufferListPointer
    private var currentSlice = Int.min
    private let lock = NSLock()

    public init(base: SampleSource, processed: SampleRange, process: AUProcess, sampleRate: Double, crossfade: Int = 0) throws {
        self.base = base
        self.processed = processed
        self.crossfade = min(crossfade, Int(processed.length) / 2)
        var description = process.component
        guard let component = AudioComponentFindNext(nil, &description) else { throw TapeError.failed("\(process.name) is not available") }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), process.name)
        unit = instance!
        let channels = max(1, base.channelCount)
        input = SampleBuffer(channelCount: channels, capacity: slice)
        output = SampleBuffer(channelCount: channels, capacity: slice)
        outputList = AudioBufferList.allocate(maximumBuffers: channels)

        let avFormat = AVAudioFormat.deinterleavedFloat(sampleRate: sampleRate, channels: channels)
        var format = avFormat.streamDescription.pointee
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format, formatSize), process.name)
        }
        var frames = UInt32(slice)
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                            &frames, UInt32(MemoryLayout<UInt32>.size)), process.name)
        var callback = AURenderCallbackStruct(inputProc: liveAUInput, inputProcRefCon: Unmanaged.passUnretained(input).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), process.name)
        try Self.check(AudioUnitInitialize(unit), process.name)
        latency = 0
        setParameters(process)
        var seconds: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size)
        latency = Int((seconds * sampleRate).rounded())
    }

    /// Live parameter changes while previewing.
    public func setParameters(_ process: AUProcess) {
        lock.lock()
        defer { lock.unlock() }
        for (address, value) in process.parameters {
            AudioUnitSetParameter(unit, AudioUnitParameterID(address), kAudioUnitScope_Global, 0, value, 0)
        }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        free(outputList.unsafeMutablePointer)
    }

    private static func check(_ status: OSStatus, _ name: String) throws {
        guard status == noErr else { throw TapeError.failed("\(name) preview failed (\(status))") }
    }

    /// Called by the playback producer thread, not the audio callback, so the lock and the slice renders are fine.
    public func read(start: Int64, count: Int, into buffer: SampleBuffer, offset: Int) {
        lock.lock()
        defer { lock.unlock() }
        base.read(start: start, count: count, into: buffer, offset: offset)
        var at = max(start, processed.start)
        let to = min(start + Int64(count), processed.end)
        while at < to {
            // The unit's output stream runs `latency` frames behind its input, which starts at `processed.start`.
            let stream = Int(at - processed.start) + latency
            let k = stream / slice
            if k != currentSlice {
                if k != currentSlice + 1 {
                    AudioUnitReset(unit, kAudioUnitScope_Global, 0)
                    if k > 0 { renderSlice(k - 1) }
                }
                renderSlice(k)
            }
            let i = stream - k * slice
            let n = min(slice - i, Int(to - at))
            for c in 0..<min(channelCount, buffer.channelCount) {
                let dst = buffer.channels[c] + offset + Int(at - start), src = output.channels[c] + i
                guard crossfade > 0 else {
                    dst.update(from: src, count: n)
                    continue
                }
                for j in 0..<n {
                    let f = at + Int64(j)
                    let k = Int(min(f - processed.start, processed.end - 1 - f))
                    let t: Float = k < crossfade ? Float(k + 1) / Float(crossfade + 1) : 1
                    dst[j] = dst[j] * (1 - t) + src[j] * t
                }
            }
            at += Int64(n)
        }
    }

    /// Renders slice `k` of the unit's stream into `output`: input frames `processed.start + k * slice` onwards,
    /// silence outside `processed`.
    private func renderSlice(_ k: Int) {
        let from = processed.start + Int64(k * slice)
        base.read(start: from, count: slice, into: input, offset: 0)
        for c in 0..<input.channelCount {
            let p = input.channels[c]
            for i in 0..<slice where !processed.contains(from + Int64(i)) { p[i] = 0 }
        }
        let bytes = UInt32(slice * MemoryLayout<Float>.size)
        for c in 0..<output.channelCount {
            outputList[c] = AudioToolbox.AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: output.channels[c])
        }
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        time.mSampleTime = Double(k * slice)
        time.mFlags = .sampleTimeValid
        if AudioUnitRender(unit, &flags, &time, 0, UInt32(slice), outputList.unsafeMutablePointer) != noErr {
            for c in 0..<output.channelCount { output.channels[c].update(from: input.channels[c], count: slice) }
        }
        currentSlice = k
    }
}

/// The unit's input: the frames `pull` just read into the source's input buffer.
private func liveAUInput(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                         _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let data else { return noErr }
    let input = Unmanaged<SampleBuffer>.fromOpaque(refCon).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    let size = Int(frames) * MemoryLayout<Float>.size
    for (c, b) in buffers.enumerated() where c < input.channelCount {
        if let dst = b.mData {
            dst.copyMemory(from: input.channels[c], byteCount: size)
        } else {
            buffers[c].mData = UnsafeMutableRawPointer(input.channels[c])
        }
        buffers[c].mDataByteSize = UInt32(size)
    }
    return noErr
}
