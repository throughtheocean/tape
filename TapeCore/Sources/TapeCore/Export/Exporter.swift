import AVFoundation
import Foundation

/// How the session channels map to output files.
public enum ChannelLayout: String, Codable, CaseIterable, Sendable {
    case session, mono, stereo, split

    public var displayName: String {
        switch self {
        case .session: return "As session"
        case .mono: return "Mono"
        case .stereo: return "Stereo"
        case .split: return "Split to files"
        }
    }

    /// Output files and, per file, the channel count.
    public func fileChannels(session n: Int) -> [Int] {
        switch self {
        case .session: return [n]
        case .mono: return [1]
        case .stereo: return [2]
        case .split: return Array(repeating: 1, count: n)
        }
    }

    /// Suffixes for split files: L and R for stereo, else the channel number.
    public static func splitSuffixes(_ n: Int) -> [String] {
        n == 2 ? ["L", "R"] : (1...max(n, 1)).map(String.init)
    }

    /// Mixes `frames` frames of the session channels into the file channels.
    /// Mono averages all channels. Stereo duplicates a mono session and takes the first two otherwise.
    func map(_ input: [UnsafePointer<Float>], frames: Int, into files: [[UnsafeMutablePointer<Float>]]) {
        let n = input.count
        switch self {
        case .session:
            for c in 0..<n { files[0][c].update(from: input[c], count: frames) }
        case .mono:
            let out = files[0][0]
            out.update(from: input[0], count: frames)
            if n > 1 {
                for c in 1..<n { for i in 0..<frames { out[i] += input[c][i] } }
                let scale = 1 / Float(n)
                for i in 0..<frames { out[i] *= scale }
            }
        case .stereo:
            files[0][0].update(from: input[0], count: frames)
            files[0][1].update(from: input[min(1, n - 1)], count: frames)
        case .split:
            for c in 0..<n { files[c][0].update(from: input[c], count: frames) }
        }
    }
}

public struct ExportSettings: Codable, Equatable, Hashable, Sendable {
    public var container: AudioContainer
    public var sampleFormat: SampleFormat
    public var sampleRate: Double
    public var layout: ChannelLayout
    /// AAC only, bits per second.
    public var bitRate: Int
    /// TPDF dither when the output is 16 bit.
    public var dither: Bool

    public static let rates: [Double] = [44100, 48000, 88200, 96000, 176_400, 192_000]
    public static let aacBitRates = [128_000, 192_000, 256_000, 320_000]

    public init(container: AudioContainer = .wav, sampleFormat: SampleFormat = .int24, sampleRate: Double = 48000,
                layout: ChannelLayout = .session, bitRate: Int = 256_000, dither: Bool = true) {
        self.container = container
        self.sampleFormat = container.sampleFormats.contains(sampleFormat) ? sampleFormat : container.sampleFormats.last!
        self.sampleRate = sampleRate
        self.layout = layout
        self.bitRate = bitRate
        self.dither = dither
    }

    public var fileExtension: String { container.fileExtension(sampleFormat) }

    public func fileFormat(channels: Int) -> AudioFileFormat {
        AudioFileFormat(container: container, sampleFormat: sampleFormat, sampleRate: sampleRate, channelCount: channels, bitRate: bitRate)
    }

    /// Integer output is rounded to its grid before the file sees it, so every container stores the same values.
    /// Dither applies at 16 bit. AAC takes float.
    var quantizer: Quantizer? {
        guard container != .aac else { return nil }
        switch sampleFormat {
        case .int16: return Quantizer(bits: 16, dither: dither)
        case .int24: return Quantizer(bits: 24, dither: false)
        case .float32: return nil
        }
    }
}

/// What to export.
public enum ExportScope: Equatable, Sendable {
    /// The whole document through the master.
    case mix
    case range(SampleRange)
    /// The selected regions alone, as one file over their span.
    case selection([UUID])
    /// Each region alone, as its own file, in timeline order.
    case eachRegion([UUID])
    /// One file per track, post track gain and pan, before the master; mute respected (no file), solo ignored.
    /// Every stem spans the whole document from frame 0.
    case stems([UUID])
}

