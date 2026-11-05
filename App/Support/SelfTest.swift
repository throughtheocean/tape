import AppKit
import TapeCore

/// Scripted UI run, started with `-TapeSelfTest <script>`. Drives the front window through its
/// menu key equivalents and synthesized mouse events, logs state and renders snapshots offscreen,
/// so the UI can be exercised while no display is available. A test harness, not a user feature.
@MainActor
final class SelfTest {
    private let scriptPath: String
    private weak var app: AppDelegate?
    private var log = ""
    private let logURL = URL(fileURLWithPath: "/tmp/tape-selftest.log")

    init(scriptPath: String, app: AppDelegate) {
        self.scriptPath = scriptPath
        self.app = app
    }

    func run() {
        Task { @MainActor in
            do {
                let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
                for raw in script.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty || line.hasPrefix("#") { continue }
                    write("> \(line)")
                    try await execute(line)
                    // A real event per command, so undo groups close the way they do for user input.
                    if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApp.postEvent(e, atStart: false)
                    }
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
                write("done")
            } catch {
                write("error: \(error)")
            }
            flushLog()
        }
    }

    private var front: MainWindowController? {
        app?.controllers.first { $0.window === NSApp.mainWindow } ?? app?.controllers.last
    }

    private func write(_ s: String) {
        log += s + "\n"
        flushLog()
    }

    private func flushLog() {
        try? log.write(to: logURL, atomically: true, encoding: .utf8)
    }

    // MARK: Commands

    private func execute(_ line: String) async throws {
        let parts = line.split(separator: " ").map(String.init)
        let args = Array(parts.dropFirst())
        guard let c = front, let command = parts.first else { return }
        let editor = c.editor
        switch command {
        case "new":
            app?.newDocument(nil)
        case "import":
            c.importAudio(urls: args.map { URL(fileURLWithPath: $0) })
        case "wait":
            try await Task.sleep(nanoseconds: UInt64((Double(args.first ?? "1") ?? 1) * 1e9))
        case "waitLoaded":
            for _ in 0..<600 {
                let d = c.tapeDocument
                if d.loading.isEmpty, d.loaded.count + d.failures.count >= d.project.sources.count { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        case "key":
            key(args.joined(separator: " "), controller: c)
        case "menu":
            menu(title: args.joined(separator: " "), controller: c)
        case "mouse":
            mouse(args, controller: c)
        case "locate":
            editor.locate(frame(args[0], editor))
        case "view":
            editor.setView(start: Double(args[0]) ?? 0, samplesPerPoint: Double(args[1]) ?? 100)
        case "fit":
            editor.fitAll()
        case "tick":
            // Display link callbacks pause while the screen is locked; advance the playhead by hand.
            for _ in 0..<(Int(args.first ?? "1") ?? 1) {
                editor.tick()
                try await Task.sleep(nanoseconds: 16_000_000)
            }
        case "snapshot":
            snapshot(c, to: args[0])
        case "log":
            dump(c, label: args.joined(separator: " "))
        case "set":
            setting(args)
        case "quit":
            flushLog()
            NSApp.terminate(nil)
        default:
            write("unknown command \(command)")
        }
    }

    private func setting(_ args: [String]) {
        guard args.count == 2 else { return }
        let s = AppSettings.shared
        switch args[0] {
        case "snap": s.snapToZeroCrossing = args[1] == "on"
        case "preroll": RecordController.shared.setPreRoll(Double(args[1]) ?? 10)
        case "container": RecordController.shared.setContainer(AudioContainer(rawValue: args[1]) ?? .wav)
        case "depth": s.recordSampleFormat = SampleFormat(rawValue: args[1]) ?? .int24
        case "device":
            let r = RecordController.shared
            r.select(device: r.devices.first { $0.name.contains(args[1]) })
        default: write("unknown setting \(args[0])")
        }
    }

    /// `x` is points in the track view, or `f<frame>` for a timeline frame.
    private func frame(_ token: String, _ editor: EditorController) -> Int64 {
        Int64(token.hasPrefix("f") ? Double(token.dropFirst()) ?? 0 : editor.frame(forX: Double(token) ?? 0))
    }

    private func x(_ token: String, _ editor: EditorController) -> CGFloat {
        token.hasPrefix("f") ? CGFloat(editor.x(forFrame: Double(token.dropFirst()) ?? 0)) : CGFloat(Double(token) ?? 0)
    }

    /// `y` is points from the top of the track view, or a name: top (fade handle row), strip (region name),
    /// wave (middle of the waveform), minimap.
    private func y(_ token: String, _ view: NSView) -> CGFloat {
        let top = TimelineLayout.regionTop(view.bounds.height)
        let bottom = TimelineLayout.regionBottom(view.bounds.height)
        switch token {
        case "top": return top + 3
        case "strip": return top + TimelineLayout.nameStrip / 2
        case "wave": return (top + TimelineLayout.nameStrip + bottom) / 2
        case "minimap": return TimelineLayout.minimapHeight / 2
        default: return CGFloat(Double(token) ?? 0)
        }
    }

    private func modifiers(_ token: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for part in token.lowercased().split(separator: "+") {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "alt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        return flags
    }

    // MARK: Keys and menus

    private static let named: [String: String] = [
        "space": " ", "delete": "\u{8}", "fwddelete": String(Character(UnicodeScalar(UInt16(NSDeleteFunctionKey))!)),
        "home": String(Character(UnicodeScalar(UInt16(NSHomeFunctionKey))!)),
        "end": String(Character(UnicodeScalar(UInt16(NSEndFunctionKey))!)),
        "comma": ",", "period": ".",
    ]

    private func key(_ spec: String, controller: MainWindowController) {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last else { return }
        let char = Self.named[last] ?? last
        let mods = modifiers(parts.dropLast().joined(separator: "+"))
        let match: (NSMenuItem) -> Bool = { item in
            item.keyEquivalent.lowercased() == char
                && item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == mods
        }
        guard let item = findItem(NSApp.mainMenu, match) else {
            write("no menu item for key \(spec)")
            return
        }
        perform(item, controller: controller)
    }

    private func menu(title: String, controller: MainWindowController) {
        guard let item = findItem(NSApp.mainMenu, { $0.title == title }) else {
            write("no menu item \(title)")
            return
        }
        perform(item, controller: controller)
    }

    private func findItem(_ menu: NSMenu?, _ match: (NSMenuItem) -> Bool) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action != nil, match(item) { return item }
            if let found = findItem(item.submenu, match) { return found }
        }
        return nil
    }

    private func perform(_ item: NSMenuItem, controller: MainWindowController) {
        guard let action = item.action else { return }
        if controller.responds(to: action) {
            guard controller.validateMenuItem(item) else {
                write("disabled: \(item.title)")
                return
            }
            controller.perform(action, with: item)
            write("performed \(item.title)")
        } else if action == Selector(("undo:")) {
            controller.tapeDocument.undoManager.undo()
            write("performed Undo")
        } else if action == Selector(("redo:")) {
            controller.tapeDocument.undoManager.redo()
            write("performed Redo")
        } else if NSApp.sendAction(action, to: nil, from: item) {
            write("sent \(item.title)")
        } else {
            write("not handled: \(item.title)")
        }
    }

    // MARK: Mouse

    private func mouse(_ args: [String], controller: MainWindowController) {
        guard args.count >= 3, let window = controller.window else { return }
        let view = controller.timeline.metalView
        let p = NSPoint(x: x(args[1], controller.editor), y: y(args[2], view))
        let mods = args.count > 3 ? modifiers(args[3]) : []
        let clicks = args.count > 4 ? Int(args[4]) ?? 1 : 1
        let location = view.convert(p, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        switch args[0] {
        case "down": view.mouseDown(with: event(.leftMouseDown))
        case "drag": view.mouseDragged(with: event(.leftMouseDragged))
        case "up": view.mouseUp(with: event(.leftMouseUp))
        case "move": view.mouseMoved(with: event(.mouseMoved))
        case "click":
            view.mouseDown(with: event(.leftMouseDown))
            view.mouseUp(with: event(.leftMouseUp))
        case "right": view.rightMouseDown(with: event(.rightMouseDown))
        default: write("unknown mouse \(args[0])")
        }
    }

    // MARK: State

    private func dump(_ c: MainWindowController, label: String) {
        let e = c.editor, d = c.tapeDocument
        var s = "state \(label): playhead \(e.playhead) playing \(e.isPlaying) speed \(e.speed)"
        if let r = e.range { s += " range \(r.start)..<\(r.end)" }
        s += " regions \(d.project.regions.count) rate \(d.project.sessionRate ?? 0) length \(d.project.length)"
        s += " undo '\(d.undoManager.undoActionName)' redo '\(d.undoManager.redoActionName)' groupLevel \(d.undoManager.groupingLevel)"
        let rec = RecordController.shared
        s += " input \(rec.device?.name ?? "none") needsPermission \(rec.needsPermission) recording \(rec.isRecording)"
        if let err = rec.inputError { s += " inputError '\(err)'" }
        write(s)
        for (i, r) in d.project.regions.enumerated() {
            let sel = e.selection.contains(r.id) ? "*" : " "
            write(String(format: "  %@%d %@ pos %lld len %lld in %lld out %lld gain %.2f fadeIn %lld %@ %.2f fadeOut %lld %@ %.2f",
                         sel, i, r.name, r.position, r.length, r.sourceIn, r.sourceOut, r.gainDB,
                         r.fadeIn.length, r.fadeIn.shape.rawValue, r.fadeIn.blend, r.fadeOut.length, r.fadeOut.shape.rawValue, r.fadeOut.blend))
        }
    }

    private func snapshot(_ c: MainWindowController, to path: String) {
        guard let window = c.window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let size = content.bounds.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        func drawView(_ v: NSView) {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            guard let image = rep.cgImage else { return }
            let r = v.convert(v.bounds, to: content)
            ctx.draw(image, in: CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale))
        }
        drawView(content)
        let tl = c.timeline
        let metal = tl.metalView
        if let image = tl.renderer?.snapshot(size: CGSize(width: metal.bounds.width * scale, height: metal.bounds.height * scale), scale: scale) {
            let r = metal.convert(metal.bounds, to: content)
            ctx.draw(image, in: CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale))
        }
        drawView(tl.toolStrip)
        drawView(tl.ruler)
        tl.labels.update()
        if let layer = tl.labels.layer {
            let r = tl.labels.convert(tl.labels.bounds, to: content)
            ctx.saveGState()
            ctx.translateBy(x: r.minX * scale, y: r.maxY * scale)
            ctx.scaleBy(x: scale, y: -scale)
            layer.render(in: ctx)
            ctx.restoreGState()
        }
        guard let out = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: out)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        write("snapshot \(path)")
    }
}
