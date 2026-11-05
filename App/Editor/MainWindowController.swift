import AppKit
import Combine
import SwiftUI
import TapeCore
import UniformTypeIdentifiers

/// One document window: transport and inspector on top, timeline full width below.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    let tapeDocument: TapeDocument
    let editor: EditorController
    let timeline: TimelineView
    private let mainSplit = NSSplitView()
    private let topSplit = NSSplitView()
    private var subscriptions: Set<AnyCancellable> = []
    var onClose: ((MainWindowController) -> Void)?

    init(document: TapeDocument) {
        tapeDocument = document
        editor = EditorController(document: document)
        timeline = TimelineView(editor: editor)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.chrome
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 820, height: 520)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("TapeMainWindow")
        buildLayout()
        updateTitle()

        editor.$errorMessage.compactMap { $0 }.sink { [weak self] message in
            self?.showError(message)
        }.store(in: &subscriptions)
        editor.focusRegionName.sink { [weak self] in self?.revealInspector() }.store(in: &subscriptions)
        tapeDocument.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateTitle() }
        }.store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        guard let window else { return }
        let transport = NSHostingView(rootView: VStack(spacing: 0) {
            RecordRow(editor: editor)
            Divider().overlay(Color(nsColor: Theme.separator))
            TransportPanel(editor: editor, document: tapeDocument).frame(height: 52)
            Spacer(minLength: 0)
        }.background(Color.tapeChrome))
        let inspector = NSHostingView(rootView: InspectorPanel(editor: editor, document: tapeDocument))
        transport.sizingOptions = []
        inspector.sizingOptions = []

        topSplit.isVertical = true
        topSplit.dividerStyle = .thin
        topSplit.delegate = self
        topSplit.addArrangedSubview(transport)
        topSplit.addArrangedSubview(inspector)
        topSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        topSplit.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)

        mainSplit.isVertical = false
        mainSplit.dividerStyle = .thin
        mainSplit.delegate = self
        mainSplit.addArrangedSubview(topSplit)
        mainSplit.addArrangedSubview(timeline)
        mainSplit.autosaveName = "TapeMainSplit"

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.chrome.cgColor
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainSplit)
        let titlebar: CGFloat = 28
        NSLayoutConstraint.activate([
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.topAnchor.constraint(equalTo: content.topAnchor, constant: titlebar),
            mainSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.layoutIfNeeded()

        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames TapeMainSplit") == nil {
            mainSplit.setPosition(window.frame.height / 3, ofDividerAt: 0)
        }
        inspector.isHidden = !AppSettings.shared.inspectorVisible
        applyInspectorWidth()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.layoutIfNeeded()
        applyInspectorWidth()
    }

    private func applyInspectorWidth() {
        guard let inspector = topSplit.arrangedSubviews.last, !inspector.isHidden else { return }
        topSplit.setPosition(topSplit.bounds.width - CGFloat(AppSettings.shared.inspectorWidth) - topSplit.dividerThickness,
                             ofDividerAt: 0)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === topSplit, let inspector = topSplit.arrangedSubviews.last,
              !inspector.isHidden, inspector.frame.width >= 200, window?.isVisible == true else { return }
        AppSettings.shared.inspectorWidth = Double(inspector.frame.width)
    }

    private func updateTitle() {
        window?.title = tapeDocument.displayName
        window?.representedURL = tapeDocument.isUntitled ? nil : tapeDocument.package.url
    }

    func focusTimeline() {
        window?.makeFirstResponder(timeline.metalView)
    }

    // MARK: Split view

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        splitView === mainSplit ? max(proposed, 90) : max(proposed, 300)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        splitView === mainSplit ? min(proposed, splitView.bounds.height - 160) : min(proposed, splitView.bounds.width - 220)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        splitView === topSplit && subview === topSplit.arrangedSubviews.last
    }

    // MARK: Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { tapeDocument.undoManager }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard tapeDocument.isUntitled else { return true }
        if tapeDocument.isEmpty { return true }
        let alert = NSAlert()
        alert.messageText = "Save this document before closing?"
        alert.informativeText = "Untitled documents are kept only until you close them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.beginSheetModal(for: sender) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn:
                    self.runSavePanel { saved in if saved { sender.close() } }
                case .alertThirdButtonReturn:
                    self.discardOnClose = true
                    sender.close()
                default:
                    break
                }
            }
        }
        return false
    }

    private var discardOnClose = false

    func windowWillClose(_ notification: Notification) {
        RecordController.shared.editorClosing(editor)
        editor.playback.shutdown()
        tapeDocument.flushSaves()
        if tapeDocument.isUntitled, tapeDocument.isEmpty || discardOnClose { tapeDocument.deletePackage() }
        onClose?(self)
    }

    // MARK: Save

    private func runSavePanel(completion: @escaping (Bool) -> Void) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "com.maikbluhm.tape.project")]
        panel.nameFieldStringValue = tapeDocument.isUntitled ? "Untitled.tape" : tapeDocument.package.url.lastPathComponent
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return completion(false) }
                do {
                    try self.tapeDocument.move(to: url)
                    self.updateTitle()
                    (NSApp.delegate as? AppDelegate)?.rememberOpenDocuments()
                    completion(true)
                } catch {
                    self.showError("Could not save: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if tapeDocument.isUntitled {
            runSavePanel { _ in }
        } else {
            tapeDocument.flushSaves()
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) { runSavePanel { _ in } }

    // MARK: Import

    @objc func importAudio(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self.importAudio(urls: panel.urls)
            }
        }
    }

    func importAudio(urls: [URL]) {
        do {
            try tapeDocument.importAudio(urls)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: Transport and view actions

    @objc func togglePlay(_ sender: Any?) { editor.togglePlay() }
    @objc func shuttleBackward(_ sender: Any?) { editor.shuttleBackward() }
    @objc func stopTransport(_ sender: Any?) { editor.stop() }
    @objc func shuttleForward(_ sender: Any?) { editor.shuttleForward() }
    @objc func setRangeIn(_ sender: Any?) { editor.setRangeIn() }
    @objc func setRangeOut(_ sender: Any?) { editor.setRangeOut() }
    @objc func clearRange(_ sender: Any?) { editor.clearRange() }
    @objc func toggleLoop(_ sender: Any?) { editor.toggleLoop() }
    @objc func goToStart(_ sender: Any?) { editor.goToStart() }
    @objc func goToEnd(_ sender: Any?) { editor.goToEnd() }
    @objc func zoomToFit(_ sender: Any?) { editor.fitAll() }
    @objc func zoomInTimeline(_ sender: Any?) { editor.zoomAroundPlayhead(by: 0.5) }
    @objc func zoomOutTimeline(_ sender: Any?) { editor.zoomAroundPlayhead(by: 2) }

    @objc func toggleRecord(_ sender: Any?) { RecordController.shared.toggleRecord(editor: editor) }

    // MARK: Edit actions

    override func selectAll(_ sender: Any?) { editor.selectAll() }
    @objc func bladeRegions(_ sender: Any?) { editor.blade() }
    @objc func deleteRegions(_ sender: Any?) { editor.deleteSelection(ripple: true) }
    @objc func deleteRegionsLeavingGap(_ sender: Any?) { editor.deleteSelection(ripple: false) }
    @objc func duplicateRegions(_ sender: Any?) { editor.duplicateSelection() }
    @objc func applyDefaultFades(_ sender: Any?) { editor.applyDefaultFades() }
    @objc func nudgeLeft(_ sender: Any?) { editor.nudge(-1) }
    @objc func nudgeRight(_ sender: Any?) { editor.nudge(1) }
    @objc func selectTool(_ sender: Any?) { editor.tool = .select }
    @objc func bladeTool(_ sender: Any?) { editor.tool = .blade }

    private var fadeSheet: NSWindow?

    @objc func showFadeDialog(_ sender: Any?) {
        guard let window, fadeSheet == nil, let first = editor.selectedRegions.first else { return }
        let count = editor.selectedRegions.count
        let dialog = FadeDialog(sessionRate: editor.sessionRate, fadeIn: first.fadeIn, fadeOut: first.fadeOut, regionCount: count) {
            [weak self] result in
            guard let self, let sheet = self.fadeSheet else { return }
            if let result { self.editor.setFades(fadeIn: result.0, fadeOut: result.1) }
            window.endSheet(sheet)
            self.fadeSheet = nil
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: dialog))
        sheet.appearance = NSAppearance(named: .darkAqua)
        fadeSheet = sheet
        window.beginSheet(sheet)
    }

    // MARK: Process

    private var processSheet: NSWindow?
    private(set) var processSession: ProcessSession?
    private(set) var openAlert: NSAlert?

    @objc func showProcess(_ sender: Any?) {
        guard let window, processSheet == nil,
              let raw = (sender as? NSMenuItem)?.representedObject as? String, let kind = ProcessKind(rawValue: raw) else { return }
        let session = ProcessSession(kind: kind, editor: editor)
        let sheetView = ProcessSheet(session: session) { [weak self] in
            guard let self, let sheet = self.processSheet else { return }
            window.endSheet(sheet)
            self.processSheet = nil
            self.processSession = nil
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: sheetView))
        sheet.appearance = NSAppearance(named: .darkAqua)
        processSheet = sheet
        processSession = session
        window.beginSheet(sheet)
    }

    @objc func consolidate(_ sender: Any?) {
        tapeDocument.consolidate { [weak self] error in
            if let error { self?.showError("Consolidate failed: \(error.localizedDescription)") }
        }
    }

    @objc func cleanUpSources(_ sender: Any?) {
        guard let window else { return }
        let preview = tapeDocument.cleanUpPreview()
        guard preview.sources + preview.files > 0 else {
            showError("There are no unused sources.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Clean up sources?"
        alert.informativeText = "\(preview.sources) unused source\(preview.sources == 1 ? "" : "s") and \(preview.files) file\(preview.files == 1 ? "" : "s") "
            + "(\(ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file))) that no region uses will be deleted. "
            + "This clears undo and cannot be undone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        openAlert = alert
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                self.openAlert = nil
                if response == .alertFirstButtonReturn { self.tapeDocument.cleanUpSources() }
            }
        }
    }

    /// Shows the inspector if hidden, for double click on a region.
    func revealInspector() {
        guard let inspector = topSplit.arrangedSubviews.last,
              inspector.isHidden || topSplit.isSubviewCollapsed(inspector) else { return }
        toggleInspector(nil)
    }

    @objc func toggleSnapToZero(_ sender: Any?) {
        AppSettings.shared.snapToZeroCrossing.toggle()
        editor.needsDisplay?()
    }

    @objc func toggleInspector(_ sender: Any?) {
        guard let inspector = topSplit.arrangedSubviews.last else { return }
        let show = inspector.isHidden || topSplit.isSubviewCollapsed(inspector)
        inspector.isHidden = !show
        topSplit.adjustSubviews()
        AppSettings.shared.inspectorVisible = show
        applyInspectorWidth()
    }

    /// Single key shortcuts are disabled while a text field edits, so typing works there.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let editingText = window?.firstResponder is NSTextView
        if editingText, item.keyEquivalentModifierMask.isEmpty || item.keyEquivalentModifierMask == .shift { return false }
        switch item.action {
        case #selector(togglePlay(_:)):
            if RecordController.shared.isRecording {
                item.title = "Stop Recording"
                return true
            }
            item.title = editor.isPlaying ? "Pause" : "Play"
            return tapeDocument.project.sessionRate != nil
        case #selector(toggleRecord(_:)):
            item.title = RecordController.shared.isRecording ? "Stop Recording" : "Record"
            return true
        case #selector(toggleLoop(_:)):
            item.state = editor.loopEnabled ? .on : .off
            return true
        case #selector(toggleSnapToZero(_:)):
            item.state = AppSettings.shared.snapToZeroCrossing ? .on : .off
            return true
        case #selector(toggleInspector(_:)):
            item.title = AppSettings.shared.inspectorVisible ? "Hide Inspector" : "Show Inspector"
            return true
        case #selector(clearRange(_:)):
            return editor.range != nil
        case #selector(deleteRegions(_:)), #selector(deleteRegionsLeavingGap(_:)), #selector(duplicateRegions(_:)),
             #selector(applyDefaultFades(_:)), #selector(showFadeDialog(_:)), #selector(nudgeLeft(_:)), #selector(nudgeRight(_:)):
            return !editor.selectedIDs.isEmpty
        case #selector(bladeRegions(_:)), #selector(selectAll(_:)):
            return !tapeDocument.project.regions.isEmpty
        case #selector(showProcess(_:)):
            return processSheet == nil && fadeSheet == nil && !RecordController.shared.isRecording && ProcessSession.canProcess(editor)
        case #selector(consolidate(_:)):
            return tapeDocument.project.sources.contains {
                if case .external = $0.location { return true }
                return false
            }
        case #selector(cleanUpSources(_:)):
            return !RecordController.shared.isRecording
        case #selector(selectTool(_:)):
            item.state = editor.tool == .select ? .on : .off
            return true
        case #selector(bladeTool(_:)):
            item.state = editor.tool == .blade ? .on : .off
            return true
        default:
            return true
        }
    }
}
