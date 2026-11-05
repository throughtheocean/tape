import AppKit
import Combine
import TapeCore

/// One open `.tape` package: the undoable project, view state, loaded sources and autosave.
@MainActor
final class TapeDocument: ObservableObject {
    private(set) var package: TapePackage
    @Published private(set) var project: Project
    @Published private(set) var revision = 0
    @Published private(set) var loaded: [UUID: LoadedSource] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published private(set) var failures: [UUID: String] = [:]
    @Published private(set) var peakTimes: [UUID: Double] = [:]
    var view: ViewState

    let undoManager = UndoManager()
    private let autosave = Debouncer(delay: 0.5)
    private static let ioQueue = DispatchQueue(label: "tape.document.io", qos: .utility)

    init(package: TapePackage) throws {
        let file = try package.load()
        self.package = package
        project = file.document
        view = file.view
        loadMissingSources()
    }

    // MARK: Untitled documents

    static var untitledDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tape/Untitled", isDirectory: true)
    }

    static func createUntitled() throws -> TapeDocument {
        try FileManager.default.createDirectory(at: untitledDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = untitledDirectory.appendingPathComponent("Untitled \(stamp).tape")
        return try TapeDocument(package: TapePackage.create(at: url))
    }

    var isUntitled: Bool {
        package.url.deletingLastPathComponent().standardizedFileURL.path == Self.untitledDirectory.standardizedFileURL.path
    }

    var displayName: String { isUntitled ? "Untitled" : package.name }

    var isEmpty: Bool { project.regions.isEmpty && project.sources.isEmpty }

    /// Moves the package to a user chosen location.
    func move(to url: URL) throws {
        saveNow()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.trashItem(at: url, resultingItemURL: nil) }
        try fm.moveItem(at: package.url, to: url)
        package = TapePackage(url: url)
        objectWillChange.send()
    }

    func deletePackage() {
        try? FileManager.default.removeItem(at: package.url)
    }

    // MARK: Undoable changes

    /// Applies one user action as one undo step named `name`.
    func apply(_ name: String, _ change: (inout Project) -> Void) {
        var next = project
        change(&next)
        next.sortRegions()
        guard next != project else { return }
        replaceProject(next, actionName: name)
    }

    private func replaceProject(_ next: Project, actionName: String) {
        let previous = project
        project = next
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.replaceProject(previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        changed()
        loadMissingSources()
    }

    private func changed() {
        revision += 1
        scheduleSave()
    }

    // MARK: Saving

    func scheduleSave() {
        autosave.schedule { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        let file = ProjectFile(document: project, view: view)
        let package = package
        Self.ioQueue.async {
            do {
                try package.save(file)
            } catch {
                NSLog("Tape autosave failed: \(error)")
            }
        }
    }

    /// Blocks until queued writes are on disk.
    func flushSaves() {
        autosave.flush { saveNow() }
        Self.ioQueue.sync {}
    }

    // MARK: Import

    func importAudio(_ urls: [URL]) throws {
        var refs: [SourceRef] = []
        for url in urls {
            let info = try AudioFileInfo(url: url)
            refs.append(SourceRef(name: url.lastPathComponent,
                                  location: .external(path: url.path, bookmark: TapePackage.bookmark(for: url)),
                                  sampleRate: info.sampleRate, channelCount: info.channelCount, frameCount: info.frameCount))
        }
        guard !refs.isEmpty else { return }
        let name = refs.count == 1 ? "Import \(refs[0].name)" : "Import \(refs.count) Files"
        apply(name) { p in
            if p.sessionRate == nil {
                p.sessionRate = refs[0].sampleRate
                p.channelCount = refs[0].channelCount
            }
            let rate = p.sessionRate!
            var position = p.length
            for ref in refs {
                p.sources.append(ref)
                let length = ref.sessionFrameCount(sessionRate: rate)
                p.regions.append(Region(name: (ref.name as NSString).deletingPathExtension, sourceId: ref.id,
                                        sourceIn: 0, sourceOut: length, position: position))
                position += length
            }
        }
    }

    // MARK: Recording

    /// Adds a finished recording from `sources/` as a region starting at `position`.
    /// Returns the timeline frame where R was pressed, after the pre-roll head.
    @discardableResult
    func addRecording(fileName: String, result: RecordEngine.Recording, at position: Int64) -> Int64 {
        let ref = SourceRef(name: fileName, location: .package(fileName: fileName), sampleRate: result.sampleRate,
                            channelCount: result.channelCount, frameCount: result.frames, preRollFrames: result.preRollFrames)
        var livePoint = position
        apply("Record") { p in
            if p.sessionRate == nil {
                p.sessionRate = result.sampleRate
                p.channelCount = result.channelCount
            }
            let rate = p.sessionRate!
            p.sources.append(ref)
            p.regions.append(Region(name: (fileName as NSString).deletingPathExtension, sourceId: ref.id, sourceIn: 0,
                                    sourceOut: ref.sessionFrameCount(sessionRate: rate), position: position))
            livePoint = position + ref.sessionPreRoll(sessionRate: rate)
        }
        return livePoint
    }

    // MARK: Sources

    private func loadMissingSources() {
        guard let rate = project.sessionRate else { return }
        let package = package
        for ref in project.sources where loaded[ref.id] == nil && !loading.contains(ref.id) && failures[ref.id] == nil {
            loading.insert(ref.id)
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = Result { try SourceLoader.load(ref, in: package, sessionRate: rate) }
                await self?.finishLoading(ref.id, result)
            }
        }
    }

    private func finishLoading(_ id: UUID, _ result: Result<LoadedSource, Error>) {
        loading.remove(id)
        switch result {
        case let .success(source):
            loaded[id] = source
            if let t = source.peakBuildSeconds {
                peakTimes[id] = t
                NSLog("Tape peaks for \(source.ref.name): \(String(format: "%.2f", t)) s")
            }
        case let .failure(error):
            failures[id] = error.localizedDescription
        }
        revision += 1
    }

    /// Snapshot for the renderer; regions whose source is not loaded yet are left out.
    func editList() -> EditList {
        var sources: [UUID: SampleSource] = [:]
        for (id, s) in loaded { sources[id] = s.source }
        return EditList(regions: project.regions.filter { sources[$0.sourceId] != nil },
                        sources: sources, channelCount: project.channelCount)
    }

    var sessionRate: Double { project.sessionRate ?? 48000 }
}
