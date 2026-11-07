import Foundation

/// Half open range of session frames.
public struct SampleRange: Codable, Equatable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var length: Int64 { end - start }
    public var isEmpty: Bool { end <= start }

    public func contains(_ frame: Int64) -> Bool { frame >= start && frame < end }

    public func clamped(to other: SampleRange) -> SampleRange {
        SampleRange(start: max(start, other.start), end: max(max(start, other.start), min(end, other.end)))
    }
}

public enum FadeShape: String, Codable, CaseIterable, Sendable {
    case linear, sCurve, log, exp

    /// Neighbour used by the continuous shape blend, in the order linear, S, log, exp.
    public var next: FadeShape? {
        switch self {
        case .linear: return .sCurve
        case .sCurve: return .log
        case .log: return .exp
        case .exp: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .sCurve: return "S-Curve"
        case .log: return "Logarithmic"
        case .exp: return "Exponential"
        }
    }
}

public struct Fade: Codable, Equatable, Hashable, Sendable {
    /// Length in session frames.
    public var length: Int64
    public var shape: FadeShape
    /// 0 to 1 blend from `shape` towards `shape.next`.
    public var blend: Double

    public init(length: Int64 = 0, shape: FadeShape = .linear, blend: Double = 0) {
        self.length = length
        self.shape = shape
        self.blend = blend
    }

    public static let none = Fade()
}

/// A connected region's link to a region on a magnetic track: it starts `offset` frames after the anchor's start.
public struct Anchor: Codable, Equatable, Hashable, Sendable {
    public var regionId: UUID
    public var offset: Int64

    public init(regionId: UUID, offset: Int64) {
        self.regionId = regionId
        self.offset = offset
    }
}

public struct Region: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Source id of gap regions: silence of any length that keeps a magnetic sequence intact. No source has it.
    public static let gapSourceID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    /// A gap's `sourceIn`, far from 0 so its start can be trimmed earlier as freely as its end later.
    public static let gapOrigin: Int64 = 1 << 40

    public var id: UUID
    public var name: String
    /// The track the region belongs to.
    public var trackId: UUID
    public var sourceId: UUID
    /// First source frame, at session rate.
    public var sourceIn: Int64
    /// One past the last source frame, at session rate.
    public var sourceOut: Int64
    /// Timeline frame of the region start.
    public var position: Int64
    public var gainDB: Double
    public var fadeIn: Fade
    public var fadeOut: Fade
    /// Set on a connected region: it follows its anchor when the anchor moves.
    public var anchor: Anchor?

    public init(id: UUID = UUID(), name: String, trackId: UUID = Track.firstID, sourceId: UUID, sourceIn: Int64, sourceOut: Int64,
                position: Int64, gainDB: Double = 0, fadeIn: Fade = .none, fadeOut: Fade = .none, anchor: Anchor? = nil) {
        self.id = id
        self.name = name
        self.trackId = trackId
        self.sourceId = sourceId
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
        self.position = position
        self.gainDB = gainDB
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.anchor = anchor
    }

    /// Silence of `length` on `track` at `position`.
    public static func gap(id: UUID = UUID(), track: UUID, position: Int64, length: Int64) -> Region {
        Region(id: id, name: "Gap", trackId: track, sourceId: gapSourceID, sourceIn: gapOrigin, sourceOut: gapOrigin + length,
               position: position)
    }

    public var isGap: Bool { sourceId == Self.gapSourceID }

    public var length: Int64 { sourceOut - sourceIn }
    public var end: Int64 { position + length }
    public var timelineRange: SampleRange { SampleRange(start: position, end: end) }
}

public struct SourceRef: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Location: Codable, Equatable, Hashable, Sendable {
        /// File outside the package, referenced by security scoped bookmark with the path as fallback.
        case external(path: String, bookmark: Data?)
        /// File inside the package `sources/` directory.
        case package(fileName: String)
    }

    public var id: UUID
    public var name: String
    public var location: Location
    /// Native rate of the file.
    public var sampleRate: Double
    public var channelCount: Int
    /// Native frame count of the file.
    public var frameCount: Int64
    /// For recordings: native frames of pre-roll before the moment R was pressed.
    public var preRollFrames: Int64?

    public init(id: UUID = UUID(), name: String, location: Location, sampleRate: Double, channelCount: Int, frameCount: Int64,
                preRollFrames: Int64? = nil) {
        self.id = id
        self.name = name
        self.location = location
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.preRollFrames = preRollFrames
    }

    /// Pre-roll length in session frames, 0 when the source is not a recording.
    public func sessionPreRoll(sessionRate: Double) -> Int64 {
        guard let preRollFrames, preRollFrames > 0 else { return 0 }
        if sampleRate == sessionRate { return preRollFrames }
        return Int64((Double(preRollFrames) * sessionRate / sampleRate).rounded())
    }

    /// Frame count once read at `sessionRate`.
    public func sessionFrameCount(sessionRate: Double) -> Int64 {
        if sampleRate == sessionRate { return frameCount }
        return Int64((Double(frameCount) * sessionRate / sampleRate).rounded())
    }
}

