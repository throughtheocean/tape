import AppKit
import Combine
import SwiftUI
import TapeCore
import UniformTypeIdentifiers

/// One document window: inspector sidebar on the left, transport bar and timeline to its right.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let tapeDocument: TapeDocument
    let editor: EditorController
    let timeline: TimelineView
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
        editor.confirm = { [weak self] message, info, button, action in self?.confirm(message, info, button, action) }
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
        }.background(Color.tapeChrome))
        transport.sizingOptions = []
        let inspector = NSHostingView(rootView: InspectorPanel(editor: editor, document: tapeDocument))
        inspector.sizingOptions = []
        inspectorView = inspector

        sidebar.wantsLayer = true
        sidebar.layer?.masksToBounds = true
        sidebar.layer?.backgroundColor = Theme.chrome.cgColor
        sidebarLine.wantsLayer = true
        sidebarLine.layer?.backgroundColor = Theme.separator.cgColor
        sidebarHandle.onDrag = { [weak self] dx in self?.resizeInspector(by: dx) }

        sidebarButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Inspector")
        sidebarButton.isBordered = false
        sidebarButton.contentTintColor = Theme.secondaryText
        sidebarButton.toolTip = "Show or hide the inspector (Option Command I)"
        sidebarButton.target = self
        sidebarButton.action = #selector(toggleInspector(_:))

        let content = FileDropView()
        content.onDrop = { [weak self] urls, point, option in self?.dropFiles(urls, at: point, keepBoth: option) ?? false }
        content.canDrop = { RecordController.shared.isRecording == false }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.chrome.cgColor
        for v in [sidebar, sidebarLine, transport, timeline, sidebarHandle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        inspector.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(inspector)

        let titlebar: CGFloat = 28
        let width = min(max(CGFloat(AppSettings.shared.inspectorWidth), Self.inspectorWidths.lowerBound),
                        Self.inspectorWidths.upperBound)
        let visible = AppSettings.shared.inspectorVisible
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: visible ? width : 0)
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor, constant: titlebar),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarWidth,
            inspector.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: sidebar.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            inspectorWidth,

            sidebarLine.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarLine.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarLine.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarLine.widthAnchor.constraint(equalToConstant: 1),
            sidebarHandle.centerXAnchor.constraint(equalTo: sidebarLine.centerXAnchor),
            sidebarHandle.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarHandle.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarHandle.widthAnchor.constraint(equalToConstant: 7),

            transport.leadingAnchor.constraint(equalTo: sidebarLine.trailingAnchor),
            transport.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            transport.topAnchor.constraint(equalTo: content.topAnchor, constant: titlebar),
            transport.heightAnchor.constraint(equalToConstant: Self.transportHeight),
            timeline.leadingAnchor.constraint(equalTo: sidebarLine.trailingAnchor),
            timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            timeline.topAnchor.constraint(equalTo: transport.bottomAnchor),
            timeline.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        inspector.isHidden = !visible
        sidebarLine.isHidden = !visible
        sidebarHandle.isHidden = !visible
        window.contentView = content

        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: titlebar))
        sidebarButton.frame = NSRect(x: 6, y: 3, width: 24, height: 22)
        holder.addSubview(sidebarButton)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// Record row (44), divider, transport (52).
    static let transportHeight: CGFloat = 97
    static let inspectorWidths: ClosedRange<CGFloat> = 260...520

    private let sidebar = NSView()
    private let sidebarLine = NSView()
    private let sidebarHandle = SidebarResizeHandle()
    private let sidebarButton = NSButton()
    var sidebarToggle: NSButton { sidebarButton }
    private var inspectorView: NSView?
    private var sidebarWidth: NSLayoutConstraint!
    private var inspectorWidth: NSLayoutConstraint!

    var isInspectorVisible: Bool { sidebarWidth.constant > 0 }

    private func resizeInspector(by dx: CGFloat) {
        let w = min(max(inspectorWidth.constant + dx, Self.inspectorWidths.lowerBound), Self.inspectorWidths.upperBound)
        inspectorWidth.constant = w
        sidebarWidth.constant = w
        AppSettings.shared.inspectorWidth = Double(w)
    }

    /// Slides the inspector in or out from the left.
    func setInspectorVisible(_ show: Bool, animated: Bool = true) {
        guard show != isInspectorVisible, let content = window?.contentView else { return }
        AppSettings.shared.inspectorVisible = show
        if show {
            inspectorView?.isHidden = false
            sidebarLine.isHidden = false
            sidebarHandle.isHidden = false
        }
        let target = show ? inspectorWidth.constant : 0
        guard animated else {
            sidebarWidth.constant = target
            finishInspectorSlide(shown: show)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            sidebarWidth.animator().constant = target
            content.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishInspectorSlide(shown: show) }
        })
    }

    private func finishInspectorSlide(shown: Bool) {
        guard !shown, !isInspectorVisible else { return }
        inspectorView?.isHidden = true
        sidebarLine.isHidden = true
        sidebarHandle.isHidden = true
    }

    private func updateTitle() {
        window?.title = tapeDocument.displayName
        window?.representedURL = tapeDocument.isUntitled ? nil : tapeDocument.package.url
    }

    func focusTimeline() {
        window?.makeFirstResponder(timeline.metalView)
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
            try tapeDocument.importAudio(urls, track: editor.selectedTrackID)
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Audio dropped on the window. An empty document takes the files from the start (the multitrack view gives
    /// each file a track). Dropped over a lane, the files go onto that track at the drop point, snapped like a
    /// region drag, covering what lies under them unless `keepBoth` (Option). Below the last lane they get new tracks
    /// at the bottom. Elsewhere in the single view they go to the end of the shown track, as Import does.
    /// Tape projects open in their own window.
    @discardableResult
    func dropFiles(_ urls: [URL], at windowPoint: NSPoint?, keepBoth: Bool = false) -> Bool {
        let packages = urls.filter { $0.pathExtension.lowercased() == TapePackage.fileExtension }
        let audio = urls.filter { $0.pathExtension.lowercased() != TapePackage.fileExtension }
        if !packages.isEmpty { (NSApp.delegate as? AppDelegate)?.openURLs(packages) }
        guard !audio.isEmpty else { return !packages.isEmpty }
        let metal = timeline.metalView
        let p = windowPoint.map { metal.convert($0, from: nil) }
        let inLanes = p.map { metal.bounds.contains($0) && Double($0.y) >= editor.laneViewport.top && Double($0.y) < editor.laneViewport.bottom } ?? false
        let frame = p.map { Int64(max(0, editor.frame(forX: Double($0.x)).rounded())) } ?? 0
        do {
            if !tapeDocument.project.regions.isEmpty, inLanes, let p, let lane = editor.lane(atY: Double(p.y)) {
                let editor = editor
                try tapeDocument.importAudio(audio, onto: lane.track.id, start: { editor.snappedDrop(frame, lengths: $0) },
                                             overwrite: !keepBoth)
                editor.selectTrack(lane.track.id, header: false)
            } else if editor.multitrack {
                let empty = tapeDocument.project.regions.isEmpty
                let ids = try tapeDocument.importAudioAsTracks(audio, position: !empty && p.map { metal.bounds.contains($0) } == true ? frame : 0)
                if let first = ids.first {
                    editor.selectTrack(first, header: true)
                    editor.revealSelectedLane()
                }
            } else {
                try tapeDocument.importAudio(audio, track: editor.selectedTrackID)
            }
        } catch {
            showError(error.localizedDescription)
        }
        return true
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
    @objc func deleteRegions(_ sender: Any?) {
        if editor.multitrack, editor.headerFocused, editor.selectedIDs.isEmpty {
            removeTrack(sender)
        } else {
            editor.deleteSelection(ripple: true)
        }
    }
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

    // MARK: Export

    private var exportSheet: NSWindow?
    private(set) var exportSession: ExportSession?
    /// Self-test: export here instead of asking with a panel.
    var exportDestination: URL?
    private(set) var lastExportStatus = ""

    @objc func showExport(_ sender: Any?) { presentExport(scope: nil, region: nil) }
    @objc func showExportEachRegion(_ sender: Any?) { presentExport(scope: .eachRegion, region: nil) }

    /// Right click on a region: export just that region.
    @objc func exportRegion(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        presentExport(scope: nil, region: id)
    }

    private func presentExport(scope: ExportScopeKind?, region: UUID?) {
        guard let window, exportSheet == nil, window.attachedSheet == nil else { return }
        let session = ExportSession(editor: editor, scope: scope, onlyRegion: region)
        let close: () -> Void = { [weak self] in
            guard let self, let sheet = self.exportSheet else { return }
            window.endSheet(sheet)
            self.exportSheet = nil
            self.exportSession = nil
        }
        let view = ExportSheet(session: session, export: { [weak self] in
            guard let self, let sheet = self.exportSheet else { return }
            session.chooseAndExport(in: sheet, destination: self.exportDestination) { ok in
                self.lastExportStatus = session.status
                if ok { close() }
            }
        }, close: close)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheet.appearance = NSAppearance(named: .darkAqua)
        exportSheet = sheet
        exportSession = session
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

    /// A sheet with `button` and Cancel; `action` runs on `button`.
    func confirm(_ message: String, _ info: String, _ button: String, _ action: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        openAlert = alert
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                self.openAlert = nil
                if response == .alertFirstButtonReturn { action() }
            }
        }
    }

    /// Shows the inspector if hidden, for double click on a region.
    func revealInspector() {
        setInspectorVisible(true)
    }

    // MARK: Tracks

    @objc func toggleMultitrack(_ sender: Any?) { editor.multitrack.toggle() }
    @objc func toggleOnlyTrack(_ sender: Any?) { editor.onlyTrack.toggle() }
    @objc func toggleMagnetic(_ sender: Any?) { editor.toggleMagnetic(editor.selectedTrackID) }
    @objc func addTrack(_ sender: Any?) { editor.addTrack() }
    @objc func cycleLaneHeight(_ sender: Any?) { editor.cycleLaneHeight() }
    @objc func selectPreviousTrack(_ sender: Any?) { editor.selectAdjacentTrack(by: -1) }
    @objc func selectNextTrack(_ sender: Any?) { editor.selectAdjacentTrack(by: 1) }
    @objc func toggleExpandTrack(_ sender: Any?) { editor.expandSelected.toggle() }

    /// Removes the selected track, asking first when it holds regions.
    @objc func removeTrack(_ sender: Any?) {
        let track = editor.selectedTrack
        guard let window, editor.project.tracks.count > 1 else { return }
        let count = editor.project.regions(onTrack: track.id).count
        guard count > 0 else {
            editor.removeTrack(track.id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove \(track.name)?"
        alert.informativeText = "Its \(count) region\(count == 1 ? "" : "s") will be removed with it. You can undo this."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        openAlert = alert
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                self.openAlert = nil
                if response == .alertFirstButtonReturn { self.editor.removeTrack(track.id) }
            }
        }
    }

    @objc func nextLoudnessReading(_ sender: Any?) {
        AppSettings.shared.loudnessMode = AppSettings.shared.loudnessMode.next
        timeline.loudnessMeter.refresh()
    }

    @objc func resetLoudness(_ sender: Any?) { editor.resetLoudness() }

    @objc func toggleSnapToZero(_ sender: Any?) {
        AppSettings.shared.snapToZeroCrossing.toggle()
        editor.needsDisplay?()
    }

    @objc func toggleInspector(_ sender: Any?) {
        setInspectorVisible(!isInspectorVisible)
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
        case #selector(nextLoudnessReading(_:)):
            item.title = "Loudness Reading: \(AppSettings.shared.loudnessMode.title)"
            return true
        case #selector(toggleOnlyTrack(_:)):
            item.state = editor.onlyTrack ? .on : .off
            return !editor.multitrack
        case #selector(toggleMultitrack(_:)):
            item.state = editor.multitrack ? .on : .off
            return true
        case #selector(toggleMagnetic(_:)):
            item.state = editor.selectedTrack.magnetic ? .on : .off
            return window?.attachedSheet == nil
        case #selector(addTrack(_:)):
            return !RecordController.shared.isRecording
        case #selector(selectPreviousTrack(_:)):
            return (editor.project.trackIndex(editor.selectedTrackID) ?? 0) > 0 && !RecordController.shared.isRecording
        case #selector(selectNextTrack(_:)):
            return (editor.project.trackIndex(editor.selectedTrackID) ?? 0) < editor.project.tracks.count - 1
                && !RecordController.shared.isRecording
        case #selector(removeTrack(_:)):
            return editor.project.tracks.count > 1 && !RecordController.shared.isRecording
        case #selector(cycleLaneHeight(_:)):
            item.title = "Lane Height: \(Int(editor.laneHeight)) pt"
            return editor.multitrack
        case #selector(toggleExpandTrack(_:)):
            item.state = editor.expandSelected ? .on : .off
            return editor.multitrack
        case #selector(deleteRegions(_:)):
            return !editor.selectedIDs.isEmpty
                || (editor.multitrack && editor.headerFocused && editor.project.tracks.count > 1 && !RecordController.shared.isRecording)
        case #selector(deleteRegionsLeavingGap(_:)), #selector(duplicateRegions(_:)),
             #selector(applyDefaultFades(_:)), #selector(showFadeDialog(_:)), #selector(nudgeLeft(_:)), #selector(nudgeRight(_:)):
            return !editor.selectedIDs.isEmpty
        case #selector(bladeRegions(_:)), #selector(selectAll(_:)):
            return !tapeDocument.project.regions.isEmpty
        case #selector(showExport(_:)), #selector(exportRegion(_:)), #selector(showExportEachRegion(_:)):
            return window?.attachedSheet == nil && !RecordController.shared.isRecording && !editor.project.regions.isEmpty
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
