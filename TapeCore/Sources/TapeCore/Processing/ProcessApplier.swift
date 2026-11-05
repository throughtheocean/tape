import AVFoundation
import Foundation

/// Renders the new source file for a processed region.
public enum ProcessApplier {
    public static let crossfadeSeconds = 0.002
    static let copyBlock = 1 << 16

    /// Reads `range` of `source` into memory.
    public static func read(_ source: SampleSource, range: SampleRange, sampleRate: Double) -> AudioBuffer {
        let n = Int(range.length)
        let scratch = SampleBuffer(channelCount: source.channelCount, capacity: max(n, 1))
        source.read(start: range.start, count: n, into: scratch, offset: 0)
        return AudioBuffer(channels: scratch.toArrays(count: n), sampleRate: sampleRate)
    }

    /// Writes all of `source` (at `sampleRate`) to a float32 CAF at `url`, with `range` (source frames) run through
    /// `process`. With `crossfade` the processed part blends in and out over 2 ms at the range edges.
    /// Frames outside the range are copied unchanged in blocks, so only the range is held in memory.
    /// Returns the new file's frame count and rate (they differ from the source only for `Resample`).
    public static func render(source: SampleSource, sampleRate: Double, process: AudioProcess, range: SampleRange,
                              crossfade: Bool, to url: URL,
                              isCancelled: @Sendable () -> Bool = { false }) throws -> (frames: Int64, sampleRate: Double) {
        let total = source.frameCount
        if process is Resample {
            let whole = read(source, range: SampleRange(start: 0, end: total), sampleRate: sampleRate)
            let converted = try process.render(input: whole, range: whole.all)
            try write([converted], to: url, sampleRate: converted.sampleRate, channelCount: whole.channelCount)
            return (Int64(converted.frameCount), converted.sampleRate)
        }
        let r = range.clamped(to: SampleRange(start: 0, end: total))
        let original = read(source, range: r, sampleRate: sampleRate)
        var processed = try process.render(input: original, range: original.all)
        if crossfade {
            ProcessCrossfade.apply(original: original, processed: &processed, range: processed.all,
                                   frames: Int((crossfadeSeconds * sampleRate).rounded()))
        }
        let file = try AVAudioFile(forWriting: url, settings: cafSettings(sampleRate: sampleRate, channelCount: source.channelCount),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try copy(source, SampleRange(start: 0, end: r.start), to: file, isCancelled: isCancelled)
        try append(processed, to: file)
        try copy(source, SampleRange(start: r.end, end: total), to: file, isCancelled: isCancelled)
        return (total, sampleRate)
    }

    static func cafSettings(sampleRate: Double, channelCount: Int) -> [String: Any] {
        AudioFileFormat(container: .caf, sampleFormat: .float32, sampleRate: sampleRate, channelCount: channelCount).settings
    }

    /// Writes buffers back to back as float32 CAF.
    public static func write(_ buffers: [AudioBuffer], to url: URL, sampleRate: Double, channelCount: Int) throws {
        let file = try AVAudioFile(forWriting: url, settings: cafSettings(sampleRate: sampleRate, channelCount: channelCount),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        for b in buffers { try append(b, to: file) }
    }

    static func append(_ buffer: AudioBuffer, to file: AVAudioFile) throws {
        let format = file.processingFormat
        var offset = 0
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(copyBlock))!
        while offset < buffer.frameCount {
            let n = min(copyBlock, buffer.frameCount - offset)
            for c in 0..<Int(format.channelCount) {
                buffer.channels[c].withUnsafeBufferPointer { pcm.floatChannelData![c].update(from: $0.baseAddress! + offset, count: n) }
            }
            pcm.frameLength = AVAudioFrameCount(n)
            try file.write(from: pcm)
            offset += n
        }
    }

    static func copy(_ source: SampleSource, _ range: SampleRange, to file: AVAudioFile, isCancelled: @Sendable () -> Bool) throws {
        guard !range.isEmpty else { return }
        let format = file.processingFormat
        let scratch = SampleBuffer(channelCount: source.channelCount, capacity: copyBlock)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(copyBlock))!
        var f = range.start
        while f < range.end {
            if isCancelled() { throw TapeError.cancelled }
            let n = Int(min(Int64(copyBlock), range.end - f))
            source.read(start: f, count: n, into: scratch, offset: 0)
            for c in 0..<Int(format.channelCount) {
                pcm.floatChannelData![c].update(from: scratch.channels[c], count: n)
            }
            pcm.frameLength = AVAudioFrameCount(n)
            try file.write(from: pcm)
            f += Int64(n)
        }
    }
}
