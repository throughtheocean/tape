import AppKit
import Combine
import TapeCore

enum TimeDisplay: String, CaseIterable, Identifiable {
    case timecode, milliseconds, samples
    var id: String { rawValue }

    var label: String {
        switch self {
        case .timecode: return "Timecode"
        case .milliseconds: return "Milliseconds"
        case .samples: return "Samples"
        }
    }
}

/// User settings persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    @Published var timeDisplay: TimeDisplay {
        didSet { defaults.set(timeDisplay.rawValue, forKey: "timeDisplay") }
    }

    @Published var frameRate: Double {
        didSet { defaults.set(frameRate, forKey: "frameRate") }
    }

    @Published var accentHex: UInt32 {
        didSet { defaults.set(Int(accentHex), forKey: "accentColor") }
    }

    @Published var inspectorVisible: Bool {
        didSet { defaults.set(inspectorVisible, forKey: "inspectorVisible") }
    }

    /// Range edges (and in M3 trims and marks) snap to the nearest zero crossing.
    @Published var snapToZeroCrossing: Bool {
        didSet { defaults.set(snapToZeroCrossing, forKey: "snapToZeroCrossing") }
    }

    // MARK: Record settings

    /// UID of the chosen input device; empty means no input.
    @Published var recordDeviceUID: String? {
        didSet { defaults.set(recordDeviceUID, forKey: "recordDeviceUID") }
    }

    /// Zero based device channels, one or two.
    @Published var recordChannels: [Int] {
        didSet { defaults.set(recordChannels, forKey: "recordChannels") }
    }

    @Published var recordContainer: AudioContainer {
        didSet { defaults.set(recordContainer.rawValue, forKey: "recordContainer") }
    }

    @Published var recordSampleFormat: SampleFormat {
        didSet { defaults.set(recordSampleFormat.rawValue, forKey: "recordSampleFormat") }
    }

    /// 0 to 60 seconds.
    @Published var preRollSeconds: Double {
        didSet { defaults.set(preRollSeconds, forKey: "preRollSeconds") }
    }

    /// When the playhead is inside a region at R: place the recording right after that region
    /// instead of at the end of the document.
    @Published var recordSnapAfterRegion: Bool {
        didSet { defaults.set(recordSnapAfterRegion, forKey: "recordSnapAfterRegion") }
    }

    // MARK: Edit settings

    static let defaultFadeChoices: [Double] = [2, 5, 10, 20, 50, 100, 250, 500]
    static let nudgeChoices: [Double] = [1, 10, 100]

    /// Length the F key gives both ends of the selected regions, in ms.
    @Published var defaultFadeMs: Double {
        didSet { defaults.set(defaultFadeMs, forKey: "defaultFadeMs") }
    }

    /// Step of the , and . keys, in ms.
    @Published var nudgeMs: Double {
        didSet { defaults.set(nudgeMs, forKey: "nudgeMs") }
    }

    var inspectorWidth: Double {
        get { (defaults.object(forKey: "inspectorWidth") as? Double) ?? 280 }
        set { defaults.set(newValue, forKey: "inspectorWidth") }
    }

    var accentColor: NSColor { NSColor(hex: accentHex) }

    /// Paths of documents open at quit or crash, reopened on launch.
    var openDocuments: [String] {
        get { defaults.stringArray(forKey: "openDocuments") ?? [] }
        set { defaults.set(newValue, forKey: "openDocuments") }
    }

    private init() {
        timeDisplay = TimeDisplay(rawValue: defaults.string(forKey: "timeDisplay") ?? "") ?? .timecode
        let rate = defaults.double(forKey: "frameRate")
        frameRate = rate > 0 ? rate : 25
        let hex = defaults.object(forKey: "accentColor") as? Int
        accentHex = UInt32(hex ?? 0x3B82F6)
        inspectorVisible = defaults.object(forKey: "inspectorVisible") as? Bool ?? true
        snapToZeroCrossing = defaults.object(forKey: "snapToZeroCrossing") as? Bool ?? true
        recordDeviceUID = defaults.string(forKey: "recordDeviceUID")
        recordChannels = (defaults.array(forKey: "recordChannels") as? [Int]) ?? [0, 1]
        recordContainer = AudioContainer(rawValue: defaults.string(forKey: "recordContainer") ?? "") ?? .wav
        recordSampleFormat = SampleFormat(rawValue: defaults.string(forKey: "recordSampleFormat") ?? "") ?? .int24
        preRollSeconds = defaults.object(forKey: "preRollSeconds") as? Double ?? 10
        recordSnapAfterRegion = defaults.object(forKey: "recordSnapAfterRegion") as? Bool ?? false
        defaultFadeMs = defaults.object(forKey: "defaultFadeMs") as? Double ?? 10
        nudgeMs = defaults.object(forKey: "nudgeMs") as? Double ?? 10
    }
}
