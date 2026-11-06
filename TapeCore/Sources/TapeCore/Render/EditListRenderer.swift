import Accelerate
import Foundation

/// Mix settings of one track, as the renderer sees them.
public struct TrackMix: Equatable, Sendable {
    public var id: UUID
    public var gainDB: Double
    public var pan: Double
    public var mute: Bool
    public var solo: Bool

    public init(id: UUID, gainDB: Double = 0, pan: Double = 0, mute: Bool = false, solo: Bool = false) {
        self.id = id
        self.gainDB = gainDB
        self.pan = pan
        self.mute = mute
        self.solo = solo
    }

    public init(_ track: Track) {
        self.init(id: track.id, gainDB: track.gainDB, pan: track.pan, mute: track.mute, solo: track.solo)
    }

    /// Linear track gain; at or below `Track.silentDB` it is 0.
    public var gain: Float { gainDB <= Track.silentDB ? 0 : Float(pow(10, gainDB / 20)) }

    /// Per output channel gain for a source with `sourceChannels` into two output channels.
    /// Mono sources pan with constant power (-3 dB each side at centre). Stereo sources are balanced:
    /// the side away from the pan is attenuated along a quarter cosine, the other stays at unity.
    public static func panGains(pan: Double, sourceChannels: Int) -> (Float, Float) {
        let p = min(max(pan, -1), 1)
        if sourceChannels == 1 {
            let theta = (p + 1) * .pi / 4
            return (Float(cos(theta)), Float(sin(theta)))
        }
        if p > 0 { return (Float(cos(p * .pi / 2)), 1) }
        if p < 0 { return (1, Float(cos(-p * .pi / 2))) }
        return (1, 1)
    }
}

/// Immutable snapshot of what the renderer plays: regions plus the sources they read, and the mix.
///
/// Without `tracks` every region is summed at unity, as before tracks existed (tools, previews of a lone region).
/// With `tracks`, regions are summed per track, panned, scaled by track gain, muted or soloed, then summed and
/// scaled by the master gain. Regions on a track that is not in `tracks` are left out.
public struct EditList: @unchecked Sendable {
    public var regions: [Region]
    public var sources: [UUID: SampleSource]
    public var channelCount: Int
    public var tracks: [TrackMix]
    public var masterGainDB: Double
    /// Index into `tracks` per region, -1 when the list has no tracks.
    let trackOfRegion: [Int]

    public init(regions: [Region], sources: [UUID: SampleSource], channelCount: Int, tracks: [TrackMix] = [],
                masterGainDB: Double = 0) {
        let index = Dictionary(tracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = regions.sorted { $0.position < $1.position }
            .filter { tracks.isEmpty || index[$0.trackId] != nil }
        self.regions = sorted
        self.sources = sources
        self.channelCount = channelCount
        self.tracks = tracks
        self.masterGainDB = masterGainDB
        trackOfRegion = tracks.isEmpty ? Array(repeating: -1, count: sorted.count) : sorted.map { index[$0.trackId]! }
    }

    /// The whole project through the mix; regions whose source is not in `sources` are left out.
    public init(project: Project, sources: [UUID: SampleSource]) {
        self.init(regions: project.regions.filter { sources[$0.sourceId] != nil }, sources: sources,
                  channelCount: project.channelCount, tracks: project.tracks.map(TrackMix.init),
                  masterGainDB: project.master.gainDB)
    }

    /// Same sources and mix, other regions.
    public func with(regions: [Region], sources: [UUID: SampleSource]? = nil) -> EditList {
        EditList(regions: regions, sources: sources ?? self.sources, channelCount: channelCount, tracks: tracks,
                 masterGainDB: masterGainDB)
    }

    /// One track alone, solo ignored, master gain left out: the stem of that track as it feeds the mix.
    public func stem(_ trackId: UUID) -> EditList {
        guard var t = tracks.first(where: { $0.id == trackId }) else { return with(regions: []) }
        t.solo = false
        return EditList(regions: regions.filter { $0.trackId == trackId }, sources: sources, channelCount: channelCount,
                        tracks: [t], masterGainDB: 0)
    }

    public static let empty = EditList(regions: [], sources: [:], channelCount: 2)

    public var length: Int64 { regions.map(\.end).max() ?? 0 }

    public var masterGain: Float { masterGainDB <= Track.silentDB ? 0 : Float(pow(10, masterGainDB / 20)) }
}

/// Pulls samples for any timeline range from an edit list. The only place that applies
/// region gain, fades and the track mix; playback and export both go through it.
public final class EditListRenderer: @unchecked Sendable {
    public let maxFrames: Int
    private var scratch: SampleBuffer
    private var trackBuffer: SampleBuffer
    private let envelope: UnsafeMutablePointer<Float>
    private let channelEnvelope: UnsafeMutablePointer<Float>

    /// Peak per track of `list.tracks` (post gain and pan, max over channels, 0 when not audible), from the last
    /// `render` call, accumulated over its chunks. Only filled while `metering` is on.
    public private(set) var trackPeaks: [Float] = []
    /// Peak per output channel after the master gain, from the last `render` call.
    public private(set) var masterPeaks: [Float] = []
    public var metering = false

    public init(maxFrames: Int = 8192) {
        self.maxFrames = maxFrames
        scratch = SampleBuffer(channelCount: 2, capacity: maxFrames)
        trackBuffer = SampleBuffer(channelCount: 2, capacity: maxFrames)
        envelope = .allocate(capacity: maxFrames)
        channelEnvelope = .allocate(capacity: maxFrames)
    }

