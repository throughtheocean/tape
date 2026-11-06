import AVFoundation
import Combine
import Foundation
import TapeCore

enum ProcessKind: String, CaseIterable, Identifiable {
    case normalize, gain, removeDC, trimSilence, reverse, compressor, limiter, resample
    var id: String { rawValue }

    var title: String {
        switch self {
        case .normalize: return "Normalize"
        case .gain: return "Gain"
        case .removeDC: return "Remove DC Offset"
        case .trimSilence: return "Trim Silence"
        case .reverse: return "Reverse"
        case .compressor: return "Compressor"
        case .limiter: return "Limiter"
        case .resample: return "Resample"
        }
    }

    var isAudioUnit: Bool { self == .compressor || self == .limiter }
    var canPreview: Bool { self != .resample }
}

/// Parameters of every process, edited in the sheet.
struct ProcessParameters: Equatable {
    var loudnessMode = true
    var peakTarget = -1.0
    var lufsTarget = -14.0
    var truePeakCeiling = -1.0
    var gainDB = 0.0
    var silenceThreshold = -60.0
    var silenceHoldMs = 10.0
    var compThreshold = -20.0
    var compHeadroom = 5.0
    var compAttackMs = 1.0
    var compReleaseMs = 50.0
    var compMasterGain = 0.0
    var limAttackMs = 12.0
    var limDecayMs = 24.0
    var limPreGain = 0.0
    var resampleRate = 48000.0
}

/// One region a process touches: the source frames to process and whether the edges crossfade.
struct ProcessTarget: Sendable {
    var region: Region
    /// Source frames (session rate) to process.
    var sourceRange: SampleRange
    /// Timeline frames covered.
    var span: SampleRange
    /// True when only part of the region is processed.
    var partial: Bool
}

/// A process sheet's state: targets, parameters, live preview and apply.
@MainActor
final class ProcessSession: ObservableObject {
    let kind: ProcessKind
    let editor: EditorController
    @Published private(set) var targets: [ProcessTarget]
    /// Set when a range is processed: normalize measures the whole range as one.
    let range: SampleRange?
    /// On a range: every track's regions in it instead of the selected track's.
    @Published var allTracks: Bool {
        didSet {
            guard allTracks != oldValue else { return }
            let wasPreviewing = previewing
            setPreview(false)
            targets = Self.targets(editor, allTracks: allTracks).0
            if wasPreviewing, !targets.isEmpty { setPreview(true) }
        }
    }
    @Published var parameters = ProcessParameters() {
        didSet { if parameters != oldValue { parametersChanged() } }
    }
    @Published private(set) var previewing = false
    @Published private(set) var status = ""
    @Published private(set) var isApplying = false
    private var previewUnit: AVAudioUnitEffect?
    private var previewTask: Task<Void, Never>?
    private let previewDebounce = Debouncer(delay: 0.12)
    private let cancelFlag = AtomicInt64(0)

    init(kind: ProcessKind, editor: EditorController) {
        self.kind = kind
        self.editor = editor
        let own = Self.targets(editor, allTracks: false)
        // The selected track has nothing in the range: start with every track so the sheet has something to do.
        let all = own.1 != nil && own.0.isEmpty
        allTracks = all
        (targets, range) = all ? Self.targets(editor, allTracks: true) : own
        if kind == .resample { parameters.resampleRate = editor.sessionRate }
    }

    var targetSummary: String {
        let regions = targets.count == 1 ? "1 region" : "\(targets.count) regions"
        if let range {
            let scope = allTracks ? "" : " on \(editor.selectedTrack.name)"
            return "\(regions)\(scope) inside the range (\(editor.lengthText(range.length)))"
        }
        return regions
    }

    /// The selected track's regions in the range (every track's with `allTracks`) when a range is set, else the
    /// selected regions.
    static func targets(_ editor: EditorController, allTracks: Bool) -> ([ProcessTarget], SampleRange?) {
        let project = editor.project
        if let range = editor.range, !range.isEmpty {
            let hits = project.regions.filter {
                $0.position < range.end && $0.end > range.start && (allTracks || $0.trackId == editor.selectedTrackID)
            }
            let t = hits.map { r -> ProcessTarget in
                let span = r.timelineRange.clamped(to: range)
                let start = r.sourceIn + (span.start - r.position)
                return ProcessTarget(region: r, sourceRange: SampleRange(start: start, end: start + span.length), span: span,
                                     partial: span != r.timelineRange)
            }
            return (t, range)
        }
        let t = editor.selectedRegions.map {
            ProcessTarget(region: $0, sourceRange: SampleRange(start: $0.sourceIn, end: $0.sourceOut), span: $0.timelineRange, partial: false)
        }
        return (t, nil)
    }

    static func canProcess(_ editor: EditorController) -> Bool {
        let t = targets(editor, allTracks: true).0
        return !t.isEmpty && t.allSatisfy { editor.document.loaded[$0.region.sourceId] != nil }
    }

    // MARK: Processes

