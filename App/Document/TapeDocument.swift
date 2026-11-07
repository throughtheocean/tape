import AppKit
import AVFoundation
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
    /// The project as opened or last exported; quitting asks about an export when it differs.
    private var exportedProject: Project

    let undoManager = UndoManager()
    private let autosave = Debouncer(delay: 0.5)
    private static let ioQueue = DispatchQueue(label: "tape.document.io", qos: .utility)

    init(package: TapePackage) throws {
        let file = try package.load()
        self.package = package
        project = file.document
        exportedProject = file.document
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

    var hasUnexportedChanges: Bool { project != exportedProject }

    func markExported() { exportedProject = project }

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

    /// Applies one user action as one undo step named `name`. Magnetic tracks and connected regions settle after it.
    func apply(_ name: String, _ change: (inout Project) -> Void) {
        var next = project
        EditOperations.edit(&next, change)
        guard next != project else { return }
        replaceProject(next, actionName: name)
    }

    // MARK: Gestures

    private(set) var gestureBase: Project?

    var isInGesture: Bool { gestureBase != nil }

    /// Starts a drag that changes the project live (audible while playing) without undo steps.
    func beginGesture() {
        gestureBase = project
    }

    /// Replaces the live project with `change` applied to the state at `beginGesture`.
    func updateGesture(_ change: (inout Project) -> Void) {
        guard let base = gestureBase else { return }
        var next = base
        EditOperations.edit(&next, change)
        guard next != project else { return }
        project = next
        revision += 1
    }

    /// Ends the drag as one undo step named `name`, or none if nothing changed.
    func endGesture(_ name: String) {
        guard let base = gestureBase else { return }
        gestureBase = nil
        let final = project
        guard final != base else { return }
        project = base
        replaceProject(final, actionName: name)
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

    /// Imports each file onto a new track at the bottom, named after the file, starting at `position`.
    /// In a document without regions the first file goes onto the first track instead. One undo step.
    @discardableResult
    func importAudioAsTracks(_ urls: [URL], position: Int64) throws -> [UUID] {
        let refs = try sourceRefs(urls)
        guard !refs.isEmpty else { return [] }
        var trackIDs: [UUID] = []
        let name = refs.count == 1 ? "Import \(refs[0].name) as Track" : "Import \(refs.count) Files as Tracks"
        apply(name) { p in
            if p.sessionRate == nil {
                p.sessionRate = refs[0].sampleRate
                p.channelCount = refs[0].channelCount
            }
            let rate = p.sessionRate!
            let reuseFirst = p.regions.isEmpty
            for (i, ref) in refs.enumerated() {
                let title = (ref.name as NSString).deletingPathExtension
                let trackId = i == 0 && reuseFirst ? p.tracks[0].id : EditOperations.addTrack(&p)
                if let t = p.trackIndex(trackId) { p.tracks[t].name = title }
                p.sources.append(ref)
                p.regions.append(Region(name: title, trackId: trackId, sourceId: ref.id, sourceIn: 0,
                                        sourceOut: ref.sessionFrameCount(sessionRate: rate), position: max(0, position)))
                trackIDs.append(trackId)
            }
        }
        return trackIDs
    }

    /// Imports the files onto `track` one after another (a drop over a lane). `start` gets their lengths in session
    /// frames and returns the first region's position. With `overwrite` they cover what lies under them. One undo step.
    func importAudio(_ urls: [URL], onto track: UUID, start: ([Int64]) -> Int64, overwrite: Bool) throws {
        let refs = try sourceRefs(urls)
        guard !refs.isEmpty else { return }
        let rate = project.sessionRate ?? refs[0].sampleRate
        let lengths = refs.map { $0.sessionFrameCount(sessionRate: rate) }
        let position = start(lengths)
        let name = refs.count == 1 ? "Import \(refs[0].name)" : "Import \(refs.count) Files"
        apply(name) { p in
            if p.sessionRate == nil {
                p.sessionRate = refs[0].sampleRate
                p.channelCount = refs[0].channelCount
            }
            let regions = zip(refs, lengths).map { ref, length in
                Region(name: (ref.name as NSString).deletingPathExtension, sourceId: ref.id, sourceIn: 0, sourceOut: length,
                       position: 0)
            }
            p.sources += refs
            EditOperations.place(&p, regions, track: p.track(track)?.id ?? p.tracks[0].id, at: position, overwrite: overwrite)
        }
    }

    private func sourceRefs(_ urls: [URL]) throws -> [SourceRef] {
        try urls.map { url in
            let info = try AudioFileInfo(url: url)
            return SourceRef(name: url.lastPathComponent,
                             location: .external(path: url.path, bookmark: TapePackage.bookmark(for: url)),
                             sampleRate: info.sampleRate, channelCount: info.channelCount, frameCount: info.frameCount)
        }
    }

    /// Imports at the document end, onto `track` (default: the first track).
    func importAudio(_ urls: [URL], track: UUID? = nil) throws {
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
            let trackId = track.flatMap { p.track($0)?.id } ?? p.tracks[0].id
            var position = p.length
            for ref in refs {
                p.sources.append(ref)
                let length = ref.sessionFrameCount(sessionRate: rate)
                p.regions.append(Region(name: (ref.name as NSString).deletingPathExtension, trackId: trackId, sourceId: ref.id,
                                        sourceIn: 0, sourceOut: length, position: position))
                position += length
            }
        }
    }

    // MARK: Recording

    /// Adds a finished recording from `sources/` as a region starting at `position`.
    /// Returns the timeline frame where R was pressed, after the pre-roll head.
    @discardableResult
    func addRecording(fileName: String, result: RecordEngine.Recording, at position: Int64, track: UUID) -> Int64 {
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
            let trackId = p.track(track)?.id ?? p.tracks[0].id
            p.regions.append(Region(name: (fileName as NSString).deletingPathExtension, trackId: trackId, sourceId: ref.id, sourceIn: 0,
                                    sourceOut: ref.sessionFrameCount(sessionRate: rate), position: position))
            livePoint = position + ref.sessionPreRoll(sessionRate: rate)
        }
        return livePoint
    }

    /// A recording made while playing: its first live frame lands at `liveAt`, the pre-roll stays hidden before the
    /// region's start (trim the start out to reveal it), and it covers what lies under it on `track`. One undo step.
    func addOverdub(fileName: String, result: RecordEngine.Recording, liveAt: Int64, track: UUID) {
        let ref = SourceRef(name: fileName, location: .package(fileName: fileName), sampleRate: result.sampleRate,
                            channelCount: result.channelCount, frameCount: result.frames, preRollFrames: result.preRollFrames)
        apply("Record") { p in
            if p.sessionRate == nil {
                p.sessionRate = result.sampleRate
                p.channelCount = result.channelCount
            }
            let rate = p.sessionRate!
            p.sources.append(ref)
            let trackId = p.track(track)?.id ?? p.tracks[0].id
            let length = ref.sessionFrameCount(sessionRate: rate)
            let early = max(0, -liveAt)
            let sourceIn = min(ref.sessionPreRoll(sessionRate: rate) + early, length)
            let region = Region(name: (fileName as NSString).deletingPathExtension, trackId: trackId, sourceId: ref.id,
                                sourceIn: sourceIn, sourceOut: length, position: max(0, liveAt))
            guard region.length > 0 else { return }
            p.regions.append(region)
            EditOperations.overwrite(&p, by: [region.id])
        }
    }

    // MARK: Processing and source housekeeping

    /// A new file name in `sources/` that does not exist yet.
    func newSourceFile(base: String, ext: String = "caf") -> (name: String, url: URL) {
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var name = "\(clean).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: package.sourcesURL.appendingPathComponent(name).path) {
            name = "\(clean) \(n).\(ext)"
            n += 1
        }
        return (name, package.sourcesURL.appendingPathComponent(name))
    }

    /// Registers a source loaded elsewhere (a process result) so regions can switch to it without a gap.
    func adopt(_ source: LoadedSource) {
        loaded[source.ref.id] = source
        failures[source.ref.id] = nil
    }

    /// Sources no region uses.
    var unusedSources: [SourceRef] {
        let used = Set(project.regions.map(\.sourceId))
        return project.sources.filter { !used.contains($0.id) }
    }

    /// Files in `sources/` that no remaining source points to, plus the unused sources' own package files.
    private func orphanFiles(keeping refs: [SourceRef]) -> [URL] {
        let kept = Set(refs.compactMap { ref -> String? in
            if case let .package(fileName) = ref.location { return fileName }
            return nil
        })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: package.sourcesURL.path)) ?? []
        return files.filter { !kept.contains($0) && !$0.hasPrefix(".") }.map { package.sourcesURL.appendingPathComponent($0) }
    }

    /// What Clean Up Sources would remove: unused sources and their files, in bytes.
    func cleanUpPreview() -> (sources: Int, files: Int, bytes: Int64) {
        let unused = Set(unusedSources.map(\.id))
        let files = orphanFiles(keeping: project.sources.filter { !unused.contains($0.id) })
        let bytes = files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (unused.count, files.count, bytes)
    }

    /// Removes unused sources, their files in `sources/` and their caches. Clears undo, since undo could
    /// point regions back at deleted files.
    func cleanUpSources() {
        let unused = Set(unusedSources.map(\.id))
        var next = project
        next.sources.removeAll { unused.contains($0.id) }
        for url in orphanFiles(keeping: next.sources) { try? FileManager.default.removeItem(at: url) }
        for id in unused {
            try? FileManager.default.removeItem(at: package.peakURL(for: id))
            if let caches = try? FileManager.default.contentsOfDirectory(atPath: package.peaksURL.path) {
                for name in caches where name.hasPrefix(id.uuidString) {
                    try? FileManager.default.removeItem(at: package.peaksURL.appendingPathComponent(name))
                }
            }
            loaded[id] = nil
            failures[id] = nil
        }
        project = next
        undoManager.removeAllActions()
        changed()
    }

    /// Copies every external source into `sources/` as float32 CAF at its own rate and points the
    /// sources there, as one undo step. Runs the copies off the main thread.
    func consolidate(completion: @escaping @MainActor (Error?) -> Void) {
        let externals = project.sources.filter {
            if case .external = $0.location { return true }
            return false
        }
        guard !externals.isEmpty else { return completion(nil) }
        let package = package
        let targets = externals.map { ref in (ref, newSourceFile(base: (ref.name as NSString).deletingPathExtension)) }
        Task {
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    try package.ensureDirectories()
                    for (ref, file) in targets {
                        try Self.copyAsCAF(from: package.resolve(ref), to: file.url)
                    }
                    return nil
                } catch {
                    for (_, file) in targets { try? FileManager.default.removeItem(at: file.url) }
                    return error
                }
            }.value
            if failure == nil {
                apply("Consolidate") { p in
                    for (ref, file) in targets {
                        if let i = p.sources.firstIndex(where: { $0.id == ref.id }) {
                            p.sources[i].location = .package(fileName: file.name)
                        }
                    }
                }
            }
            completion(failure)
        }
    }

    nonisolated private static func copyAsCAF(from input: URL, to output: URL) throws {
        let inFile = try AVAudioFile(forReading: input)
        let format = inFile.processingFormat
        let outFile = try AVAudioFile(forWriting: output, settings: AudioFileFormat(container: .caf, sampleFormat: .float32,
                                                                                  sampleRate: format.sampleRate,
                                                                                  channelCount: Int(format.channelCount)).settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536)!
        while inFile.framePosition < inFile.length {
            try inFile.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try outFile.write(from: buffer)
        }
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
        return EditList(project: project, sources: sources)
    }

    var sessionRate: Double { project.sessionRate ?? 48000 }

    /// Source length in session frames, the limit for trimming a region's end.
    func sourceLength(_ id: UUID) -> Int64 {
        if id == Region.gapSourceID { return Region.gapOrigin * 2 }
        if let loaded = loaded[id] { return loaded.source.frameCount }
        return project.source(id)?.sessionFrameCount(sessionRate: sessionRate) ?? 0
    }
}
