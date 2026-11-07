import AppKit
import Combine
import HardwarePresets
import TapeCore

enum ExportScopeKind: String, CaseIterable, Identifiable {
    case mix, range, selection, eachRegion, stems
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mix: return "Mix"
        case .range: return "Range"
        case .selection: return "Selected regions as one file"
        case .eachRegion: return "Each region as its own file, numbered"
        case .stems: return "Stems, one file per track"
        }
    }

    var writesFolder: Bool { self == .eachRegion || self == .stems }
}

/// State of the export sheet: format, scope, naming, hardware preset, and the running export.
@MainActor
final class ExportSession: ObservableObject {
    let editor: EditorController
    /// Export Region: only this region, as one file.
    let onlyRegion: UUID?

    @Published var settings: ExportSettings
    @Published var scope: ExportScopeKind
    @Published var pattern: String
    @Published var stemPattern: String
    /// First `{index}` number for Each Region. Stems always count from 1, by track position.
    @Published var startIndex: Int
    @Published private(set) var preset: ExportPreset?
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""

    private let cancelFlag = AtomicInt64(0)

    init(editor: EditorController, scope: ExportScopeKind? = nil, onlyRegion: UUID? = nil) {
        self.editor = editor
        self.onlyRegion = onlyRegion
        let s = AppSettings.shared
        settings = s.exportSettings
        pattern = s.exportPattern
        stemPattern = s.stemPattern
        startIndex = editor.exportStartIndex
        self.scope = .mix
        if let onlyRegion {
            self.scope = .selection
            editor.selection = [onlyRegion]
        } else if let scope, availableScopes.contains(scope) {
            self.scope = scope
        } else if editor.range != nil {
            self.scope = .range
        } else {
            self.scope = editor.selection.count > 1 ? .eachRegion : .mix
        }
        if let id = s.exportPresetID, let p = ExportPreset.preset(for: id) { applyPreset(p) }
    }

    var availableScopes: [ExportScopeKind] {
        if onlyRegion != nil { return [.selection] }
        var scopes: [ExportScopeKind] = [.mix]
        if editor.range != nil { scopes.append(.range) }
        if !editor.selection.isEmpty { scopes.append(.selection) }
        if !editor.project.regions.isEmpty { scopes.append(.eachRegion) }
        scopes.append(.stems)
        return scopes
    }

    var documentName: String {
        (editor.document.displayName as NSString).deletingPathExtension
    }

    /// Selected regions, or every region when nothing is selected (for Each Region).
    private var regionIDs: [UUID] {
        if let onlyRegion { return [onlyRegion] }
        let selected = editor.project.regions.filter { editor.selection.contains($0.id) }.map(\.id)
        return selected.isEmpty ? editor.project.regions.map(\.id) : selected
    }

    var coreScope: ExportScope {
        switch scope {
        case .mix: return .mix
        case .range: return .range(editor.range ?? SampleRange(start: 0, end: 0))
        case .selection: return .selection(regionIDs)
        case .eachRegion: return .eachRegion(regionIDs)
        case .stems: return .stems(editor.project.tracks.map(\.id))
        }
    }

    /// Name for single-file scopes: the region for Export Region, the preset's pattern, or the document.
    var defaultFileName: String {
        if let p = preset?.limits.namePattern {
            return Exporter.fileName(pattern: p, name: documentName, index: 1, region: "", date: Date())
        }
        if let onlyRegion, let r = editor.project.regions.first(where: { $0.id == onlyRegion }) { return r.name }
        return documentName
    }

