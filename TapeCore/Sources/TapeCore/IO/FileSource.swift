import AVFoundation
import Foundation

public enum TapeError: Error, LocalizedError {
    case unreadable(URL, String)
    case invalidPeakFile(URL)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .unreadable(url, why): return "Cannot read \(url.lastPathComponent): \(why)"
        case let .invalidPeakFile(url): return "Invalid peak file \(url.lastPathComponent)"
        case .cancelled: return "Cancelled"
        }
    }
}

public struct AudioFileInfo: Equatable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var frameCount: Int64

    public init(url: URL) throws {
        do {
            let file = try AVAudioFile(forReading: url)
            sampleRate = file.fileFormat.sampleRate
            channelCount = Int(file.fileFormat.channelCount)
            frameCount = file.length
        } catch {
            throw TapeError.unreadable(url, error.localizedDescription)
        }
    }
}

/// File backed source with an LRU cache of decoded blocks and forward prefetch.
/// The file must already be at session rate (see `Resampler`).
public final class FileSource: SampleSource, @unchecked Sendable {
    public let url: URL
    public let channelCount: Int
    public let frameCount: Int64
    public let sampleRate: Double

    static let blockFrames = 32768
    private let maxBlocks: Int
    private let lock = NSLock()
    private let file: AVAudioFile
    private var cache: [Int64: (buffer: AVAudioPCMBuffer, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    private var prefetching: Set<Int64> = []
    private static let prefetchQueue = DispatchQueue(label: "tape.source.prefetch", qos: .userInitiated)

    public init(url: URL, cacheMegabytes: Int = 32) throws {
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TapeError.unreadable(url, error.localizedDescription)
        }
        self.url = url
        channelCount = Int(file.processingFormat.channelCount)
        frameCount = file.length
        sampleRate = file.processingFormat.sampleRate
        let blockBytes = Self.blockFrames * channelCount * 4
        maxBlocks = max(8, cacheMegabytes * 1_048_576 / max(blockBytes, 1))
    }

    public func read(start: Int64, count: Int, into buffer: SampleBuffer, offset: Int) {
        let channels = min(channelCount, buffer.channelCount)
        var done = 0
        let bf = Int64(Self.blockFrames)
        var lastBlock: Int64 = -1
        while done < count {
            let f = start + Int64(done)
            if f < 0 || f >= frameCount {
                // Zero up to the next in-range frame or the end of the request.
                let next = f < 0 ? min(Int64(count - done), -f) : Int64(count - done)
                for c in 0..<channels { (buffer.channels[c] + offset + done).update(repeating: 0, count: Int(next)) }
                done += Int(next)
                continue
            }
            let blockIndex = f / bf
            let within = Int(f - blockIndex * bf)
            lock.lock()
            let block = loadBlock(blockIndex)
            let available = Int(block.frameLength) - within
            let n = min(count - done, max(available, 0))
            if n > 0, let data = block.floatChannelData {
                for c in 0..<channels {
                    (buffer.channels[c] + offset + done).update(from: data[c] + within, count: n)
                }
            }
            lock.unlock()
            if n <= 0 {
                for c in 0..<channels { (buffer.channels[c] + offset + done).update(repeating: 0, count: count - done) }
                break
            }
            done += n
            lastBlock = blockIndex
        }
        if lastBlock >= 0 { prefetch(lastBlock + 1) }
    }

    /// Caller holds `lock`.
    private func loadBlock(_ index: Int64) -> AVAudioPCMBuffer {
        tick &+= 1
        if let hit = cache[index] {
            cache[index] = (hit.buffer, tick)
            return hit.buffer
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Self.blockFrames))!
        file.framePosition = index * Int64(Self.blockFrames)
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(Self.blockFrames))
        } catch {
            buffer.frameLength = 0
        }
        if cache.count >= maxBlocks, let victim = cache.min(by: { $0.value.tick < $1.value.tick })?.key {
            cache.removeValue(forKey: victim)
        }
        cache[index] = (buffer, tick)
        return buffer
    }

    private func prefetch(_ index: Int64) {
        guard index * Int64(Self.blockFrames) < frameCount else { return }
        lock.lock()
        let needed = cache[index] == nil && !prefetching.contains(index)
        if needed { prefetching.insert(index) }
        lock.unlock()
        guard needed else { return }
        Self.prefetchQueue.async { [self] in
            lock.lock()
            _ = loadBlock(index)
            prefetching.remove(index)
            lock.unlock()
        }
    }
}
