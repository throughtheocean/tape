import AVFoundation
import AppKit
import HardwarePresets
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
        case "button":
            switch args.first {
            case "sidebar": c.sidebarToggle.performClick(nil)
            case "select": c.timeline.sideBar.select.toggle()
            case "blade": c.timeline.sideBar.blade.toggle()
            case "snap": c.timeline.sideBar.snap.toggle()
            case "lanesize": c.timeline.sideBar.laneSize.action()
            case "expand": c.timeline.sideBar.expand.toggle()
            default: write("no button \(args.first ?? "")")
            }
        case "snapshot":
            snapshot(c, to: args[0])
        case "log":
            dump(c, label: args.joined(separator: " "))
        case "set":
            setting(args)
        case "sheet":
            sheet(args.first ?? "return", controller: c)
        case "preview":
            c.processSession?.setPreview(args.first == "on")
            write("preview \(c.processSession?.previewing == true ? "on" : "off") playing \(editor.isPlaying)")
        case "param":
            param(args, session: c.processSession)
        case "waitApply":
            for _ in 0..<600 {
                if c.processSession == nil || c.processSession?.isApplying == false { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            write("apply finished, sheet open \(c.window?.attachedSheet != nil) status '\(c.processSession?.status ?? "")'")
        case "measure":
            measure(c, label: args.joined(separator: " "))
        case "exportto":
            // A path with an extension is a file (its folder is created), otherwise a folder.
            let url = args.first.map { URL(fileURLWithPath: $0) }
            c.exportDestination = url
            if let url {
                let dir = url.pathExtension.isEmpty ? url : url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            write("export destination \(args.first ?? "panel")")
        case "export":
            exportSetting(args, session: c.exportSession)
        case "waitExport":
            for _ in 0..<1200 {
                if c.exportSession == nil || c.exportSession?.isExporting == false { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            write("export finished, sheet open \(c.window?.attachedSheet != nil) status '\(c.exportSession?.status ?? c.lastExportStatus)'")
        case "context":
            context(args, controller: c)
        case "fileinfo":
            for path in args { fileInfo(path) }
        case "files":
            let dir = args.first ?? "/tmp"
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            write("files in \(dir): \(names.count): \(names.joined(separator: ", "))")
        case "compare":
            compare(args, controller: c)
        case "header":
            header(args, controller: c)
        case "master":
            master(args, controller: c)
        case "meters":
            meters(c, label: args.joined(separator: " "))
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

    /// `f<frame>` may carry an offset in points, for example `f216000+5`.
    private func x(_ token: String, _ editor: EditorController) -> CGFloat {
        guard token.hasPrefix("f") else { return CGFloat(Double(token) ?? 0) }
        var body = token.dropFirst()
        var offset = 0.0
        if let i = body.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) {
            offset = Double(body[i...]) ?? 0
            body = body[..<i]
        }
        return CGFloat(editor.x(forFrame: Double(body) ?? 0) + offset)
    }

    /// `y` is points from the top of the track view, or a name: top (fade handle row), strip (region name),
    /// wave (middle of the waveform), minimap. Names refer to the selected track's lane, or to track N with `:N`
    /// (1 based), for example `wave:3`. A name may carry an offset in points, for example `wave-40`.
    private func y(_ token: String, _ editor: EditorController) -> CGFloat {
        var name = token
        var offset: CGFloat = 0
        var trackNumber: Int?
        if let colon = name.firstIndex(of: ":") {
            let rest = name[name.index(after: colon)...]
            let digits = rest.prefix { $0.isNumber }
            trackNumber = Int(digits)
            name = String(name[..<colon]) + rest.dropFirst(digits.count)
        }
        if let i = name.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) {
            offset = CGFloat(Double(name[i...]) ?? 0)
            name = String(name[..<i])
        }
        let tracks = editor.project.tracks
        let id = trackNumber.map { tracks[min(max($0 - 1, 0), tracks.count - 1)].id } ?? editor.selectedTrackID
        let lane = editor.lane(for: id) ?? editor.lanes()[0]
        let top = CGFloat(lane.bodyTop), bottom = CGFloat(lane.bodyBottom)
        switch name {
        case "top": return CGFloat(lane.waveTop) + offset
        case "strip": return top + CGFloat(lane.strip) / 2 + offset
        case "wave": return (CGFloat(lane.waveTop) + bottom) / 2 + offset
        case "below": return bottom + 4 + offset
        case "minimap": return TimelineLayout.minimapHeight / 2 + offset
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

    private func param(_ args: [String], session: ProcessSession?) {
        guard let session, args.count == 2, let v = Double(args[1]) else {
            write("param needs an open process sheet, a name and a value")
            return
        }
        let paths: [String: WritableKeyPath<ProcessParameters, Double>] = [
            "lufs": \.lufsTarget, "ceiling": \.truePeakCeiling, "peak": \.peakTarget, "gain": \.gainDB,
            "threshold": \.compThreshold, "pregain": \.limPreGain, "silence": \.silenceThreshold, "hold": \.silenceHoldMs,
            "rate": \.resampleRate,
        ]
        if args[0] == "mode" {
            session.parameters.loudnessMode = args[1] != "0"
        } else if let path = paths[args[0]] {
            session.parameters[keyPath: path] = v
        } else {
            write("unknown param \(args[0])")
            return
        }
        write("param \(args[0]) = \(args[1])")
    }

    /// `export preset <id|none>`, `export scope <kind>`, `export format <container> <int16|int24|float32> <rate> <layout>`,
    /// `export pattern <text>`, `export dither on|off`, `export state`.
    private func exportSetting(_ args: [String], session: ExportSession?) {
        guard let session, let what = args.first else {
            write("export needs an open export sheet")
            return
        }
        switch what {
        case "preset":
            session.applyPreset(args.count > 1 ? ExportPreset.preset(for: args[1]) : nil)
        case "scope":
            if let kind = ExportScopeKind(rawValue: args.count > 1 ? args[1] : ""), session.availableScopes.contains(kind) {
                session.scope = kind
            } else {
                write("scope not available: \(args.dropFirst().joined()) (have \(session.availableScopes.map(\.rawValue)))")
            }
        case "format" where args.count == 5:
            session.settings = ExportSettings(container: AudioContainer(rawValue: args[1]) ?? .wav,
                                              sampleFormat: SampleFormat(rawValue: args[2]) ?? .int24,
                                              sampleRate: Double(args[3]) ?? 48000, layout: ChannelLayout(rawValue: args[4]) ?? .session)
        case "pattern":
            let pattern = args.dropFirst().joined(separator: " ")
            if session.scope == .stems { session.stemPattern = pattern } else { session.pattern = pattern }
        case "dither":
            session.settings.dither = args.count > 1 && args[1] == "on"
        case "state":
            break
        default:
            write("unknown export setting \(what)")
            return
        }
        let s = session.settings
        write("export: preset \(session.preset?.id ?? "none") locked \(session.isLocked) scope \(session.scope.rawValue) "
              + "\(s.container.rawValue) \(s.sampleFormat.rawValue) \(Int(s.sampleRate)) \(s.layout.rawValue) dither \(s.dither) "
              + "pattern '\(session.pattern)' summary '\(session.summary)' problem '\(session.problem ?? "")'")
    }

    /// `context <x> <y> [item title]`: opens the timeline context menu there and performs the item.
    private func context(_ args: [String], controller c: MainWindowController) {
        guard args.count >= 2, let window = c.window else { return }
        let view = c.timeline.metalView
        let p = NSPoint(x: x(args[0], c.editor), y: y(args[1], c.editor))
        guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(p, to: nil), modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let menu = view.menu(for: e) else {
            write("no context menu")
            return
        }
        write("context menu: \(menu.items.map(\.title))")
        let title = args.dropFirst(2).joined(separator: " ")
        if !title.isEmpty, let item = menu.items.first(where: { $0.title == title }) { perform(item, controller: c) }
    }

    private func fileInfo(_ path: String) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            write("fileinfo \(path): cannot open")
            return
        }
        let d = file.fileFormat.streamDescription.pointee
        let codec = d.mFormatID == kAudioFormatLinearPCM ? ((d.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "float" : "int")
            : d.mFormatID == kAudioFormatFLAC ? "flac" : d.mFormatID == kAudioFormatAppleLossless ? "alac"
            : d.mFormatID == kAudioFormatMPEG4AAC ? "aac" : "other"
        let alacBits: [UInt32: UInt32] = [1: 16, 2: 20, 3: 24, 4: 32]
        let bits = d.mBitsPerChannel > 0 ? d.mBitsPerChannel : d.mFormatID == kAudioFormatAppleLossless ? alacBits[d.mFormatFlags] ?? 0 : 0
        write("fileinfo \((path as NSString).lastPathComponent): \(codec) \(bits) bit \(Int(d.mSampleRate)) Hz \(d.mChannelsPerFrame) ch \(file.length) frames")
    }

    /// `compare <file> [region]`: the file against the edit list render (whole document, or the selected region alone).
    private func compare(_ args: [String], controller c: MainWindowController) {
        guard let path = args.first, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            write("compare: cannot open \(args.first ?? "")")
            return
        }
        var list = c.tapeDocument.editList()
        var span = SampleRange(start: 0, end: list.length)
        if args.count > 1, args[1] == "region", let r = c.editor.selectedRegions.first {
            list = list.with(regions: [r])
            span = r.timelineRange
        }
        if args.count > 2, args[1] == "stem", let n = Int(args[2]), n >= 1, n <= c.editor.project.tracks.count {
            list = list.stem(c.editor.project.tracks[n - 1].id)
            span = SampleRange(start: 0, end: c.tapeDocument.editList().length)
        }
        let n = Int(span.length)
        let out = SampleBuffer(channelCount: list.channelCount, capacity: max(n, 1))
        EditListRenderer().render(list, start: span.start, frames: n, into: out)
        let expected = out.toArrays(count: n)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1)))!
        try? file.readFully(into: buffer, frameCount: AVAudioFrameCount(file.length))
        var maxDiff: Float = 0
        for ch in 0..<min(Int(buffer.format.channelCount), expected.count) {
            for i in 0..<min(Int(buffer.frameLength), n) { maxDiff = max(maxDiff, abs(buffer.floatChannelData![ch][i] - expected[ch][i])) }
        }
        write("compare \((path as NSString).lastPathComponent): \(buffer.frameLength) frames vs \(n) rendered, max difference \(maxDiff)")
    }

    /// Renders the range, else the selected regions' span, else the whole document, and logs loudness and peaks.
    private func measure(_ c: MainWindowController, label: String) {
        let e = c.editor
        let selected = e.selectedRegions.map(\.timelineRange)
        let span = e.range
            ?? (selected.isEmpty ? nil : SampleRange(start: selected.map(\.start).min()!, end: selected.map(\.end).max()!))
            ?? SampleRange(start: 0, end: e.documentLength)
        guard !span.isEmpty else { return }
        let list = c.tapeDocument.editList()
        let out = SampleBuffer(channelCount: list.channelCount, capacity: Int(span.length))
        EditListRenderer().render(list, start: span.start, frames: Int(span.length), into: out)
        let buffer = AudioBuffer(channels: out.toArrays(count: Int(span.length)), sampleRate: e.sessionRate)
        let mean = buffer.channels[0].reduce(0, +) / Float(max(1, buffer.frameCount))
        write(String(format: "measure %@: %.3f LUFS, peak %.3f dBFS, true peak %.3f dBTP, mean %.5f over %lld frames", label,
                     Loudness.integrated(buffer), 20 * log10(Double(buffer.peak())), Loudness.truePeakDB(buffer), mean, span.length))
    }

    /// Presses Return or Escape in the attached sheet, or reports that none is open.
    private func sheet(_ key: String, controller: MainWindowController) {
        guard let sheet = controller.window?.attachedSheet else {
            write("no sheet")
            return
        }
        let chars = key == "escape" ? "\u{1b}" : "\r"
        let code: UInt16 = key == "escape" ? 53 : 36
        let alertButton = key == "escape" ? controller.openAlert?.buttons.last : controller.openAlert?.buttons.first
        if let button = alertButton ?? findButton(sheet.contentView, keyEquivalent: chars) {
            button.performClick(nil)
            write("sheet \(key) clicked '\(button.title)', sheet open \(controller.window?.attachedSheet != nil)")
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: sheet.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                sheet.sendEvent(e)
            }
        }
        write("sheet \(key) sent, sheet open \(controller.window?.attachedSheet != nil)")
    }

    /// AppKit buttons (NSAlert) take a click; SwiftUI sheets get key events instead.
    private func findButton(_ view: NSView?, keyEquivalent: String) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton, b.keyEquivalent == keyEquivalent { return b }
        for sub in view.subviews {
            if let b = findButton(sub, keyEquivalent: keyEquivalent) { return b }
        }
        return nil
    }

    // MARK: Mouse

    private func mouse(_ args: [String], controller: MainWindowController) {
        guard args.count >= 3, let window = controller.window else { return }
        let view = controller.timeline.metalView
        let p = NSPoint(x: x(args[1], controller.editor), y: y(args[2], controller.editor))
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
        s += " tool \(e.tool) sheet \(c.window?.attachedSheet != nil) sources \(d.project.sources.count) unused \(d.unusedSources.count) orphans \(d.cleanUpPreview().files)"
        s += " inspector \(c.isInspectorVisible) timelineHeight \(Int(c.timeline.bounds.height)) snap \(AppSettings.shared.snapToZeroCrossing)"
        if let alert = c.openAlert { s += " alert '\(alert.messageText)'" }
        if let responder = c.window?.firstResponder { s += " focus \(type(of: responder))" }
        write(s)
        for (i, r) in d.project.regions.enumerated() {
            let sel = e.selection.contains(r.id) ? "*" : " "
            let track = d.project.tracks.count > 1 ? " track \((d.project.trackIndex(r.trackId) ?? -1) + 1)" : ""
            write(String(format: "  %@%d %@ pos %lld len %lld in %lld out %lld gain %.2f fadeIn %lld %@ %.2f fadeOut %lld %@ %.2f",
                         sel, i, r.name, r.position, r.length, r.sourceIn, r.sourceOut, r.gainDB,
                         r.fadeIn.length, r.fadeIn.shape.rawValue, r.fadeIn.blend, r.fadeOut.length, r.fadeOut.shape.rawValue, r.fadeOut.blend)
                  + track)
        }
        guard e.multitrack || d.project.tracks.count > 1 else { return }
        write(String(format: "  view %@ selectedTrack %d headerFocused %@ laneHeight %.0f expand %@ laneScroll %.0f master %.2f",
                     e.multitrack ? "multi" : "single", (d.project.trackIndex(e.selectedTrackID) ?? -1) + 1,
                     e.headerFocused ? "true" : "false", e.laneHeight, e.expandSelected ? "true" : "false", e.laneScroll,
                     d.project.master.gainDB))
        for (i, t) in d.project.tracks.enumerated() {
            let lane = e.lane(for: t.id).map { String(format: "%.0f+%.0f", $0.top, $0.height) } ?? "hidden"
            write(String(format: "  T%d %@ color %d gain %.2f pan %.2f mute %@ solo %@ regions %d lane %@",
                         i + 1, t.name, t.color, t.gainDB, t.pan, t.mute ? "true" : "false", t.solo ? "true" : "false",
                         d.project.regions(onTrack: t.id).count, lane))
        }
    }

    /// `header <track> <down|drag|up|click|double> <zone>[@fraction][+dy|-dy]`: mouse on a track header.
    /// Zones: name, swatch, mute, solo, gain, pan, meter, body. The fraction places x along a slider.
    private func header(_ args: [String], controller c: MainWindowController) {
        guard args.count >= 3, let n = Int(args[0]), n >= 1, n <= c.editor.project.tracks.count else {
            write("header: bad arguments")
            return
        }
        let id = c.editor.project.tracks[n - 1].id
        c.timeline.headers.refresh()
        guard let view = c.timeline.headers.header(for: id) else {
            write("header: track \(n) not shown")
            return
        }
        var spec = args[2]
        var dy: CGFloat = 0
        if let i = spec.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) {
            dy = CGFloat(Double(spec[i...]) ?? 0)
            spec = String(spec[..<i])
        }
        let parts = spec.split(separator: "@")
        let fraction = parts.count > 1 ? Double(parts[1]) : nil
        var p = view.point(zone: String(parts[0]), fraction: fraction)
        p.y += dy
        let location = view.convert(p, to: nil)
        func event(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: c.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
                               pressure: 1)!
        }
        switch args[1] {
        case "down": view.mouseDown(with: event(.leftMouseDown))
        case "drag": view.mouseDragged(with: event(.leftMouseDragged))
        case "up": view.mouseUp(with: event(.leftMouseUp))
        case "click":
            view.mouseDown(with: event(.leftMouseDown))
            view.mouseUp(with: event(.leftMouseUp))
        case "double":
            view.mouseDown(with: event(.leftMouseDown, clicks: 2))
            view.mouseUp(with: event(.leftMouseUp, clicks: 2))
        default: write("header: unknown action \(args[1])")
        }
    }

    /// `master <add|gain@fraction|double>`: the master strip.
    private func master(_ args: [String], controller c: MainWindowController) {
        let view = c.timeline.headers.master
        let spec = args.first ?? ""
        let parts = spec.split(separator: "@")
        let p = view.point(zone: String(parts[0]), fraction: parts.count > 1 ? Double(parts[1]) : nil)
        let location = view.convert(p, to: nil)
        func event(_ type: NSEvent.EventType, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: c.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
                               pressure: 1)!
        }
        let clicks = args.count > 1 && args[1] == "double" ? 2 : 1
        view.mouseDown(with: event(.leftMouseDown, clicks: clicks))
        view.mouseUp(with: event(.leftMouseUp, clicks: clicks))
    }

    /// Logs the meters as the header column shows them.
    private func meters(_ c: MainWindowController, label: String) {
        let e = c.editor
        var s = "meters \(label):"
        for (i, t) in e.project.tracks.enumerated() {
            let m = e.trackMeters[t.id] ?? MeterBallistics()
            s += String(format: " T%d %.1f/%.1f%@", i + 1, m.levelDB, m.holdDB, m.clipped ? " clip" : "")
        }
        s += " master"
        for m in e.masterMeters { s += String(format: " %.1f/%.1f%@", m.levelDB, m.holdDB, m.clipped ? " clip" : "") }
        write(s)
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
        drawView(tl.sideBar)
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
