import Accelerate
import Foundation

/// Planar float audio held in memory for processing.
public struct AudioBuffer: Equatable, Sendable {
    public var channels: [[Float]]
    public var sampleRate: Double

    public init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
    }

    public init(frames: Int, channelCount: Int, sampleRate: Double) {
        channels = Array(repeating: [Float](repeating: 0, count: frames), count: channelCount)
        self.sampleRate = sampleRate
    }

    public var frameCount: Int { channels.first?.count ?? 0 }
    public var channelCount: Int { channels.count }
    public var all: SampleRange { SampleRange(start: 0, end: Int64(frameCount)) }

    /// Largest absolute sample in `range` over all channels.
    public func peak(in range: SampleRange? = nil) -> Float {
        let r = (range ?? all).clamped(to: all)
        var peak: Float = 0
        for c in channels where !r.isEmpty {
            c.withUnsafeBufferPointer { p in
                var m: Float = 0
                vDSP_maxmgv(p.baseAddress! + Int(r.start), 1, &m, vDSP_Length(r.length))
                peak = max(peak, m)
            }
        }
        return peak
    }
}

/// One process. Parameters are the conforming struct's properties.
public protocol AudioProcess: Sendable {
    var name: String { get }
    /// Returns `input` with the frames in `range` processed and every other frame unchanged.
    /// Same length and rate as `input`, except for `Resample`.
    func render(input: AudioBuffer, range: SampleRange) throws -> AudioBuffer
}

// MARK: Gain

public struct Gain: AudioProcess {
    public var dB: Double
    public var name: String { "Gain" }

    public init(dB: Double) { self.dB = dB }

    public func render(input: AudioBuffer, range: SampleRange) throws -> AudioBuffer {
        var out = input
        let r = range.clamped(to: input.all)
        guard !r.isEmpty else { return out }
        var g = Float(pow(10, dB / 20))
        for c in out.channels.indices {
            out.channels[c].withUnsafeMutableBufferPointer { p in
                let base = p.baseAddress! + Int(r.start)
                vDSP_vsmul(base, 1, &g, base, 1, vDSP_Length(r.length))
            }
        }
        return out
    }
}

// MARK: Normalize

public struct Normalize: AudioProcess {
    public enum Mode: Equatable, Sendable {
        /// Sample peak to `targetDB` dBFS.
        case peak(targetDB: Double)
        /// Integrated loudness (BS.1770-4) to `targetLUFS`, never raising the true peak above `ceilingDBTP`.
        case loudness(targetLUFS: Double, ceilingDBTP: Double)
    }

    public var mode: Mode
    public var name: String { "Normalize" }

    public init(mode: Mode) { self.mode = mode }

    /// Gain in dB that the process applies to `range`; 0 for silence.
    public func gainDB(for input: AudioBuffer, range: SampleRange) -> Double {
        switch mode {
        case let .peak(target):
            let peak = input.peak(in: range)
            return peak > 0 ? target - 20 * log10(Double(peak)) : 0
        case let .loudness(target, ceiling):
            let lufs = Loudness.integrated(input, range: range)
            guard lufs.isFinite else { return 0 }
            var gain = target - lufs
            let tp = Loudness.truePeakDB(input, range: range)
            if tp.isFinite, tp + gain > ceiling { gain = ceiling - tp }
            return gain
        }
    }

    public func render(input: AudioBuffer, range: SampleRange) throws -> AudioBuffer {
        try Gain(dB: gainDB(for: input, range: range)).render(input: input, range: range)
    }
}

// MARK: DC offset

public struct RemoveDC: AudioProcess {
    public var name: String { "Remove DC Offset" }

    public init() {}

    /// Subtracts each channel's mean over `range`.
    public func render(input: AudioBuffer, range: SampleRange) throws -> AudioBuffer {
        var out = input
        let r = range.clamped(to: input.all)
        guard !r.isEmpty else { return out }
        for c in out.channels.indices {
            out.channels[c].withUnsafeMutableBufferPointer { p in
                let base = p.baseAddress! + Int(r.start)
                var mean: Float = 0
                vDSP_meanv(base, 1, &mean, vDSP_Length(r.length))
                var negative = -mean
                vDSP_vsadd(base, 1, &negative, base, 1, vDSP_Length(r.length))
            }
        }
        return out
    }
}

// MARK: Reverse

public struct Reverse: AudioProcess {
    public var name: String { "Reverse" }

    public init() {}

    public func render(input: AudioBuffer, range: SampleRange) throws -> AudioBuffer {
        var out = input
        let r = range.clamped(to: input.all)
        guard !r.isEmpty else { return out }
        for c in out.channels.indices {
            out.channels[c].withUnsafeMutableBufferPointer { p in
                vDSP_vrvrs(p.baseAddress! + Int(r.start), 1, vDSP_Length(r.length))
            }
        }
        return out
    }
}

// MARK: Trim silence

/// Finds where the audio rises above `thresholdDB` and keeps `holdMs` before the first and after the
/// last such frame. Applied at region ends as a trim; `render` silences what the trim would remove.
public struct TrimSilence: AudioProcess {
    public var thresholdDB: Double
    public var holdMs: Double
    public var name: String { "Trim Silence" }

    public init(thresholdDB: Double = -60, holdMs: Double = 10) {
        self.thresholdDB = thresholdDB
        self.holdMs = holdMs
    }

    /// The part of `range` to keep; empty when everything is below the threshold.
    public func bounds(_ input: AudioBuffer, range: SampleRange) -> SampleRange {
        let r = range.clamped(to: input.all)
        let threshold = Float(pow(10, thresholdDB / 20))
        var first = Int64.max, last = Int64.min
        for c in input.channels {
            c.withUnsafeBufferPointer { p in
                var i = r.start
                while i < r.end, i < first {
                    if abs(p[Int(i)]) >= threshold { first = i; break }
                    i += 1
                }
                var j = r.end - 1
                while j >= r.start, j > last {
                    if abs(p[Int(j)]) >= threshold { last = j; break }
                    j -= 1
                }
            }
        }
        guard first <= last else { return SampleRange(start: r.start, end: r.start) }
        let hold = Int64((holdMs / 1000 * input.sampleRate).rounded())
        return SampleRange(start: max(r.start, first - hold), end: min(r.end, last + 1 + hold))
    }

    public func render(input: AudioBuffer, range: SampleRange) throws -> AudioBuffer {
        let keep = bounds(input, range: range)
        let r = range.clamped(to: input.all)
        var out = input
        for c in out.channels.indices {
            for i in Int(r.start)..<Int(r.end) where !keep.contains(Int64(i)) { out.channels[c][i] = 0 }
        }
        return out
    }
}

// MARK: Crossfade

public enum ProcessCrossfade {
    /// Blends from `original` into `processed` over `frames` after `range.start` and back before `range.end`,
    /// so a partial process has no click at its edges. Linear, equal gain: the two signals are correlated.
    public static func apply(original: AudioBuffer, processed: inout AudioBuffer, range: SampleRange, frames: Int) {
        let r = range.clamped(to: processed.all)
        let n = min(frames, Int(r.length) / 2)
        guard n > 0 else { return }
        for c in processed.channels.indices {
            for k in 0..<n {
                let t = Float(k + 1) / Float(n + 1)
                let a = Int(r.start) + k
                processed.channels[c][a] = original.channels[c][a] * (1 - t) + processed.channels[c][a] * t
                let b = Int(r.end) - 1 - k
                processed.channels[c][b] = original.channels[c][b] * (1 - t) + processed.channels[c][b] * t
            }
        }
    }
}
