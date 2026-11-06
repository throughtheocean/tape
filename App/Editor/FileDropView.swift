import AppKit
import TapeCore
import UniformTypeIdentifiers

/// Window content that accepts audio files and Tape projects dragged from the Finder.
@MainActor
final class FileDropView: NSView {
    /// Files, window point, Option held.
    var onDrop: ([URL], NSPoint, Bool) -> Bool = { _, _, _ in false }
    var canDrop: () -> Bool = { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        let all = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return all.filter { url in
            if url.pathExtension.lowercased() == TapePackage.fileExtension { return true }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            return type?.conforms(to: .audio) == true
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canDrop() && !urls(sender).isEmpty ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard canDrop(), !files.isEmpty else { return false }
        return onDrop(files, sender.draggingLocation, NSEvent.modifierFlags.contains(.option))
    }
}
