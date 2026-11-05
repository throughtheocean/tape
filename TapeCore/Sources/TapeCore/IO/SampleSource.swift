import Foundation

/// Deinterleaved float storage owned by the caller, reused across reads.
public final class SampleBuffer: @unchecked Sendable {
    public let channelCount: Int
    public let capacity: Int
    public let channels: [UnsafeMutablePointer<Float>]

    public init(channelCount: Int, capacity: Int) {
        self.channelCount = channelCount
        self.capacity = capacity
        channels = (0..<channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            p.initialize(repeating: 0, count: capacity)
            return p
        }
    }

    deinit { channels.forEach { $0.deallocate() } }

    public func zero(offset: Int = 0, count: Int) {
        for c in channels { (c + offset).update(repeating: 0, count: count) }
    }

    public func toArrays(count: Int) -> [[Float]] {
        channels.map { Array(UnsafeBufferPointer(start: $0, count: count)) }
    }
}

/// Random access audio at session rate. Implementations must be safe to call from any thread.
public protocol SampleSource: AnyObject, Sendable {
    var channelCount: Int { get }
    /// Length in session frames.
    var frameCount: Int64 { get }
    /// Reads frames `start ..< start + count` into `buffer` at `offset`, all source channels.
    /// Frames outside the source are zero.
    func read(start: Int64, count: Int, into buffer: SampleBuffer, offset: Int)
}

/// In-memory source, used by tests and for small generated material.
public final class MemorySource: SampleSource, @unchecked Sendable {
    public let samples: [[Float]]
    public var channelCount: Int { samples.count }
    public var frameCount: Int64 { Int64(samples.first?.count ?? 0) }

    public init(samples: [[Float]]) { self.samples = samples }

    public func read(start: Int64, count: Int, into buffer: SampleBuffer, offset: Int) {
        let n = Int64(samples.first?.count ?? 0)
        for c in 0..<min(channelCount, buffer.channelCount) {
            let dst = buffer.channels[c] + offset
            samples[c].withUnsafeBufferPointer { src in
                for i in 0..<count {
                    let f = start + Int64(i)
                    dst[i] = (f >= 0 && f < n) ? src[Int(f)] : 0
                }
            }
        }
    }
}
