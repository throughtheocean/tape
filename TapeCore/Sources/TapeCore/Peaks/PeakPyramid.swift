import Accelerate
import AVFoundation
import Foundation

/// Min and max per block for block sizes 16, 256, 4096 and 65536, stored as Float16
/// interleaved `[block][channel][min, max]`. Block size 1 is the source itself.
public final class PeakPyramid: @unchecked Sendable {
    public static let blockSizes = [16, 256, 4096, 65536]
    static let magic: UInt32 = 0x534B_5054 // "TPKS"
    static let version: UInt32 = 1
    static let headerSize = 256

    public struct Level: Sendable {
        public let blockSize: Int
        public let blockCount: Int
        let byteOffset: Int
    }

    public let channelCount: Int
    public let frameCount: Int64
    public let sampleRate: Double
    public let levels: [Level]

    private let base: UnsafeMutableRawPointer
    private let byteCount: Int
    private let isMapped: Bool

    // MARK: Layout

    static func layout(channelCount: Int, frameCount: Int64) -> (levels: [Level], bytes: Int) {
        var offset = headerSize
        var levels: [Level] = []
        for bs in blockSizes {
            let count = Int((frameCount + Int64(bs) - 1) / Int64(bs))
            levels.append(Level(blockSize: bs, blockCount: count, byteOffset: offset))
            offset += count * channelCount * 2 * MemoryLayout<Float16>.size
            offset = (offset + 15) & ~15
        }
        return (levels, offset)
    }

