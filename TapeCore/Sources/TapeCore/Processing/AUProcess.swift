import AudioToolbox
import AVFoundation
import Foundation

/// Any Apple effect Audio Unit as a process: a component description plus parameter values.
/// Offline it renders through its own `AVAudioEngine` in manual rendering mode and removes the
/// unit's latency; for previews `makeUnit` gives the same unit to insert into the playback engine.
public struct AUProcess: AudioProcess, @unchecked Sendable {
    public var name: String
    public var component: AudioComponentDescription
    public var parameters: [AUParameterAddress: AUValue]

    public init(name: String, component: AudioComponentDescription, parameters: [AUParameterAddress: AUValue] = [:]) {
        self.name = name
        self.component = component
        self.parameters = parameters
    }

    static func apple(_ subType: OSType) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subType,
                                  componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    }

    public func makeUnit() -> AVAudioUnitEffect {
        let unit = AVAudioUnitEffect(audioComponentDescription: component)
        apply(to: unit)
        return unit
    }

    /// Sets this process's parameter values on a unit made by `makeUnit`, for live preview changes.
    public func apply(to unit: AVAudioUnit) {
        guard let tree = unit.auAudioUnit.parameterTree else { return }
        for (address, value) in parameters {
            tree.parameter(withAddress: address)?.value = value
        }
    }

    public func render(input: AudioBuffer, range: SampleRange) throws -> AudioBuffer {
        let r = range.clamped(to: input.all)
        guard !r.isEmpty else { return input }
        let format = AVAudioFormat.deinterleavedFloat(sampleRate: input.sampleRate, channels: input.channelCount)
        let engine = AVAudioEngine()
        let unit = makeUnit()
        let feeder = BufferFeeder(input: input, range: r)
        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, list in
            feeder.fill(list, frames: Int(frameCount))
            return noErr
        }
        engine.attach(sourceNode)
        engine.attach(unit)
        engine.connect(sourceNode, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        let block: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        try engine.start()
        defer { engine.stop() }

        let latency = Int((unit.auAudioUnit.latency * input.sampleRate).rounded())
        let total = Int(r.length) + latency
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!
        var out = input
        var rendered = 0
        while rendered < total {
            let n = min(Int(block), total - rendered)
            let status = try engine.renderOffline(AVAudioFrameCount(n), to: buffer)
            guard status == .success else { throw TapeError.failed("\(name) render failed (\(status.rawValue))") }
            for i in 0..<Int(buffer.frameLength) {
                let k = rendered + i - latency
                guard k >= 0, k < Int(r.length) else { continue }
                for c in 0..<input.channelCount {
                    out.channels[c][Int(r.start) + k] = buffer.floatChannelData![c][i]
                }
            }
            rendered += n
        }
        return out
    }
}

/// Supplies `range` of a buffer to a source node, then silence (for the unit's latency tail).
private final class BufferFeeder: @unchecked Sendable {
    let input: AudioBuffer
    let range: SampleRange
    var position: Int

    init(input: AudioBuffer, range: SampleRange) {
        self.input = input
        self.range = range
        position = Int(range.start)
    }

    func fill(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for (c, b) in buffers.enumerated() {
            guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frames {
                let f = position + i
                data[i] = f < Int(range.end) && c < input.channelCount ? input.channels[c][f] : 0
            }
        }
        position += frames
    }
}

// MARK: Compressor and limiter

public enum Dynamics {
    /// `AUDynamicsProcessor`. Threshold and headroom in dB, attack and release in seconds, master gain in dB.
    public static func compressor(threshold: Double = -20, headroom: Double = 5, attack: Double = 0.001,
                                  release: Double = 0.05, masterGain: Double = 0) -> AUProcess {
        AUProcess(name: "Compressor", component: AUProcess.apple(kAudioUnitSubType_DynamicsProcessor), parameters: [
            AUParameterAddress(kDynamicsProcessorParam_Threshold): AUValue(threshold),
            AUParameterAddress(kDynamicsProcessorParam_HeadRoom): AUValue(headroom),
            AUParameterAddress(kDynamicsProcessorParam_AttackTime): AUValue(attack),
            AUParameterAddress(kDynamicsProcessorParam_ReleaseTime): AUValue(release),
            AUParameterAddress(kDynamicsProcessorParam_OverallGain): AUValue(masterGain),
        ])
    }

    /// `AUPeakLimiter`. Attack and decay in seconds, pre-gain in dB.
    public static func limiter(attack: Double = 0.012, decay: Double = 0.024, preGain: Double = 0) -> AUProcess {
        AUProcess(name: "Limiter", component: AUProcess.apple(kAudioUnitSubType_PeakLimiter), parameters: [
            AUParameterAddress(kLimiterParam_AttackTime): AUValue(attack),
            AUParameterAddress(kLimiterParam_DecayTime): AUValue(decay),
            AUParameterAddress(kLimiterParam_PreGain): AUValue(preGain),
        ])
    }
}

// MARK: Resample

/// Converts the whole buffer to `sampleRate` with `AVAudioConverter` at highest quality.
/// The only process that changes length and rate; the range is ignored.
public struct Resample: AudioProcess {
    public var sampleRate: Double
    public var name: String { "Resample" }

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public func render(input: AudioBuffer, range: SampleRange) throws -> AudioBuffer {
        guard sampleRate != input.sampleRate, input.frameCount > 0 else { return input }
        let inFormat = AVAudioFormat.deinterleavedFloat(sampleRate: input.sampleRate, channels: input.channelCount)
        let outFormat = AVAudioFormat.deinterleavedFloat(sampleRate: sampleRate, channels: input.channelCount)
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TapeError.failed("No converter to \(sampleRate) Hz")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.frameCount))!
        inBuffer.frameLength = inBuffer.frameCapacity
        for c in 0..<input.channelCount {
            input.channels[c].withUnsafeBufferPointer { inBuffer.floatChannelData![c].update(from: $0.baseAddress!, count: input.frameCount) }
        }
        let expected = Int((Double(input.frameCount) * sampleRate / input.sampleRate).rounded())
        var out = AudioBuffer(frames: 0, channelCount: input.channelCount, sampleRate: sampleRate)
        let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 65536)!
        let feed = OneShotInput(buffer: inBuffer)
        while true {
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in feed.next(inputStatus) }
            if let error { throw error }
            for c in 0..<input.channelCount {
                out.channels[c].append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![c], count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error || outBuffer.frameLength == 0 { break }
        }
        for c in out.channels.indices {
            if out.channels[c].count > expected { out.channels[c].removeLast(out.channels[c].count - expected) }
            if out.channels[c].count < expected { out.channels[c] += [Float](repeating: 0, count: expected - out.channels[c].count) }
        }
        return out
    }
}

private final class OneShotInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var sent = false

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if sent {
            status.pointee = .endOfStream
            return nil
        }
        sent = true
        status.pointee = .haveData
        return buffer
    }
}