    func jobs(directory: URL, fileName: String) -> [ExportJob] {
        let names = Dictionary(editor.project.tracks.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return Exporter.jobs(list: editor.document.editList(), scope: coreScope, directory: directory, fileName: fileName,
                             pattern: scope == .stems ? stemPattern : pattern, documentName: documentName, date: Date(),
                             settings: settings, trackNames: names, startIndex: scope == .eachRegion ? max(0, startIndex) : 1)
    }

    /// What the export would write, for the summary line and the preset limits.
    var plannedJobs: [ExportJob] { jobs(directory: URL(fileURLWithPath: "/"), fileName: defaultFileName) }

    var summary: String {
        let jobs = plannedJobs
        let rate = editor.sessionRate
        let seconds = jobs.reduce(0.0) { $0 + Double($1.span.length) / max(rate, 1) }
        let files = jobs.count * (settings.layout == .split ? settings.layout.fileChannels(session: editor.project.mixChannelCount).count : 1)
        let names = jobs.prefix(3).map { $0.urls(settings).map(\.lastPathComponent).joined(separator: ", ") }.joined(separator: ", ")
        let more = jobs.count > 3 ? ", ..." : ""
        return "\(files) file\(files == 1 ? "" : "s"), \(String(format: "%.1f", seconds)) s: \(names)\(more)"
    }

    /// Why Export is disabled, or nil.
    var problem: String? {
        let jobs = plannedJobs
        if jobs.isEmpty || jobs.allSatisfy({ $0.span.isEmpty }) { return "Nothing to export." }
        let rate = max(editor.sessionRate, 1)
        return preset?.violation(fileSeconds: jobs.map { Double($0.span.length) / rate })
    }

    // MARK: Presets

    /// Choosing a preset sets and locks its fields; None unlocks them as they are and brings back the user's pattern.
    func applyPreset(_ p: ExportPreset?) {
        if isPatternLocked {
            pattern = AppSettings.shared.exportPattern
            stemPattern = AppSettings.shared.stemPattern
        }
        preset = p
        if let p {
            settings = ExportSettings(preset: p)
            if let name = p.limits.namePattern {
                pattern = name
                stemPattern = name
            }
        }
    }

    var isLocked: Bool { preset != nil }
    var isPatternLocked: Bool { preset?.limits.namePattern != nil }

    // MARK: Export

    /// Asks for the destination (a file, or a folder for Each Region), then exports.
    /// `destination` skips the panel (self-test).
    func chooseAndExport(in window: NSWindow, destination: URL? = nil, completion: @escaping @MainActor (Bool) -> Void) {
        if let destination {
            run(directory: scope.writesFolder ? destination : destination.deletingLastPathComponent(),
                fileName: scope.writesFolder ? defaultFileName : destination.deletingPathExtension().lastPathComponent,
                completion: completion)
            return
        }
        if scope.writesFolder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = scope == .stems ? "Choose a folder for the stems." : "Choose a folder for the region files."
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    guard response == .OK, let url = panel.url else { return }
                    self.run(directory: url, fileName: self.defaultFileName, completion: completion)
                }
            }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = defaultFileName + "." + settings.fileExtension
            panel.allowedContentTypes = []
            panel.prompt = "Export"
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    guard response == .OK, let url = panel.url else { return }
                    self.run(directory: url.deletingLastPathComponent(), fileName: url.deletingPathExtension().lastPathComponent,
                             completion: completion)
                }
            }
        }
    }

    private func run(directory: URL, fileName: String, completion: @escaping @MainActor (Bool) -> Void) {
        let s = AppSettings.shared
        s.exportSettings = settings
        s.exportPattern = isPatternLocked ? s.exportPattern : pattern
        s.stemPattern = isPatternLocked ? s.stemPattern : stemPattern
        s.exportPresetID = preset?.id
        let jobs = jobs(directory: directory, fileName: fileName)
        let settings = settings
        let rate = editor.sessionRate
        cancelFlag.store(0)
        let cancelled = cancelFlag
        isExporting = true
        progress = 0
        status = "Exporting"
        let report: @Sendable (Double) -> Void = { [self] value in
            Task { @MainActor in if self.isExporting { self.progress = value } }
        }
        let started = Date()
        Task { [self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try Exporter.export(jobs, sessionRate: rate, settings: settings, progress: report,
                                        isCancelled: { cancelled.load() != 0 })
                }
            }.value
            isExporting = false
            switch result {
            case let .success(urls):
                progress = 1
                status = String(format: "Exported %d file%@ in %.1f s", urls.count, urls.count == 1 ? "" : "s",
                                Date().timeIntervalSince(started))
                lastExported = urls
                if scope == .eachRegion, !jobs.isEmpty { editor.exportStartIndex = max(0, startIndex) + jobs.count }
                completion(true)
            case let .failure(error):
                if case TapeError.cancelled = error { status = "Cancelled" } else { status = error.localizedDescription }
                completion(false)
            }
        }
    }

    /// Files written by the last successful export.
    private(set) var lastExported: [URL] = []

    func cancel() { cancelFlag.store(1) }
}
