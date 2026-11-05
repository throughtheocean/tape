import Foundation

/// Single producer, single consumer ring of fixed size audio chunks. Each chunk carries
/// the generation it was rendered for and the timeline position it starts at, so the
/// consumer can drop stale audio after a seek without any lock.
final class ChunkRing: @unchecked Sendable {
    struct Header {
        var generation: Int64 = -1
        /// Timeline frame of the first output frame.
        var startPosition: Int64 = 0
        /// Signed timeline frames advanced per output frame.
        var speed: Int64 = 1
        var frames: Int64 = 0
    }

    let slotCount: Int
    let chunkFrames: Int
    let channelCount: Int
    let headers: UnsafeMutablePointer<Header>
    let data: UnsafeMutablePointer<Float>
    /// Monotonic counters; slot = index % slotCount.
    let writeIndex = AtomicInt64(0)
    let readIndex = AtomicInt64(0)

    init(slotCount: Int, chunkFrames: Int, channelCount: Int) {
        self.slotCount = slotCount
        self.chunkFrames = chunkFrames
        self.channelCount = channelCount
        headers = .allocate(capacity: slotCount)
        headers.initialize(repeating: Header(), count: slotCount)
        data = .allocate(capacity: slotCount * channelCount * chunkFrames)
        data.initialize(repeating: 0, count: slotCount * channelCount * chunkFrames)
    }

    deinit {
        headers.deallocate()
        data.deallocate()
    }

    var filled: Int { Int(writeIndex.load() - readIndex.load()) }

    @inline(__always)
    func channel(slot: Int, channel: Int) -> UnsafeMutablePointer<Float> {
        data + (slot * channelCount + channel) * chunkFrames
    }
}