    private init(channelCount: Int, frameCount: Int64, sampleRate: Double) {
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        let l = Self.layout(channelCount: channelCount, frameCount: frameCount)
        levels = l.levels
        byteCount = l.bytes
        base = UnsafeMutableRawPointer.allocate(byteCount: l.bytes, alignment: 16)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: l.bytes)
        isMapped = false
        writeHeader()
    }

    private init(mapped: UnsafeMutableRawPointer, bytes: Int, channelCount: Int, frameCount: Int64,
                 sampleRate: Double, levels: [Level]) {
        base = mapped
        byteCount = bytes
        isMapped = true
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.levels = levels
    }

    deinit {
        if isMapped { munmap(base, byteCount) } else { base.deallocate() }
    }

    private func writeHeader() {
        base.storeBytes(of: Self.magic, toByteOffset: 0, as: UInt32.self)
        base.storeBytes(of: Self.version, toByteOffset: 4, as: UInt32.self)
        base.storeBytes(of: UInt32(channelCount), toByteOffset: 8, as: UInt32.self)
        base.storeBytes(of: UInt32(levels.count), toByteOffset: 12, as: UInt32.self)
        base.storeBytes(of: frameCount, toByteOffset: 16, as: Int64.self)
        base.storeBytes(of: sampleRate, toByteOffset: 24, as: Double.self)
        for (i, level) in levels.enumerated() {
            let o = 64 + i * 32
            base.storeBytes(of: Int64(level.blockSize), toByteOffset: o, as: Int64.self)
            base.storeBytes(of: Int64(level.blockCount), toByteOffset: o + 8, as: Int64.self)
            base.storeBytes(of: Int64(level.byteOffset), toByteOffset: o + 16, as: Int64.self)
        }
    }

    @inline(__always)
    func pointer(level: Int) -> UnsafeMutablePointer<Float16> {
        (base + levels[level].byteOffset).assumingMemoryBound(to: Float16.self)
    }

    /// Min and max of one block.
    public func minMax(level: Int, block: Int, channel: Int) -> (min: Float, max: Float) {
        let p = pointer(level: level) + (block * channelCount + channel) * 2
        return (Float(p[0]), Float(p[1]))
    }

    // MARK: Query

    /// Index of the coarsest level whose block size is at most `framesPerColumn`, or nil below 16.
    public func levelIndex(framesPerColumn: Double) -> Int? {
        var best: Int?
        for (i, l) in levels.enumerated() where Double(l.blockSize) <= framesPerColumn { best = i }
        return best
    }

    /// Fills `mins` and `maxs` with one value per column. Column `i` covers frames
    /// `start + i * framesPerColumn ..< start + (i + 1) * framesPerColumn`.
    /// Columns outside the source get `min > max` (nothing to draw).
    public func columns(start: Double, framesPerColumn: Double, count: Int, channel: Int, level: Int,
                        mins: UnsafeMutablePointer<Float>, maxs: UnsafeMutablePointer<Float>) {
        let l = levels[level]
        let bs = Double(l.blockSize)
        let p = UnsafePointer(pointer(level: level))
        let stride = channelCount * 2
        for i in 0..<count {
            let f0 = start + Double(i) * framesPerColumn
            let f1 = f0 + framesPerColumn
            var b0 = Int((f0 / bs).rounded(.down))
            var b1 = Int((f1 / bs).rounded(.up))
            b0 = max(b0, 0)
            b1 = min(b1, l.blockCount)
            if b1 <= b0 {
                mins[i] = 1
                maxs[i] = -1
                continue
            }
            var lo = Float.greatestFiniteMagnitude
            var hi = -Float.greatestFiniteMagnitude
            var q = p + b0 * stride + channel * 2
            for _ in b0..<b1 {
                let a = Float(q[0]), b = Float(q[1])
                if a < lo { lo = a }
                if b > hi { hi = b }
                q += stride
            }
            mins[i] = lo
            maxs[i] = hi
        }
    }

    // MARK: Build

    /// Builds from a file in parallel segments, each with its own `AVAudioFile`.
    public static func build(url: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> PeakPyramid {
        let info = try AudioFileInfo(url: url)
        return try build(channelCount: info.channelCount, frameCount: info.frameCount, sampleRate: info.sampleRate,
                         isCancelled: isCancelled) {
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunkFrames))!
            return { start, count in
                file.framePosition = start
                try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
                let got = Int(buffer.frameLength)
                if got < count, let data = buffer.floatChannelData {
                    for c in 0..<Int(buffer.format.channelCount) { (data[c] + got).update(repeating: 0, count: count - got) }
                }
                return UnsafePointer(buffer.floatChannelData!)
            }
        }
    }

    /// Builds from any sample source.
    public static func build(source: SampleSource, sampleRate: Double) throws -> PeakPyramid {
        try build(channelCount: source.channelCount, frameCount: source.frameCount, sampleRate: sampleRate) {
            let state = SourceReaderState(channelCount: source.channelCount, capacity: chunkFrames)
            return { start, count in
                source.read(start: start, count: count, into: state.buffer, offset: 0)
                return UnsafePointer(state.pointers)
            }
        }
    }

    private final class SourceReaderState {
        let buffer: SampleBuffer
        let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

        init(channelCount: Int, capacity: Int) {
            buffer = SampleBuffer(channelCount: channelCount, capacity: capacity)
            pointers = .allocate(capacity: channelCount)
            for (i, p) in buffer.channels.enumerated() { pointers[i] = p }
        }

        deinit { pointers.deallocate() }
    }

    static let chunkFrames = 65536 * 4

    /// A reader returns per-channel pointers holding `count` frames from `start`.
    typealias Reader = (_ start: Int64, _ count: Int) throws -> UnsafePointer<UnsafeMutablePointer<Float>>

    static func build(channelCount: Int, frameCount: Int64, sampleRate: Double,
                      isCancelled: @escaping @Sendable () -> Bool = { false },
                      makeReader: @escaping () throws -> Reader) throws -> PeakPyramid {
        let pyramid = PeakPyramid(channelCount: channelCount, frameCount: frameCount, sampleRate: sampleRate)
        guard frameCount > 0, channelCount > 0 else { return pyramid }

        let top = Int64(blockSizes.last!)
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let topBlocks = (frameCount + top - 1) / top
        let segmentBlocks = max(1, (topBlocks + Int64(cores) - 1) / Int64(cores))
        let segmentFrames = segmentBlocks * top
        let segments = Int((frameCount + segmentFrames - 1) / segmentFrames)

        let errors = ErrorBox()
        let makeReaderBox = UncheckedBox(makeReader)
        DispatchQueue.concurrentPerform(iterations: segments) { s in
            let s0 = Int64(s) * segmentFrames
            let s1 = min(frameCount, s0 + segmentFrames)
            do {
                let reader = try makeReaderBox.value()
                try pyramid.buildSegment(from: s0, to: s1, reader: reader, isCancelled: isCancelled)
            } catch {
                errors.set(error)
            }
        }
        if let e = errors.error { throw e }
        return pyramid
    }

    private func buildSegment(from s0: Int64, to s1: Int64, reader: Reader, isCancelled: () -> Bool) throws {
        let chunk = Self.chunkFrames
        let levelCount = Self.blockSizes.count
        let scratch = chunk / 16 + 1
        let mins = (0..<levelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: scratch) }
        let maxs = (0..<levelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: scratch) }
        defer {
            mins.forEach { $0.deallocate() }
            maxs.forEach { $0.deallocate() }
        }
        let stride = channelCount * 2
        var pos = s0
        while pos < s1 {
            if isCancelled() { throw TapeError.cancelled }
            let n = Int(min(Int64(chunk), s1 - pos))
            let data = try reader(pos, n)
            for c in 0..<channelCount {
                var count = n
                for li in 0..<levelCount {
                    let lo = li == 0 ? UnsafePointer(data[c]) : UnsafePointer(mins[li - 1])
                    let hi = li == 0 ? UnsafePointer(data[c]) : UnsafePointer(maxs[li - 1])
                    let produced = Self.reduce(lo, hi, count: count, window: 16, mins: mins[li], maxs: maxs[li])
                    // Chunk starts are aligned to every block size.
                    let firstBlock = Int(pos / Int64(Self.blockSizes[li]))
                    let dst = pointer(level: li) + (firstBlock * channelCount + c) * 2
                    let mn = mins[li], mx = maxs[li]
                    for b in 0..<produced {
                        dst[b * stride] = Float16(mn[b])
                        dst[b * stride + 1] = Float16(mx[b])
                    }
                    count = produced
                }
            }
            pos += Int64(n)
        }
    }

    /// Min of `lo` and max of `hi` over consecutive windows using strided vDSP passes.
    /// Returns the number of windows written, including a partial tail window.
    @discardableResult
    static func reduce(_ lo: UnsafePointer<Float>, _ hi: UnsafePointer<Float>, count: Int, window w: Int,
                       mins: UnsafeMutablePointer<Float>, maxs: UnsafeMutablePointer<Float>) -> Int {
        let full = count / w
        if full > 0 {
            let n = vDSP_Length(full)
            let s = vDSP_Stride(w)
            vDSP_vmin(lo, s, lo, s, mins, 1, n)
            vDSP_vmax(hi, s, hi, s, maxs, 1, n)
            for k in 1..<w {
                vDSP_vmin(mins, 1, lo + k, s, mins, 1, n)
                vDSP_vmax(maxs, 1, hi + k, s, maxs, 1, n)
            }
        }
        let rem = count - full * w
        if rem > 0 {
            var a: Float = 0, b: Float = 0
            vDSP_minv(lo + full * w, 1, &a, vDSP_Length(rem))
            vDSP_maxv(hi + full * w, 1, &b, vDSP_Length(rem))
            mins[full] = a
            maxs[full] = b
            return full + 1
        }
        return full
    }

    // MARK: File IO

    public func write(to url: URL) throws {
        let data = Data(bytesNoCopy: base, count: byteCount, deallocator: .none)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> PeakPyramid {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw TapeError.invalidPeakFile(url) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= headerSize else { throw TapeError.invalidPeakFile(url) }
        let size = Int(st.st_size)
        guard let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), raw != MAP_FAILED else {
            throw TapeError.invalidPeakFile(url)
        }
        let p = UnsafeMutableRawPointer(raw)
        let magic = p.load(fromByteOffset: 0, as: UInt32.self)
        let version = p.load(fromByteOffset: 4, as: UInt32.self)
        let channels = Int(p.load(fromByteOffset: 8, as: UInt32.self))
        let levelCount = Int(p.load(fromByteOffset: 12, as: UInt32.self))
        let frames = p.load(fromByteOffset: 16, as: Int64.self)
        let rate = p.load(fromByteOffset: 24, as: Double.self)
        guard magic == Self.magic, version == Self.version, levelCount == blockSizes.count,
              (1...1024).contains(channels), frames >= 0, frames < Int64(1) << 40,
              layout(channelCount: channels, frameCount: frames).bytes == size else {
            munmap(raw, size)
            throw TapeError.invalidPeakFile(url)
        }
        let expected = layout(channelCount: channels, frameCount: frames)
        return PeakPyramid(mapped: p, bytes: size, channelCount: channels, frameCount: frames,
                           sampleRate: rate, levels: expected.levels)
    }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var error: Error? { lock.withLock { stored } }
    func set(_ e: Error) { lock.withLock { if stored == nil { stored = e } } }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