    private var auProcess: AUProcess? {
        let p = parameters
        switch kind {
        case .compressor:
            return Dynamics.compressor(threshold: p.compThreshold, headroom: p.compHeadroom, attack: p.compAttackMs / 1000,
                                       release: p.compReleaseMs / 1000, masterGain: p.compMasterGain)
        case .limiter:
            return Dynamics.limiter(attack: p.limAttackMs / 1000, decay: p.limDecayMs / 1000, preGain: p.limPreGain)
        default:
            return nil
        }
    }

    /// One process per target. Normalize becomes a gain measured on what the target plays (region gain and fades
    /// included), over the whole range when a range is set, else per region.
    nonisolated static func processes(kind: ProcessKind, parameters p: ProcessParameters, targets: [ProcessTarget],
                                      range: SampleRange?, list: EditList, sessionRate: Double) -> [AudioProcess] {
        func measured(_ span: SampleRange, regions: [Region]) -> Double {
            let only = EditList(regions: regions, sources: list.sources, channelCount: list.channelCount)
            let out = SampleBuffer(channelCount: list.channelCount, capacity: Int(span.length))
            EditListRenderer().render(only, start: span.start, frames: Int(span.length), into: out)
            let buffer = AudioBuffer(channels: out.toArrays(count: Int(span.length)), sampleRate: sessionRate)
            let mode: Normalize.Mode = p.loudnessMode ? .loudness(targetLUFS: p.lufsTarget, ceilingDBTP: p.truePeakCeiling)
                : .peak(targetDB: p.peakTarget)
            return Normalize(mode: mode).gainDB(for: buffer, range: buffer.all)
        }
        switch kind {
        case .normalize:
            if let range {
                let gain = measured(range, regions: targets.map(\.region))
                return targets.map { _ in Gain(dB: gain) }
            }
            return targets.map { Gain(dB: measured($0.span, regions: [$0.region])) }
        case .gain: return targets.map { _ in Gain(dB: p.gainDB) }
        case .removeDC: return targets.map { _ in RemoveDC() }
        case .trimSilence: return targets.map { _ in TrimSilence(thresholdDB: p.silenceThreshold, holdMs: p.silenceHoldMs) }
        case .reverse: return targets.map { _ in Reverse() }
        case .resample: return targets.map { _ in Resample(sampleRate: p.resampleRate) }
        case .compressor, .limiter: return []
        }
    }

    private func currentProcesses(list: EditList) -> [AudioProcess] {
        if let au = auProcess { return targets.map { _ in au } }
        return Self.processes(kind: kind, parameters: parameters, targets: targets, range: range, list: list,
                              sessionRate: editor.sessionRate)
    }

    // MARK: Preview

    func setPreview(_ on: Bool) {
        guard on != previewing, kind.canPreview else { return }
        previewing = on
        if on {
            startPreview()
        } else {
            stopPreview()
        }
    }

    private var previewSpan: SampleRange {
        SampleRange(start: targets.map(\.span.start).min() ?? 0, end: targets.map(\.span.end).max() ?? 0)
    }

