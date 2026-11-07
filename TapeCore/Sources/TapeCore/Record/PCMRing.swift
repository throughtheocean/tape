import CoreAudio
import Foundation

/// Lock-free single producer, single consumer ring of deinterleaved float frames.
/// The producer never blocks: a write that does not fit is refused and counted by the caller.
public final class PCMRingBuffer: @unchecked Sendable {
    public let channelCount: Int
    public let capacity: Int
    private let storage: [UnsafeMutablePointer<Float>]
    /// Monotonic frame counters; position in storage is counter % capacity.
    private let written = AtomicInt64(0)
    private let read = AtomicInt64(0)

    public init(channelCount: Int, capacity: Int) {
        self.channelCount = channelCount
        self.capacity = max(1, capacity)
        storage = (0..<channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, capacity))
            p.initialize(repeating: 0, count: max(1, capacity))
            return p
        }
    }

    deinit { storage.forEach { $0.deallocate() } }

    public var available: Int { Int(written.load() - read.load()) }
    public var space: Int { capacity - available }

    /// Producer side. Copies `frames` frames from `channels` (one pointer per ring channel).
    /// Returns false, writing nothing, when the ring has no room.
    @discardableResult
    public func write(_ channels: [UnsafePointer<Float>], frames: Int) -> Bool {
        guard frames > 0 else { return true }
        let w = written.load()
        guard frames <= capacity - Int(w - read.load()) else { return false }
        let start = Int(w % Int64(capacity))
        let first = min(frames, capacity - start)
        for c in 0..<channelCount {
            (storage[c] + start).update(from: channels[c], count: first)
            if frames > first { storage[c].update(from: channels[c] + first, count: frames - first) }
        }
        written.store(w + Int64(frames))
        return true
    }

    /// Producer side, without allocating (for the audio thread): ring channel `i` takes buffer `channels[i]` of
    /// `list`. Refused when the ring has no room or a buffer is missing.
    @discardableResult
    public func write(_ list: UnsafeMutableAudioBufferListPointer, channels: [Int], frames: Int) -> Bool {
        guard frames > 0 else { return true }
        let w = written.load()
        guard frames <= capacity - Int(w - read.load()), channels.allSatisfy({ $0 < list.count && list[$0].mData != nil }) else { return false }
        let start = Int(w % Int64(capacity))
        let first = min(frames, capacity - start)
        for (i, c) in channels.enumerated() where i < channelCount {
            let src = list[c].mData!.assumingMemoryBound(to: Float.self)
            (storage[i] + start).update(from: src, count: first)
            if frames > first { storage[i].update(from: src + first, count: frames - first) }
        }
        written.store(w + Int64(frames))
        return true
    }

    /// Consumer side. Copies up to `maxFrames` frames into `out` at `offset`, returns the count.
    public func read(into out: [UnsafeMutablePointer<Float>], offset: Int = 0, maxFrames: Int) -> Int {
        let r = read.load()
        let frames = min(maxFrames, Int(written.load() - r))
        guard frames > 0 else { return 0 }
        let start = Int(r % Int64(capacity))
        let first = min(frames, capacity - start)
        for c in 0..<channelCount {
            (out[c] + offset).update(from: storage[c] + start, count: first)
            if frames > first { (out[c] + offset + first).update(from: storage[c], count: frames - first) }
        }
        read.store(r + Int64(frames))
        return frames
    }
}

/// Keeps the most recent `capacity` frames, overwriting the oldest. Single threaded.
public final class PreRollBuffer {
    public let channelCount: Int
    public let capacity: Int
    private let storage: [UnsafeMutablePointer<Float>]
    private var total: Int64 = 0

    public init(channelCount: Int, capacity: Int) {
        self.channelCount = channelCount
        self.capacity = max(0, capacity)
        storage = (0..<channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, capacity))
            p.initialize(repeating: 0, count: max(1, capacity))
            return p
        }
    }

    deinit { storage.forEach { $0.deallocate() } }

    /// Frames currently held, at most `capacity`.
    public var count: Int { Int(min(total, Int64(capacity))) }

    public func clear() { total = 0 }

    public func write(_ channels: [UnsafePointer<Float>], frames: Int) {
        guard capacity > 0, frames > 0 else { return }
        // Only the last `capacity` frames of this write can survive.
        let skip = max(0, frames - capacity)
        let n = frames - skip
        let start = Int((total + Int64(skip)) % Int64(capacity))
        let first = min(n, capacity - start)
        for c in 0..<channelCount {
            (storage[c] + start).update(from: channels[c] + skip, count: first)
            if n > first { storage[c].update(from: channels[c] + skip + first, count: n - first) }
        }
        total += Int64(frames)
    }

    /// Calls `body` with the held frames, oldest first, in at most two contiguous pieces.
    public func forEachPiece(_ body: ([UnsafePointer<Float>], Int) throws -> Void) rethrows {
        let n = count
        guard n > 0 else { return }
        let start = Int((total - Int64(n)) % Int64(capacity))
        let first = min(n, capacity - start)
        try body(storage.map { UnsafePointer($0 + start) }, first)
        if n > first { try body(storage.map { UnsafePointer($0) }, n - first) }
    }

    public func toArrays() -> [[Float]] {
        var out = [[Float]](repeating: [], count: channelCount)
        forEachPiece { pointers, frames in
            for c in 0..<channelCount { out[c] += UnsafeBufferPointer(start: pointers[c], count: frames) }
        }
        return out
    }
}
