import Foundation

/// The `.tape` package directory: `project.json`, `sources/`, `peaks/`.
public struct TapePackage: Sendable, Equatable {
    public static let fileExtension = "tape"

    public let url: URL

    public init(url: URL) { self.url = url }

    public var projectURL: URL { url.appendingPathComponent("project.json") }
    public var sourcesURL: URL { url.appendingPathComponent("sources", isDirectory: true) }
    public var peaksURL: URL { url.appendingPathComponent("peaks", isDirectory: true) }
    public var name: String { url.deletingPathExtension().lastPathComponent }

    /// Creates an empty package. Fails if something already exists at `url`.
    @discardableResult
    public static func create(at url: URL, project: Project = Project()) throws -> TapePackage {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        let package = TapePackage(url: url)
        try fm.createDirectory(at: package.sourcesURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: package.peaksURL, withIntermediateDirectories: true)
        try package.save(ProjectFile(document: project))
        return package
    }

    public func load() throws -> ProjectFile {
        let data = try Data(contentsOf: projectURL)
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)
        guard file.version <= ProjectFile.currentVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "This document was saved by a newer version of Tape (format \(file.version)).",
            ])
        }
        return file
    }

    /// Atomic write, so a crash mid-save leaves the previous version intact. Always writes the current format.
    public func save(_ file: ProjectFile) throws {
        try ensureDirectories()
        var file = file
        file.version = ProjectFile.currentVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: projectURL, options: .atomic)
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: peaksURL, withIntermediateDirectories: true)
    }

    public func peakURL(for sourceId: UUID) -> URL {
        peaksURL.appendingPathComponent("\(sourceId.uuidString).peaks")
    }

    /// Cache of a source converted to the session rate (see `Resampler`).
    public func resampledURL(for sourceId: UUID, sampleRate: Double) -> URL {
        peaksURL.appendingPathComponent("\(sourceId.uuidString)-\(Int(sampleRate)).caf")
    }

    /// Location of the original audio of `source`. External files are resolved by bookmark first.
    public func resolve(_ source: SourceRef) -> URL {
        switch source.location {
        case let .package(fileName):
            return sourcesURL.appendingPathComponent(fileName)
        case let .external(path, bookmark):
            if let bookmark, let url = Self.resolveBookmark(bookmark) { return url }
            return URL(fileURLWithPath: path)
        }
    }

    static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Security scoped bookmark when the process allows it, a plain bookmark otherwise.
    public static func bookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

/// Coalesces calls and runs the last one after `delay` on the main queue.
@MainActor
public final class Debouncer {
    public let delay: TimeInterval
    private var work: DispatchWorkItem?

    public init(delay: TimeInterval) { self.delay = delay }

    public func schedule(_ action: @escaping @MainActor () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.work = nil
                action()
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Runs a pending action now.
    public func flush(_ action: @MainActor () -> Void) {
        guard let w = work, !w.isCancelled else { return }
        w.cancel()
        work = nil
        action()
    }

    public var isPending: Bool { work.map { !$0.isCancelled } ?? false }
}
