import AVFoundation
import Foundation

public enum AudioContainer: String, Codable, CaseIterable, Sendable {
    case wav, aiff, caf, flac, alac, aac

    public var displayName: String {
        switch self {
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .caf: return "CAF"
        case .flac: return "FLAC"
        case .alac: return "ALAC"
        case .aac: return "AAC"
        }
    }

    /// Containers the recorder writes.
    public static let recordable: [AudioContainer] = [.wav, .aiff, .caf, .flac]

    public var isLossy: Bool { self == .aac }

    public var sampleFormats: [SampleFormat] {
        switch self {
        case .wav, .aiff, .caf: return [.int16, .int24, .float32]
        case .flac, .alac: return [.int16, .int24]
        case .aac: return [.float32]
        }
    }

    public func fileExtension(_ format: SampleFormat) -> String {
        switch self {
        case .wav: return "wav"
        // Core Audio writes float AIFF only as AIFF-C.
        case .aiff: return format == .float32 ? "aifc" : "aif"
        case .caf: return "caf"
        case .flac: return "flac"
        case .alac, .aac: return "m4a"
        }
    }
}

public enum SampleFormat: String, Codable, CaseIterable, Sendable {
    case int16, int24, float32

    public var bits: Int {
        switch self {
        case .int16: return 16
        case .int24: return 24
        case .float32: return 32
        }
    }

    public var isFloat: Bool { self == .float32 }

    public var displayName: String {
        switch self {
        case .int16: return "16 bit"
        case .int24: return "24 bit"
        case .float32: return "32 bit float"
        }
    }
}

extension AVAudioFormat {
    /// Deinterleaved float32 for any channel count; above two channels the layout is discrete in order.
    public static func deinterleavedFloat(sampleRate: Double, channels: Int) -> AVAudioFormat {
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                 channels: AVAudioChannelCount(max(channels, 1)), interleaved: false)!
        }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }
}

/// Container, sample format, rate and channel count of a file to write.
public struct AudioFileFormat: Codable, Equatable, Hashable, Sendable {
    public var container: AudioContainer
    public var sampleFormat: SampleFormat
    public var sampleRate: Double
    public var channelCount: Int
    /// AAC only, bits per second.
    public var bitRate: Int

    public init(container: AudioContainer, sampleFormat: SampleFormat, sampleRate: Double, channelCount: Int, bitRate: Int = 256_000) {
        self.container = container
        self.sampleFormat = container.sampleFormats.contains(sampleFormat) ? sampleFormat : container.sampleFormats.last!
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
    }

    public var fileExtension: String { container.fileExtension(sampleFormat) }

    public var settings: [String: Any] {
        var s: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channelCount]
        switch container {
        case .wav, .aiff, .caf:
            s[AVFormatIDKey] = kAudioFormatLinearPCM
            s[AVLinearPCMBitDepthKey] = sampleFormat.bits
            s[AVLinearPCMIsFloatKey] = sampleFormat.isFloat
            s[AVLinearPCMIsBigEndianKey] = container == .aiff
            s[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            s[AVFormatIDKey] = kAudioFormatFLAC
            s[AVEncoderBitDepthHintKey] = sampleFormat.bits
        case .alac:
            s[AVFormatIDKey] = kAudioFormatAppleLossless
            s[AVEncoderBitDepthHintKey] = sampleFormat.bits
        case .aac:
            s[AVFormatIDKey] = kAudioFormatMPEG4AAC
            s[AVEncoderBitRateKey] = bitRate
        }
        return s
    }

    /// Opens a file for writing; the processing format is deinterleaved float32.
    public func createFile(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}
