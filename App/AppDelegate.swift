import AppKit
import TapeCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controllers: [MainWindowController] = []
    private var benchmark: Benchmark?
    #if DEBUG
    private var selfTest: SelfTest?
    #endif
    private var launched = false
    /// Files handed over before launch finished; AppKit delivers them ahead of `applicationDidFinishLaunching`.
    private var pendingOpen: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.build()
        launched = true
        if let path = UserDefaults.standard.string(forKey: "TapeBenchmark") {
            benchmark = Benchmark(audioPath: path, app: self)
            benchmark?.start()
            return
        }
        // Documents open at the last quit or crash.
        for path in AppSettings.shared.openDocuments where !isScripted {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) {
                open(packageAt: url)
            }
        }
        if !pendingOpen.isEmpty {
            openURLs(pendingOpen)
            pendingOpen = []
        }
        if controllers.isEmpty { newDocument(nil) }
        RecordController.shared.start()
        #if DEBUG
        if let script = UserDefaults.standard.string(forKey: "TapeSelfTest") {
            selfTest = SelfTest(scriptPath: script, app: self)
            selfTest?.run()
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, controllers.isEmpty { newDocument(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecordController.shared.shutdown()
        rememberOpenDocuments()
        for c in controllers {
            c.editor.playback.shutdown()
            c.tapeDocument.flushSaves()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { openURLs(urls) } else { pendingOpen += urls }
    }

    // MARK: Documents

    @discardableResult
    func show(_ document: TapeDocument) -> MainWindowController {
        let controller = MainWindowController(document: document)
        controller.onClose = { [weak self] c in
            self?.controllers.removeAll { $0 === c }
            self?.rememberOpenDocuments()
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.focusTimeline()
        rememberOpenDocuments()
        return controller
    }

    /// Drops a scratch document without asking and without saving.
    func discard(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        controller.editor.playback.shutdown()
        controller.tapeDocument.flushSaves()
        controller.tapeDocument.deletePackage()
        controller.window?.orderOut(nil)
        rememberOpenDocuments()
    }

    /// A self-test run neither restores nor remembers open documents. Release builds have no self-test.
    private var isScripted: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "TapeSelfTest") != nil
        #else
        false
        #endif
    }

    func rememberOpenDocuments() {
        guard !isScripted else { return }
        AppSettings.shared.openDocuments = controllers.map { $0.tapeDocument.package.url.path }
    }

    @objc func newDocument(_ sender: Any?) {
        do {
            show(try TapeDocument.createUntitled())
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(exportedAs: "com.maikbluhm.tape.project"), .audio]
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        openURLs(panel.urls)
    }

    func openURLs(_ urls: [URL]) {
        let packages = urls.filter { $0.pathExtension.lowercased() == TapePackage.fileExtension }
        let audio = urls.filter { $0.pathExtension.lowercased() != TapePackage.fileExtension }
        packages.forEach { open(packageAt: $0) }
        guard !audio.isEmpty else { return }
        // Reuse a frontmost empty untitled document, otherwise start a new one.
        let front = controllers.first { $0.window != nil && $0.window === NSApp.mainWindow } ?? controllers.last
        if let front, front.tapeDocument.isUntitled, front.tapeDocument.isEmpty {
            front.importAudio(urls: audio)
        } else {
            do {
                show(try TapeDocument.createUntitled()).importAudio(urls: audio)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func open(packageAt url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = controllers.first(where: { $0.tapeDocument.package.url.standardizedFileURL.path == path }) {
            existing.showWindow(nil)
            return
        }
        do {
            show(try TapeDocument(package: TapePackage(url: url)))
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