/// One output file (or one set of split files): an edit list and the timeline span to render.
public struct ExportJob: Sendable {
    public var list: EditList
    public var span: SampleRange
    /// For split layouts the channel suffix is added before the extension.
    public var url: URL

    public init(list: EditList, span: SampleRange, url: URL) {
        self.list = list
        self.span = span
        self.url = url
    }

    /// Every file this job writes.
    public func urls(_ settings: ExportSettings) -> [URL] {
        guard settings.layout == .split else { return [url] }
        let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent
        return ChannelLayout.splitSuffixes(list.channelCount).map {
            dir.appendingPathComponent("\(base)-\($0)").appendingPathExtension(url.pathExtension)
        }
    }
}

public enum Exporter {
    public static let defaultPattern = "{name}-{index:02}"
    public static let defaultStemPattern = "{name}-{track}"

    // MARK: Naming

    /// Expands `{name}`, `{region}`, `{track}`, `{date}`, `{index}` and `{index:NN}` (zero padded to NN digits).
    /// Unknown tokens stay as typed. Slashes and colons become dashes.
    public static func fileName(pattern: String, name: String, index: Int, region: String, track: String = "", date: Date) -> String {
        var out = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let token = rest[rest.index(after: open)..<close]
            out += expand(token, name: name, index: index, region: region, track: track, date: date) ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        let clean = out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return clean.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : clean
    }

