import AVFoundation
import Foundation
@testable import TapeCore

enum TestAudio {
    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TapeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes deinterleaved float samples to a file whose container follows the extension.
    static func write(_ channels: [[Float]], sampleRate: Double, to url: URL, bitDepth: Int = 32) throws {
        let isFloat = bitDepth == 32
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: url.pathExtension.lowercased().hasPrefix("aif"),
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let total = channels.first?.count ?? 0
        let chunk = 1 << 18
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
        var pos = 0
        while pos < total {
            let n = min(chunk, total - pos)
            for c in 0..<channels.count {
                channels[c].withUnsafeBufferPointer { src in
                    buffer.floatChannelData![c].update(from: src.baseAddress! + pos, count: n)
                }
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            pos += n
        }
    }

    static func read(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.readFully(into: buffer, frameCount: AVAudioFrameCount(file.length))
        return (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
        }
    }
}
