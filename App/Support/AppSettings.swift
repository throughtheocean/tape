import AppKit
import Combine

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
    }
}