    private func startPreview() {
        if let au = auProcess {
            let unit = au.makeUnit()
            previewUnit = unit
            do {
                try editor.playback.setInsert(unit)
            } catch {
                status = "Preview failed: \(error.localizedDescription)"
            }
            editor.previewPlay(previewSpan)
        } else {
            rebuildPreview(play: true)
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        try? editor.playback.setInsert(nil)
        previewUnit = nil
        editor.endPreview()
    }

    private func parametersChanged() {
        guard previewing else { return }
        if let unit = previewUnit, let au = auProcess {
            au.apply(to: unit)
        } else {
            previewDebounce.schedule { [weak self] in self?.rebuildPreview(play: false) }
        }
    }

    /// Renders each target region with the process into memory and plays an edit list that uses those copies.
    private func rebuildPreview(play: Bool) {
        previewTask?.cancel()
        let list = editor.playbackList()
        let kind = kind, parameters = parameters, targets = targets, range = range, rate = editor.sessionRate
        let project = editor.project
        status = "Rendering preview"
        previewTask = Task.detached(priority: .userInitiated) { [self] in
            let processes = Self.processes(kind: kind, parameters: parameters, targets: targets, range: range, list: list, sessionRate: rate)
            var sources = list.sources
            var replaced: [UUID: Region] = [:]
            for (target, process) in zip(targets, processes) {
                if Task.isCancelled { return }
                let r = target.region
                guard let source = list.sources[r.sourceId] else { continue }
                let whole = SampleRange(start: r.sourceIn, end: r.sourceOut)
                let original = ProcessApplier.read(source, range: whole, sampleRate: rate)
                let local = SampleRange(start: target.sourceRange.start - r.sourceIn, end: target.sourceRange.end - r.sourceIn)
                guard var processed = try? process.render(input: original, range: local) else { continue }
                if target.partial {
                    ProcessCrossfade.apply(original: original, processed: &processed, range: local,
                                           frames: Int(ProcessApplier.crossfadeSeconds * rate))
                }
                let id = UUID()
                sources[id] = MemorySource(samples: processed.channels)
                var copy = r
                copy.sourceId = id
                copy.sourceOut = Int64(processed.frameCount)
                copy.sourceIn = 0
                replaced[r.id] = copy
            }
            let regions = project.regions.compactMap { replaced[$0.id] ?? (list.sources[$0.sourceId] != nil ? $0 : nil) }
            let preview = list.with(regions: regions, sources: sources)
            await MainActor.run {
                guard self.previewing, !Task.isCancelled else { return }
                self.editor.playback.setEditList(preview)
                self.status = ""
                if play { self.editor.previewPlay(self.previewSpan) }
            }
        }
    }

    // MARK: Apply

    func cancel() {
        if isApplying {
            cancelFlag.store(1)
        } else {
            setPreview(false)
        }
    }

    /// Renders a new source per target into `sources/`, loads it, then repoints the regions in one undo step.
    /// Trim Silence only trims region ends; nothing is rendered.
    func apply(completion: @escaping @MainActor (Bool) -> Void) {
        setPreview(false)
        let doc = editor.document
        let list = doc.editList()
        let rate = editor.sessionRate
        let package = doc.package
        let processes = currentProcesses(list: list)
        let targets = targets
        let stamp = DateFormatter.recordingStamp.string(from: Date())
        let files = targets.map { doc.newSourceFile(base: "\($0.region.name) \(kind.title) \(stamp)") }
        cancelFlag.store(0)
        let cancelled = cancelFlag
        isApplying = true
        status = "Rendering"
        let progress: @Sendable (Int) -> Void = { [self] i in
            Task { @MainActor in self.status = "Rendering \(i + 1) of \(targets.count)" }
        }
        Task { [self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try Self.render(targets: targets, processes: processes, files: files, list: list, rate: rate,
                                    package: package, cancelled: cancelled, progress: progress)
                }
            }.value
            isApplying = false
            switch outcome {
            case let .success(results):
                commit(results)
                completion(true)
            case let .failure(error):
                for f in files { try? FileManager.default.removeItem(at: f.url) }
                if case TapeError.cancelled = error { status = "Cancelled" } else { status = error.localizedDescription }
                completion(false)
            }
        }
    }

    struct ApplyResult: Sendable {
        var regionID: UUID
        /// The new source, or nil for Trim Silence.
        var loaded: LoadedSource?
        /// Trim Silence: the part of the region to keep, relative to its start.
        var keep: SampleRange?
    }

    nonisolated private static func render(targets: [ProcessTarget], processes: [AudioProcess], files: [(name: String, url: URL)],
                                           list: EditList, rate: Double, package: TapePackage, cancelled: AtomicInt64,
                                           progress: @Sendable (Int) -> Void) throws -> [ApplyResult] {
        try package.ensureDirectories()
        var results: [ApplyResult] = []
        for (i, (target, process)) in zip(targets, processes).enumerated() {
            if cancelled.load() != 0 { throw TapeError.cancelled }
            progress(i)
            let r = target.region
            guard let source = list.sources[r.sourceId] else { continue }
            if let trim = process as? TrimSilence {
                let buffer = ProcessApplier.read(source, range: SampleRange(start: r.sourceIn, end: r.sourceOut), sampleRate: rate)
                results.append(ApplyResult(regionID: r.id, loaded: nil, keep: trim.bounds(buffer, range: buffer.all)))
                continue
            }
            let file = files[i]
            let written = try ProcessApplier.render(source: source, sampleRate: rate, process: process, range: target.sourceRange,
                                                    crossfade: target.partial, to: file.url, isCancelled: { cancelled.load() != 0 })
            let ref = SourceRef(name: file.name, location: .package(fileName: file.name), sampleRate: written.sampleRate,
                                channelCount: source.channelCount, frameCount: written.frames)
            let loaded = try SourceLoader.load(ref, in: package, sessionRate: rate, isCancelled: { cancelled.load() != 0 })
            results.append(ApplyResult(regionID: r.id, loaded: loaded, keep: nil))
        }
        return results
    }

    private func commit(_ results: [ApplyResult]) {
        let doc = editor.document
        for case let loaded? in results.map(\.loaded) { doc.adopt(loaded) }
        doc.apply(kind.title) { p in
            for result in results {
                let regionID = result.regionID, loaded = result.loaded, keep = result.keep
                guard let i = p.regions.firstIndex(where: { $0.id == regionID }) else { continue }
                if let loaded {
                    if !p.sources.contains(where: { $0.id == loaded.ref.id }) { p.sources.append(loaded.ref) }
                    p.regions[i].sourceId = loaded.ref.id
                } else if let keep, !keep.isEmpty {
                    let r = p.regions[i]
                    EditOperations.trimEnd(&p, id: regionID, to: r.position + keep.end, sourceLength: r.sourceOut)
                    EditOperations.trimStart(&p, id: regionID, to: r.position + keep.start)
                }
            }
        }
    }
}