    private static func expand(_ token: Substring, name: String, index: Int, region: String, track: String, date: Date) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1)
        switch parts.first.map(String.init) {
        case "name": return name
        case "region": return region
        case "track": return track
        case "date":
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyMMdd"
            return f.string(from: date)
        case "index":
            let width = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let digits = String(index)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        default: return nil
        }
    }

    // MARK: Jobs

    /// The files a scope produces. `fileName` names single-file scopes; `eachRegion` and `stems` use `pattern`.
    /// `trackNames` fills `{track}`; `{index}` counts from `startIndex`. Duplicate names get " 2", " 3" appended.
    /// Selections and single regions keep their track's gain and pan and the master, but play even when muted.
    public static func jobs(list: EditList, scope: ExportScope, directory: URL, fileName: String, pattern: String,
                            documentName: String, date: Date, settings: ExportSettings,
                            trackNames: [UUID: String] = [:], startIndex: Int = 1) -> [ExportJob] {
        let list = list.isolating(nil)
        let ext = settings.fileExtension
        func url(_ base: String) -> URL {
            let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            return directory.appendingPathComponent(clean).appendingPathExtension(ext)
        }
        func only(_ ids: [UUID]) -> [Region] {
            let set = Set(ids)
            return list.regions.filter { set.contains($0.id) }.sorted { $0.position < $1.position }
        }
        func sub(_ regions: [Region]) -> EditList {
            var l = list.with(regions: regions)
            for i in l.tracks.indices {
                l.tracks[i].mute = false
                l.tracks[i].solo = false
            }
            return l
        }
        var used = Set<String>()
        func unique(_ base: String) -> String {
            var name = base
            var n = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(n)"
                n += 1
            }
            used.insert(name.lowercased())
            return name
        }
        switch scope {
        case .mix:
            return [ExportJob(list: list, span: SampleRange(start: 0, end: list.length), url: url(fileName))]
        case let .range(r):
            return [ExportJob(list: list, span: r, url: url(fileName))]
        case let .selection(ids):
            let regions = only(ids)
            guard let start = regions.map(\.position).min(), let end = regions.map(\.end).max() else { return [] }
            return [ExportJob(list: sub(regions), span: SampleRange(start: start, end: end), url: url(fileName))]
        case let .eachRegion(ids):
            return only(ids).enumerated().map { i, r in
                let base = Self.fileName(pattern: pattern, name: documentName, index: startIndex + i, region: r.name,
                                         track: trackNames[r.trackId] ?? "", date: date)
                return ExportJob(list: sub([r]), span: r.timelineRange, url: url(unique(base)))
            }
        case let .stems(ids):
            let span = SampleRange(start: 0, end: list.length)
            let wanted = Set(ids)
            return list.tracks.filter { wanted.contains($0.id) && !$0.mute }.enumerated().map { i, t in
                let base = Self.fileName(pattern: pattern, name: documentName, index: startIndex + i, region: "",
                                         track: trackNames[t.id] ?? "", date: date)
                return ExportJob(list: list.stem(t.id), span: span, url: url(unique(base)))
            }
        }
    }

    // MARK: Render

    /// Output frames for `frames` session frames at the export rate.
    public static func outputFrames(_ frames: Int64, sessionRate: Double, settings: ExportSettings) -> Int64 {
        settings.sampleRate == sessionRate ? frames : Int64((Double(frames) * settings.sampleRate / sessionRate).rounded())
    }

    /// Renders every job through a playback engine in manual rendering mode (the same path as playback) and
    /// writes the files. `progress` gets the fraction done, 0 to 1. Files are written under a temporary name and
    /// moved into place when complete; on error or cancel nothing is left behind. Returns the written files.
    @discardableResult
    public static func export(_ jobs: [ExportJob], sessionRate: Double, settings: ExportSettings,
                              progress: @escaping @Sendable (Double) -> Void = { _ in },
                              isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [URL] {
        let total = max(1, jobs.reduce(Int64(0)) { $0 + $1.span.length })
        var done: Int64 = 0
        var written: [URL] = []
        do {
            for job in jobs {
                let base = done
                written += try export(job, sessionRate: sessionRate, settings: settings, isCancelled: isCancelled) { frames in
                    progress(Double(base + frames) / Double(total))
                }
                done += job.span.length
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        progress(1)
        return written
    }

    static func export(_ job: ExportJob, sessionRate: Double, settings: ExportSettings,
                       isCancelled: @escaping @Sendable () -> Bool, progress: @escaping (Int64) -> Void) throws -> [URL] {
        let channels = max(1, job.list.channelCount)
        let engine = PlaybackEngine()
        try engine.configure(sessionRate: sessionRate, channelCount: channels, manualRendering: true)
        defer { engine.shutdown() }
        engine.setEditList(job.list)
        engine.play(from: job.span.start)

        let finals = job.urls(settings)
        let temps = finals.map { $0.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\($0.lastPathComponent)") }
        let fileChannels = settings.layout.fileChannels(session: channels)
        do {
            // AVAudioFile finishes the header when it is released, which must happen before the move.
            try autoreleasepool {
                try write(engine: engine, frames: job.span.length, channels: channels, sessionRate: sessionRate,
                          settings: settings, fileChannels: fileChannels, to: temps, isCancelled: isCancelled, progress: progress)
            }
            for (temp, final) in zip(temps, finals) {
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: temp, to: final)
            }
        } catch {
            for t in temps { try? FileManager.default.removeItem(at: t) }
            throw error
        }
        return finals
    }

    /// Separate scope so the files are closed before they are moved.
    private static func write(engine: PlaybackEngine, frames: Int64, channels: Int, sessionRate: Double, settings: ExportSettings,
                              fileChannels: [Int], to urls: [URL], isCancelled: @escaping @Sendable () -> Bool,
                              progress: @escaping (Int64) -> Void) throws {
        let files = try zip(urls, fileChannels).map { url, n in try settings.fileFormat(channels: n).createFile(at: url) }
        let block = 8192
        let fileBuffers = files.map { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: AVAudioFrameCount(block))! }
        var quantizer = settings.quantizer
        let expected = outputFrames(frames, sessionRate: sessionRate, settings: settings)
        var out: Int64 = 0

        let feed = EngineFeed(engine: engine, frames: frames, isCancelled: isCancelled, progress: progress)

        func emit(_ buffer: AVAudioPCMBuffer, count: Int) throws {
            var offset = 0
            while offset < count {
                let n = min(block, count - offset, Int(expected - out))
                guard n > 0 else { return }
                let input = (0..<channels).map { UnsafePointer(buffer.floatChannelData![$0] + offset) }
                let targets = fileBuffers.map { b in (0..<Int(b.format.channelCount)).map { b.floatChannelData![$0] } }
                settings.layout.map(input, frames: n, into: targets)
                for (file, b) in zip(files, fileBuffers) {
                    b.frameLength = AVAudioFrameCount(n)
                    if quantizer != nil {
                        for c in 0..<Int(b.format.channelCount) { quantizer!.apply(b.floatChannelData![c], count: n) }
                    }
                    try file.write(from: b)
                }
                offset += n
                out += Int64(n)
            }
        }

        if settings.sampleRate == sessionRate {
            while let b = try feed.pull() { try emit(b, count: Int(b.frameLength)) }
        } else {
            let inFormat = AVAudioFormat.deinterleavedFloat(sampleRate: sessionRate, channels: channels)
            let outFormat = AVAudioFormat.deinterleavedFloat(sampleRate: settings.sampleRate, channels: channels)
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw TapeError.failed("No converter from \(sessionRate) Hz to \(settings.sampleRate) Hz")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            let converted = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(block))!
            while true {
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, inputStatus in feed.next(inputStatus) }
                if let failure = feed.failure { throw failure }
                if let error { throw error }
                try emit(converted, count: Int(converted.frameLength))
                if status == .endOfStream || status == .error || converted.frameLength == 0 { break }
            }
        }
        // The converter can end a few frames short of the exact ratio; pad with silence.
        if out < expected {
            let silence = AVAudioPCMBuffer(pcmFormat: AVAudioFormat.deinterleavedFloat(sampleRate: settings.sampleRate, channels: channels),
                                           frameCapacity: AVAudioFrameCount(block))!
            while out < expected {
                let n = Int(min(Int64(block), expected - out))
                for c in 0..<channels { silence.floatChannelData![c].update(repeating: 0, count: n) }
                silence.frameLength = AVAudioFrameCount(n)
                try emit(silence, count: n)
            }
        }
    }
}

