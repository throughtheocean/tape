import Accelerate
import Foundation

/// Immutable snapshot of what the renderer plays: regions plus the sources they read.
public struct EditList: @unchecked Sendable {
    public var regions: [Region]
    public var sources: [UUID: SampleSource]
    public var channelCount: Int

    public init(regions: [Region], sources: [UUID: SampleSource], channelCount: Int) {
        self.regions = regions.sorted { $0.position < $1.position }
        self.sources = sources
        self.channelCount = channelCount
    }

    public static let empty = EditList(regions: [], sources: [:], channelCount: 2)

    public var length: Int64 { regions.map(\.end).max() ?? 0 }
}

/// Pulls samples for any timeline range from an edit list. The only place that applies
/// region gain and fades; playback and export both go through it.
public final class EditListRenderer: @unchecked Sendable {
    public let maxFrames: Int
    private var scratch: SampleBuffer
    private let envelope: UnsafeMutablePointer<Float>

    public init(maxFrames: Int = 8192) {
        self.maxFrames = maxFrames
        scratch = SampleBuffer(channelCount: 2, capacity: maxFrames)
        envelope = .allocate(capacity: maxFrames)
    }

    deinit { envelope.deallocate() }

    /// Renders timeline frames `start ..< start + frames` into `out` at `offset`, all `list.channelCount` channels.
    public func render(_ list: EditList, start: Int64, frames: Int, into out: SampleBuffer, offset: Int = 0) {
        var done = 0
        while done < frames {
            let n = min(maxFrames, frames - done)
            renderChunk(list, start: start + Int64(done), frames: n, into: out, offset: offset + done)
            done += n
        }
    }

    private func renderChunk(_ list: EditList, start: Int64, frames: Int, into out: SampleBuffer, offset: Int) {
        let outChannels = min(list.channelCount, out.channelCount)
        out.zero(offset: offset, count: frames)
        let end = start + Int64(frames)
        for region in list.regions {
            if region.position >= end { break }
            if region.end <= start || region.length <= 0 { continue }
            guard let source = list.sources[region.sourceId] else { continue }
            let a = max(start, region.position)
            let b = min(end, region.end)
            let n = Int(b - a)
            let r0 = a - region.position

            if scratch.channelCount < source.channelCount {
                scratch = SampleBuffer(channelCount: source.channelCount, capacity: maxFrames)
            }
            source.read(start: region.sourceIn + r0, count: n, into: scratch, offset: 0)
            fillEnvelope(region, regionOffset: r0, count: n)

            let srcChannels = source.channelCount
            for c in 0..<outChannels {
                let sc: Int
                if srcChannels == 1 { sc = 0 } else if c < srcChannels { sc = c } else { continue }
                let dst = out.channels[c] + offset + Int(a - start)
                vDSP_vma(scratch.channels[sc], 1, envelope, 1, dst, 1, dst, 1, vDSP_Length(n))
            }
        }
    }

    /// Gain times fade-in times fade-out for region frames `r0 ..< r0 + count`.
    func fillEnvelope(_ region: Region, regionOffset r0: Int64, count n: Int) {
        var gain = Float(pow(10, region.gainDB / 20))
        vDSP_vfill(&gain, envelope, 1, vDSP_Length(n))
        let (fi, fo) = Self.effectiveFadeLengths(region)
        let length = region.length
        FadeCurves.tables.withUnsafeBufferPointer { tables in
            let t = tables.baseAddress!
            if fi > 0, r0 < fi {
                let stop = Int(min(Int64(n), fi - r0))
                for i in 0..<stop {
                    let x = Double(r0 + Int64(i)) / Double(fi)
                    envelope[i] *= FadeCurves.value(t, shape: region.fadeIn.shape, blend: region.fadeIn.blend, x: x)
                }
            }
            if fo > 0 {
                let zone = length - fo
                if r0 + Int64(n) > zone {
                    let first = Int(max(0, zone - r0))
                    for i in first..<n {
                        let x = Double(length - (r0 + Int64(i))) / Double(fo)
                        envelope[i] *= FadeCurves.value(t, shape: region.fadeOut.shape, blend: region.fadeOut.blend, x: x)
                    }
                }
            }
        }
    }

    /// Fades that together exceed the region are scaled down proportionally.
    public static func effectiveFadeLengths(_ region: Region) -> (Int64, Int64) {
        let fi = max(0, region.fadeIn.length), fo = max(0, region.fadeOut.length)
        let length = region.length
        guard fi + fo > length, fi + fo > 0 else { return (fi, fo) }
        let scaledIn = Int64(Double(fi) * Double(length) / Double(fi + fo))
        return (scaledIn, length - scaledIn)
    }
}