    deinit {
        envelope.deallocate()
        channelEnvelope.deallocate()
    }

    /// Renders timeline frames `start ..< start + frames` into `out` at `offset`, all `list.channelCount` channels.
    public func render(_ list: EditList, start: Int64, frames: Int, into out: SampleBuffer, offset: Int = 0) {
        if metering {
            if trackPeaks.count != list.tracks.count { trackPeaks = Array(repeating: 0, count: list.tracks.count) }
            for i in trackPeaks.indices { trackPeaks[i] = 0 }
            let outChannels = min(list.channelCount, out.channelCount)
            if masterPeaks.count != outChannels { masterPeaks = Array(repeating: 0, count: outChannels) }
            for i in masterPeaks.indices { masterPeaks[i] = 0 }
        }
        var done = 0
        while done < frames {
            let n = min(maxFrames, frames - done)
            if list.tracks.isEmpty {
                renderChunk(list, start: start + Int64(done), frames: n, into: out, offset: offset + done)
            } else {
                renderMix(list, start: start + Int64(done), frames: n, into: out, offset: offset + done)
            }
            done += n
        }
    }

    private func renderChunk(_ list: EditList, start: Int64, frames: Int, into out: SampleBuffer, offset: Int) {
        let outChannels = min(list.channelCount, out.channelCount)
        out.zero(offset: offset, count: frames)
        let end = start + Int64(frames)
        for region in list.regions {
            if region.position >= end { break }
            addRegion(region, list: list, start: start, end: end, into: out, offset: offset, outChannels: outChannels,
                      gain: 1, pan: nil)
        }
        applyMaster(list, out: out, offset: offset, frames: frames, outChannels: outChannels)
    }

    private func renderMix(_ list: EditList, start: Int64, frames: Int, into out: SampleBuffer, offset: Int) {
        let outChannels = min(list.channelCount, out.channelCount)
        out.zero(offset: offset, count: frames)
        if trackBuffer.channelCount < outChannels || trackBuffer.capacity < maxFrames {
            trackBuffer = SampleBuffer(channelCount: max(outChannels, 2), capacity: maxFrames)
        }
        let end = start + Int64(frames)
        let anySolo = list.tracks.contains { $0.solo }
        for (t, track) in list.tracks.enumerated() {
            let audible = !track.mute && (!anySolo || track.solo)
            let gain = track.gain
            guard audible, gain > 0 else { continue }
            trackBuffer.zero(offset: 0, count: frames)
            var touched = false
            for (i, region) in list.regions.enumerated() {
                if region.position >= end { break }
                guard list.trackOfRegion[i] == t, region.end > start else { continue }
                touched = addRegion(region, list: list, start: start, end: end, into: trackBuffer, offset: 0,
                                    outChannels: outChannels, gain: gain, pan: track.pan) || touched
            }
            guard touched else { continue }
            for c in 0..<outChannels {
                let src = trackBuffer.channels[c]
                if metering {
                    var peak: Float = 0
                    vDSP_maxmgv(src, 1, &peak, vDSP_Length(frames))
                    trackPeaks[t] = max(trackPeaks[t], peak)
                }
                let dst = out.channels[c] + offset
                vDSP_vadd(src, 1, dst, 1, dst, 1, vDSP_Length(frames))
            }
        }
        applyMaster(list, out: out, offset: offset, frames: frames, outChannels: outChannels)
    }

    private func applyMaster(_ list: EditList, out: SampleBuffer, offset: Int, frames: Int, outChannels: Int) {
        var g = list.masterGain
        for c in 0..<outChannels {
            let dst = out.channels[c] + offset
            if g != 1 { vDSP_vsmul(dst, 1, &g, dst, 1, vDSP_Length(frames)) }
            if metering {
                var peak: Float = 0
                vDSP_maxmgv(dst, 1, &peak, vDSP_Length(frames))
                masterPeaks[c] = max(masterPeaks[c], peak)
            }
        }
    }

    /// Adds the part of `region` inside `start ..< end` to `out`, with region gain and fades times `gain`.
    /// With `pan` and two output channels, mono sources are panned and stereo sources balanced.
    @discardableResult
    private func addRegion(_ region: Region, list: EditList, start: Int64, end: Int64, into out: SampleBuffer, offset: Int,
                           outChannels: Int, gain: Float, pan: Double?) -> Bool {
        if region.end <= start || region.length <= 0 { return false }
        guard let source = list.sources[region.sourceId] else { return false }
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
        var sideGains: (Float, Float) = (1, 1)
        if let pan, outChannels == 2 { sideGains = TrackMix.panGains(pan: pan, sourceChannels: srcChannels) }
        for c in 0..<outChannels {
            let sc: Int
            if srcChannels == 1 { sc = 0 } else if c < srcChannels { sc = c } else { continue }
            var g = gain * (outChannels == 2 ? (c == 0 ? sideGains.0 : sideGains.1) : 1)
            guard g > 0 else { continue }
            let dst = out.channels[c] + offset + Int(a - start)
            if g == 1 {
                vDSP_vma(scratch.channels[sc], 1, envelope, 1, dst, 1, dst, 1, vDSP_Length(n))
            } else {
                vDSP_vsmul(envelope, 1, &g, channelEnvelope, 1, vDSP_Length(n))
                vDSP_vma(scratch.channels[sc], 1, channelEnvelope, 1, dst, 1, dst, 1, vDSP_Length(n))
            }
        }
        return true
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
