import AVFoundation
import Foundation

/// Converts a whole file to float32 CAF at another rate with `AVAudioConverter` at highest quality.
public enum Resampler {
    public static func convert(_ input: URL, to output: URL, sampleRate: Double,
                               isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        let inFile = try AVAudioFile(forReading: input)
        let inFormat = inFile.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: inFormat.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TapeError.unreadable(input, "No converter for \(inFormat) to \(sampleRate) Hz")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        try? FileManager.default.removeItem(at: output)
        let partial = output.deletingPathExtension().appendingPathExtension("partial.caf")
        try? FileManager.default.removeItem(at: partial)
        try run(converter: converter, inFile: inFile, inFormat: inFormat, outFormat: outFormat,
                partial: partial, isCancelled: isCancelled)
        try FileManager.default.moveItem(at: partial, to: output)
    }

    /// Separate scope so the output file is closed before the rename.
    private static func run(converter: AVAudioConverter, inFile: AVAudioFile, inFormat: AVAudioFormat,
                            outFormat: AVAudioFormat, partial: URL,
                            isCancelled: @Sendable () -> Bool) throws {
        let outFile = try AVAudioFile(forWriting: partial, settings: outFormat.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        let capacity: AVAudioFrameCount = 65536
        let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)!
        let input = ConverterInput(file: inFile, buffer: AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: capacity)!)
        while true {
            if isCancelled() { throw TapeError.cancelled }
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { want, outStatus in
                input.next(want: want, status: outStatus)
            }
            if let error { throw error }
            if outBuffer.frameLength > 0 { try outFile.write(from: outBuffer) }
            if status == .endOfStream || status == .error { break }
        }
    }
}

/// Feeds an `AVAudioConverter` from a file. The converter calls it synchronously on the calling thread.
final class ConverterInput: @unchecked Sendable {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    private var done = false

    init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.file = file
        self.buffer = buffer
    }

    func next(want: AVAudioFrameCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if done {
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: buffer, frameCount: min(want, buffer.frameCapacity))
        } catch {
            buffer.frameLength = 0
        }
        if buffer.frameLength == 0 {
            done = true
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}