/// A lane of regions with its mix settings. The regions live in `Project.regions` and point here by `trackId`.
public struct Track: Equatable, Hashable, Identifiable, Sendable {
    /// Id of the first track of a new or migrated document.
    public static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// Size of the default color palette; `color` is an index into it.
    public static let paletteCount = 8
    /// Gains at or below this are silence, shown as minus infinity.
    public static let silentDB = -120.0
    public static let maxGainDB = 12.0

    public var id: UUID
    public var name: String
    public var color: Int
    public var gainDB: Double
    /// -1 left to 1 right.
    public var pan: Double
    public var mute: Bool
    public var solo: Bool
    /// The regions are one sequence without gaps from `magneticStart`; positions follow from order and lengths.
    public var magnetic: Bool
    /// Where a magnetic track's sequence starts: the first region's position when magnetic was switched on,
    /// moved by dragging the first region in time.
    public var magneticStart: Int64

    public init(id: UUID = UUID(), name: String, color: Int = 0, gainDB: Double = 0, pan: Double = 0,
                mute: Bool = false, solo: Bool = false, magnetic: Bool = false, magneticStart: Int64 = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.gainDB = gainDB
        self.pan = pan
        self.mute = mute
        self.solo = solo
        self.magnetic = magnetic
        self.magneticStart = magneticStart
    }
}

public struct Master: Codable, Equatable, Hashable, Sendable {
    public var gainDB: Double

    public init(gainDB: Double = 0) { self.gainDB = gainDB }
}

/// The undoable document model. Regions are kept in one list sorted by position; each names its track.
public struct Project: Equatable, Sendable {
    /// Rate of the first source; nil while the document is empty.
    public var sessionRate: Double?
    public var channelCount: Int
    public var sources: [SourceRef]
    public var regions: [Region]
    /// Never empty.
    public var tracks: [Track]
    public var master: Master

    public init(sessionRate: Double? = nil, channelCount: Int = 2, sources: [SourceRef] = [], regions: [Region] = [],
                tracks: [Track] = [], master: Master = Master()) {
        self.sessionRate = sessionRate
        self.channelCount = channelCount
        self.sources = sources
        self.regions = regions
        self.tracks = tracks.isEmpty ? [Track(id: Track.firstID, name: "Track 1", color: 0)] : tracks
        self.master = master
        assignOrphans()
    }

    public var length: Int64 { regions.map(\.end).max() ?? 0 }

    /// Channels the mix renders and plays: always stereo, whatever the first source had. `channelCount` keeps the
    /// first source's count; sessions recorded with more than two channels keep them.
    public var mixChannelCount: Int { max(2, channelCount) }

    public func source(_ id: UUID) -> SourceRef? { sources.first { $0.id == id } }

    public func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } }

    public func trackIndex(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }

    public func regions(onTrack id: UUID) -> [Region] { regions.filter { $0.trackId == id } }

    /// Keeps regions sorted and on existing tracks.
    public mutating func sortRegions() {
        regions.sort { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
        assignOrphans()
    }

    /// Regions whose track does not exist move to the first track.
    mutating func assignOrphans() {
        if tracks.isEmpty { tracks = [Track(id: Track.firstID, name: "Track 1", color: 0)] }
        guard tracks.count > 1 || regions.contains(where: { $0.trackId != tracks[0].id }) else { return }
        let ids = Set(tracks.map(\.id))
        for i in regions.indices where !ids.contains(regions[i].trackId) { regions[i].trackId = tracks[0].id }
    }

    /// Next palette color: the first one no track uses, else in order.
    public var nextTrackColor: Int {
        let used = Set(tracks.map(\.color))
        return (0..<Track.paletteCount).first { !used.contains($0) } ?? tracks.count % Track.paletteCount
    }

    /// "Track N" with the lowest N not in use.
    public var nextTrackName: String {
        let names = Set(tracks.map(\.name))
        var n = tracks.count + 1
        while names.contains("Track \(n)") { n += 1 }
        return "Track \(n)"
    }
}

extension Project: Codable {
    private enum Keys: String, CodingKey { case sessionRate, channelCount, sources, regions, tracks, master }

    /// A track as stored on disk: its fields plus its regions.
    private struct TrackFile: Codable {
        var id: UUID
        var name: String
        var color: Int
        var gainDB: Double
        var pan: Double
        var mute: Bool
        var solo: Bool
        /// Written only when on, so documents without magnetic tracks read as before.
        var magnetic: Bool?
        var magneticStart: Int64?
        var regions: [Region]
    }

