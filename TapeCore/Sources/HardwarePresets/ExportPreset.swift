import AVFoundation
import Foundation

// Copied from PolyTracker (`Models/ExportPreset.swift`, limits from `Audio/Engine/ChainBuilder.swift`).
// Changes: public and Sendable, the custom preset store left out, `limits` and `reason` added.

// MARK: - Audio Format Components

public enum BitDepth: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case int16   = "16-bit"
    case int24   = "24-bit"
    case float32 = "32-bit float"

    public var id: String { rawValue }

    public var bits: Int {
        switch self {
        case .int16:   return 16
        case .int24:   return 24
        case .float32: return 32
        }
    }

    public var isFloat: Bool { self == .float32 }
}

public enum ChannelMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case mono     = "Mono"
    case stereo   = "Stereo"
    case asSource = "As source"

    public var id: String { rawValue }

    public func resolvedChannelCount(sourceChannels: Int) -> Int {
        switch self {
        case .mono:     return 1
        case .stereo:   return 2
        case .asSource: return sourceChannels
        }
    }
}

public struct AudioFormat: Codable, Hashable, Sendable {
    public let sampleRate: Double
    public let bitDepth: BitDepth
    public let channels: ChannelMode

    /// PolyTracker writes every preset as WAV.
    public var container: String { "wav" }

    public func writeSettings(channelCount: Int) -> [String: Any] {
        [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             sampleRate,
            AVNumberOfChannelsKey:       channelCount,
            AVLinearPCMBitDepthKey:      bitDepth.bits,
            AVLinearPCMIsFloatKey:       bitDepth.isFloat,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

// MARK: - Chain Mode

public enum ChainMode: Codable, Hashable, Sendable {
    case none
    case morphageneReel
    case octatrackChain
    case evenGrid(sliceCount: Int)

    public var isChain: Bool { self != .none }

    public var displayName: String {
        switch self {
        case .none:                     return "Individual files"
        case .morphageneReel:           return "Morphagene Reel"
        case .octatrackChain:           return "Octatrack Chain"
        case .evenGrid(let n):          return "Even Grid (\(n) slices)"
        }
    }
}

// MARK: - Limits

/// Length and naming rules a device imposes, where PolyTracker defines them.
public struct PresetLimits: Hashable, Sendable {
    /// Longest file in seconds.
    public var maxSeconds: Double?
    /// Most files (or slices) per export.
    public var maxFiles: Int?
    /// File name pattern the device expects, with `{index}` counting from 1.
    public var namePattern: String?
    /// Why the limits exist, shown in the export sheet.
    public var note: String?

    public static let none = PresetLimits()
}

// MARK: - Export Preset

public struct ExportPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let icon: String?
    public let format: AudioFormat
    public let chainMode: ChainMode
    public let isBuiltIn: Bool

    public var isChainPreset: Bool { chainMode.isChain }

    public enum Category: String, CaseIterable, Sendable {
        case standard = "Standard"
        case hardware = "Hardware"
        case chain    = "Chain / Reel"
        case custom   = "Custom"
    }

    public var category: Category {
        if !isBuiltIn { return .custom }
        if chainMode.isChain { return .chain }
        switch id {
        case "digitakt", "sp404": return .hardware
        default:                  return .standard
        }
    }

    public var limits: PresetLimits {
        switch chainMode {
        case .morphageneReel:
            return PresetLimits(maxSeconds: 174, maxFiles: 9, namePattern: "mg{index}",
                                note: "Morphagene reels are at most 174 s and must be named mg1 to mg9 on the card.")
        case .octatrackChain:
            return PresetLimits(maxFiles: 64, note: "The Octatrack takes at most 64 slices per chain.")
        default:
            return .none
        }
    }

    /// Why the preset fixes the format, shown next to the locked fields.
    public var reason: String {
        let f = format
        let rate = f.sampleRate.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(f.sampleRate / 1000)) : String(f.sampleRate / 1000)
        let base = "\(name) expects WAV, \(rate) kHz, \(f.bitDepth.rawValue), \(f.channels.rawValue.lowercased())."
        return limits.note.map { "\(base) \($0)" } ?? base
    }
}

// MARK: - Built-in Presets

extension ExportPreset {
    public static let builtIn: [ExportPreset] = [
        // Standard
        ExportPreset(
            id: "wav_48_24",
            name: "48 kHz / 24-bit",
            icon: "waveform",
            format: AudioFormat(sampleRate: 48000, bitDepth: .int24, channels: .asSource),
            chainMode: .none,
            isBuiltIn: true
        ),
        ExportPreset(
            id: "wav_44_16",
            name: "44.1 kHz / 16-bit",
            icon: "waveform",
            format: AudioFormat(sampleRate: 44100, bitDepth: .int16, channels: .asSource),
            chainMode: .none,
            isBuiltIn: true
        ),
        ExportPreset(
            id: "wav_48_32f",
            name: "48 kHz / 32-bit float",
            icon: "waveform",
            format: AudioFormat(sampleRate: 48000, bitDepth: .float32, channels: .asSource),
            chainMode: .none,
            isBuiltIn: true
        ),

        // Hardware
        ExportPreset(
            id: "digitakt",
            name: "Digitakt",
            icon: "square.grid.3x3",
            format: AudioFormat(sampleRate: 48000, bitDepth: .int16, channels: .mono),
            chainMode: .none,
            isBuiltIn: true
        ),
        ExportPreset(
            id: "sp404",
            name: "SP-404",
            icon: "square.grid.3x3",
            format: AudioFormat(sampleRate: 44100, bitDepth: .int16, channels: .stereo),
            chainMode: .none,
            isBuiltIn: true
        ),

        // Chain / Reel
        ExportPreset(
            id: "morphagene",
            name: "Morphagene Reel",
            icon: "film",
            format: AudioFormat(sampleRate: 48000, bitDepth: .float32, channels: .stereo),
            chainMode: .morphageneReel,
            isBuiltIn: true
        ),
        ExportPreset(
            id: "octatrack",
            name: "Octatrack Chain",
            icon: "link",
            format: AudioFormat(sampleRate: 44100, bitDepth: .int16, channels: .asSource),
            chainMode: .octatrackChain,
            isBuiltIn: true
        ),
        ExportPreset(
            id: "octatrack_24",
            name: "Octatrack Chain (24-bit)",
            icon: "link",
            format: AudioFormat(sampleRate: 44100, bitDepth: .int24, channels: .asSource),
            chainMode: .octatrackChain,
            isBuiltIn: true
        ),
    ]

    public static let defaultPreset = builtIn.first { $0.id == "wav_48_24" }!

    public static func preset(for id: String) -> ExportPreset? {
        builtIn.first { $0.id == id }
    }
}