/// Session rate blocks from a manual rendering engine, `frames` in total, for a loop or an `AVAudioConverter`.
/// The converter calls `next` synchronously on the exporting thread.
final class EngineFeed: @unchecked Sendable {
    private let engine: PlaybackEngine
    private let buffer: AVAudioPCMBuffer
    private let frames: Int64
    private let isCancelled: () -> Bool
    private let progress: (Int64) -> Void
    private var pulled: Int64 = 0
    private var ended = false
    private(set) var failure: Error?

    init(engine: PlaybackEngine, frames: Int64, isCancelled: @escaping () -> Bool, progress: @escaping (Int64) -> Void) {
        self.engine = engine
        self.buffer = engine.makeManualBuffer()
        self.frames = frames
        self.isCancelled = isCancelled
        self.progress = progress
    }

    func pull() throws -> AVAudioPCMBuffer? {
        guard pulled < frames else { return nil }
        if isCancelled() { throw TapeError.cancelled }
        let n = Int(min(Int64(PlaybackEngine.manualBlock), frames - pulled))
        try engine.renderManual(frames: n, into: buffer)
        pulled += Int64(n)
        progress(pulled)
        return buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if !ended {
            do {
                if let b = try pull() {
                    status.pointee = .haveData
                    return b
                }
            } catch {
                failure = error
            }
            ended = true
        }
        status.pointee = .endOfStream
        return nil
    }
}

/// Rounds to an integer grid, optionally with triangular (TPDF) dither of plus or minus one LSB, so the file's own
/// float to integer conversion is exact.
struct Quantizer {
    private let scale: Float
    private let dither: Bool
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(bits: Int, dither: Bool) {
        scale = Float(1 << (bits - 1))
        self.dither = dither
    }

    private mutating func uniform() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state >> 40) / Float(1 << 24)
    }

    mutating func apply(_ data: UnsafeMutablePointer<Float>, count: Int) {
        let lo = -scale, hi = scale - 1
        for i in 0..<count {
            let v = (data[i] * scale + (dither ? uniform() - uniform() : 0)).rounded()
            data[i] = min(max(v, lo), hi) / scale
        }
    }
}