    /// Version 2 nests regions in `tracks`. Version 1 has a flat `regions` list, which becomes "Track 1".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        sessionRate = try c.decodeIfPresent(Double.self, forKey: .sessionRate)
        channelCount = try c.decode(Int.self, forKey: .channelCount)
        sources = try c.decode([SourceRef].self, forKey: .sources)
        master = try c.decodeIfPresent(Master.self, forKey: .master) ?? Master()
        if let files = try c.decodeIfPresent([TrackFile].self, forKey: .tracks) {
            tracks = files.map { Track(id: $0.id, name: $0.name, color: $0.color, gainDB: $0.gainDB, pan: $0.pan,
                                       mute: $0.mute, solo: $0.solo, magnetic: $0.magnetic ?? false,
                                       magneticStart: $0.magneticStart ?? 0) }
            regions = files.flatMap { f in f.regions.map { r in
                var r = r
                r.trackId = f.id
                return r
            } }
        } else {
            tracks = []
            regions = try c.decode([VersionOneRegion].self, forKey: .regions).map(\.region)
        }
        sortRegions()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(sessionRate, forKey: .sessionRate)
        try c.encode(channelCount, forKey: .channelCount)
        try c.encode(sources, forKey: .sources)
        try c.encode(master, forKey: .master)
        let files = tracks.map { t in
            TrackFile(id: t.id, name: t.name, color: t.color, gainDB: max(t.gainDB, Track.silentDB), pan: t.pan, mute: t.mute,
                      solo: t.solo, magnetic: t.magnetic ? true : nil,
                      magneticStart: t.magnetic && t.magneticStart != 0 ? t.magneticStart : nil, regions: regions.filter { $0.trackId == t.id })
        }
        try c.encode(files, forKey: .tracks)
    }
}

/// A region from a version 1 file, which has no `trackId`.
private struct VersionOneRegion: Decodable {
    var region: Region

    private enum Keys: String, CodingKey { case id, name, sourceId, sourceIn, sourceOut, position, gainDB, fadeIn, fadeOut }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        region = Region(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                        trackId: Track.firstID, sourceId: try c.decode(UUID.self, forKey: .sourceId),
                        sourceIn: try c.decode(Int64.self, forKey: .sourceIn), sourceOut: try c.decode(Int64.self, forKey: .sourceOut),
                        position: try c.decode(Int64.self, forKey: .position), gainDB: try c.decode(Double.self, forKey: .gainDB),
                        fadeIn: try c.decode(Fade.self, forKey: .fadeIn), fadeOut: try c.decode(Fade.self, forKey: .fadeOut))
    }
}

/// Editor state saved with the document but not part of undo.
public struct ViewState: Codable, Equatable, Sendable {
    public var playhead: Int64 = 0
    public var range: SampleRange?
    public var loopEnabled = false
    public var viewStart: Double = 0
    public var samplesPerPoint: Double?
    public var amplitudeZoom: Double = 1
    /// Multitrack view instead of the single track view.
    public var multitrack = false
    /// The track the single view shows and recordings go to.
    public var selectedTrack: UUID?
    /// Lane height in the multitrack view, points.
    public var laneHeight: Double = 80
    /// The selected track's lane at full waveform detail.
    public var expandSelected = false
    /// Vertical scroll of the lanes, points.
    public var laneScroll: Double = 0

    public init() {}

    private enum Keys: String, CodingKey {
        case playhead, range, loopEnabled, viewStart, samplesPerPoint, amplitudeZoom
        case multitrack, selectedTrack, laneHeight, expandSelected, laneScroll
    }

    /// Fields missing from older files keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        playhead = try c.decodeIfPresent(Int64.self, forKey: .playhead) ?? 0
        range = try c.decodeIfPresent(SampleRange.self, forKey: .range)
        loopEnabled = try c.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? false
        viewStart = try c.decodeIfPresent(Double.self, forKey: .viewStart) ?? 0
        samplesPerPoint = try c.decodeIfPresent(Double.self, forKey: .samplesPerPoint)
        amplitudeZoom = try c.decodeIfPresent(Double.self, forKey: .amplitudeZoom) ?? 1
        multitrack = try c.decodeIfPresent(Bool.self, forKey: .multitrack) ?? false
        selectedTrack = try c.decodeIfPresent(UUID.self, forKey: .selectedTrack)
        laneHeight = try c.decodeIfPresent(Double.self, forKey: .laneHeight) ?? 80
        expandSelected = try c.decodeIfPresent(Bool.self, forKey: .expandSelected) ?? false
        laneScroll = try c.decodeIfPresent(Double.self, forKey: .laneScroll) ?? 0
    }
}

/// On-disk shape of `project.json`.
public struct ProjectFile: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var document: Project
    public var view: ViewState

    public init(document: Project, view: ViewState = ViewState()) {
        self.version = Self.currentVersion
        self.document = document
        self.view = view
    }
}
