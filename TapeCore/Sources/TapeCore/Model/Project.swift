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

public struct Region: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
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

    public init(id: UUID = UUID(), name: String, sourceId: UUID, sourceIn: Int64, sourceOut: Int64,
                position: Int64, gainDB: Double = 0, fadeIn: Fade = .none, fadeOut: Fade = .none) {
        self.id = id
        self.name = name
        self.sourceId = sourceId
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
        self.position = position
        self.gainDB = gainDB
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

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

    public init(id: UUID = UUID(), name: String, location: Location, sampleRate: Double, channelCount: Int, frameCount: Int64) {
        self.id = id
        self.name = name
        self.location = location
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
    }

    /// Frame count once read at `sessionRate`.
    public func sessionFrameCount(sessionRate: Double) -> Int64 {
        if sampleRate == sessionRate { return frameCount }
        return Int64((Double(frameCount) * sessionRate / sampleRate).rounded())
    }
}

/// The undoable document model.
public struct Project: Codable, Equatable, Sendable {
    /// Rate of the first source; nil while the document is empty.
    public var sessionRate: Double?
    public var channelCount: Int
    public var sources: [SourceRef]
    public var regions: [Region]

    public init(sessionRate: Double? = nil, channelCount: Int = 2, sources: [SourceRef] = [], regions: [Region] = []) {
        self.sessionRate = sessionRate
        self.channelCount = channelCount
        self.sources = sources
        self.regions = regions
    }

    public var length: Int64 { regions.map(\.end).max() ?? 0 }

    public func source(_ id: UUID) -> SourceRef? { sources.first { $0.id == id } }

    public mutating func sortRegions() {
        regions.sort { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
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

    public init() {}
}

/// On-disk shape of `project.json`.
public struct ProjectFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var document: Project
    public var view: ViewState

    public init(document: Project, view: ViewState = ViewState()) {
        self.version = Self.currentVersion
        self.document = document
        self.view = view
    }
}
