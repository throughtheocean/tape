import AppKit
import TapeCore

/// Gain fader law: position is the cube root of amplitude relative to +12 dB, so 0 dB sits near two thirds.
enum Fader {
    private static let maxAmplitude = pow(10, Track.maxGainDB / 20)

    static func position(dB: Double) -> Double {
        guard dB > Track.silentDB else { return 0 }
        return min(1, cbrt(pow(10, dB / 20) / maxAmplitude))
    }

    static func dB(position: Double) -> Double {
        guard position > 0.002 else { return Track.silentDB }
        let dB = 20 * log10(pow(min(position, 1), 3) * maxAmplitude)
        return min(max(dB, Track.silentDB), Track.maxGainDB)
    }

    static func text(_ dB: Double) -> String {
        if dB <= Track.silentDB { return "-inf" }
        if abs(dB) < 0.05 { return "0.0" }
        return String(format: "%+.1f", dB)
    }

    static func panText(_ pan: Double) -> String {
        let v = Int((abs(pan) * 100).rounded())
        if v == 0 { return "C" }
        return (pan < 0 ? "L" : "R") + "\(v)"
    }

    static let colorNames = ["Accent", "Orange", "Green", "Purple", "Red", "Yellow", "Teal", "Pink"]
}

/// Draws the small controls shared by track headers and the master strip.
@MainActor
enum HeaderDrawing {
    static func slider(_ rect: NSRect, position: Double, color: NSColor, centered: Bool, mark: Double?) {
        let mid = rect.midY
        let x0 = rect.minX + 4, x1 = rect.maxX - 4
        let x = x0 + (x1 - x0) * CGFloat(min(max(position, 0), 1))
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: x0, y: mid - 1, width: x1 - x0, height: 2), xRadius: 1, yRadius: 1).fill()
        if let mark {
            NSColor(white: 1, alpha: 0.3).setFill()
            NSRect(x: (x0 + (x1 - x0) * CGFloat(mark)).rounded() - 0.5, y: mid - 4, width: 1, height: 8).fill()
        }
        let from = centered ? (x0 + x1) / 2 : x0
        color.withAlphaComponent(0.85).setFill()
        NSRect(x: min(from, x), y: mid - 1, width: abs(x - from), height: 2).fill()
        NSColor(white: 0.92, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 4.5, y: mid - 4.5, width: 9, height: 9)).fill()
    }

    static func text(_ s: String, in rect: NSRect, size: CGFloat = 10, color: NSColor = Theme.secondaryText,
                     align: NSTextAlignment = .left, weight: NSFont.Weight = .regular, mono: Bool = true) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let font = mono ? Theme.monoDigits(size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let h = font.ascender - font.descender
        (s as NSString).draw(with: NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    static func toggle(_ rect: NSRect, _ title: String, on: Bool, color: NSColor) {
        (on ? color : NSColor(white: 1, alpha: 0.08)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        text(title, in: rect, size: 10, color: on ? NSColor(white: 0, alpha: 0.85) : Theme.secondaryText, align: .center,
             weight: .semibold, mono: false)
    }

    /// Vertical or horizontal peak meter, -60 to 0 dB, with hold line and clip latch at the far end.
    static func meter(_ rect: NSRect, levelDB: Double, holdDB: Double, clipped: Bool, vertical: Bool) {
        NSColor(white: 1, alpha: 0.06).setFill()
        rect.fill()
        func norm(_ dB: Double) -> CGFloat {
            CGFloat(min(max((dB - MeterBallistics.floorDB) / -MeterBallistics.floorDB, 0), 1))
        }
        let clipSize: CGFloat = 3
        let span = (vertical ? rect.height : rect.width) - clipSize - 1
        let level = norm(levelDB) * span
        let warn = norm(-6) * span
        func part(_ a: CGFloat, _ b: CGFloat) -> NSRect {
            vertical ? NSRect(x: rect.minX, y: rect.maxY - b, width: rect.width, height: b - a)
                : NSRect(x: rect.minX + a, y: rect.minY, width: b - a, height: rect.height)
        }
        if level > 0 {
            NSColor(hex: 0x5DBB63).setFill()
            part(0, min(level, warn)).fill()
            if level > warn {
                NSColor(hex: 0xD9C44A).setFill()
                part(warn, level).fill()
            }
        }
        if holdDB > MeterBallistics.floorDB {
            let h = norm(holdDB) * span
            NSColor(white: 1, alpha: 0.7).setFill()
            part(max(0, h - 1), h).fill()
        }
        (clipped ? NSColor(hex: 0xE05D5D) : NSColor(white: 1, alpha: 0.1)).setFill()
        part(span + 1, span + 1 + clipSize).fill()
    }
}

/// Left column of the multitrack view: one header per lane, master strip at the bottom.
@MainActor
final class TrackHeaderColumn: NSView {
    let editor: EditorController
    private let clip = FlippedView()
    private var headers: [UUID: TrackHeaderView] = [:]
    let master: MasterStripView
    private let dropLine = CALayer()
    private var reorder: (id: UUID, from: Int, slot: Int)?

    init(editor: EditorController) {
        self.editor = editor
        master = MasterStripView(editor: editor)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.chrome.cgColor
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        addSubview(clip)
        addSubview(master)
        dropLine.backgroundColor = Theme.accent.cgColor
        dropLine.isHidden = true
        clip.layer?.addSublayer(dropLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Origin of the column is the top of the lane area in the Metal view.
    func refresh() {
        let viewport = editor.laneViewport
        let w = bounds.width
        clip.frame = NSRect(x: 0, y: 0, width: w, height: max(0, viewport.bottom - viewport.top))
        master.frame = NSRect(x: 0, y: bounds.height - EditorController.masterStripHeight, width: w,
                              height: EditorController.masterStripHeight)
        let lanes = editor.lanes()
        let anySolo = editor.project.tracks.contains { $0.solo }
        var seen = Set<UUID>()
        for lane in lanes {
            let id = lane.track.id
            seen.insert(id)
            let header = headers[id] ?? {
                let h = TrackHeaderView(column: self, trackID: id)
                clip.addSubview(h)
                headers[id] = h
                return h
            }()
            let frame = NSRect(x: 0, y: lane.top - viewport.top, width: w, height: lane.height)
            if header.frame != frame { header.frame = frame }
            let meter = editor.trackMeters[id] ?? MeterBallistics()
            header.update(TrackHeaderView.State(
                track: lane.track, selected: id == editor.selectedTrackID,
                focused: id == editor.selectedTrackID && editor.headerFocused,
                silenced: lane.track.mute || (anySolo && !lane.track.solo),
                level: Int((meter.levelDB * 4).rounded()), hold: Int((meter.holdDB * 4).rounded()), clipped: meter.clipped))
        }
        for (id, h) in headers where !seen.contains(id) {
            h.removeFromSuperview()
            headers[id] = nil
        }
        master.refresh()
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        editor.scrollLanes(by: -Double(dy))
    }

    func header(for id: UUID) -> TrackHeaderView? { headers[id] }

    // MARK: Reorder

    func beginReorder(_ id: UUID) {
        guard let i = editor.project.trackIndex(id) else { return }
        reorder = (id, i, i)
    }

    func updateReorder(y: CGFloat) {
        guard var r = reorder else { return }
        let lanes = editor.lanes()
        let top = editor.laneViewport.top
        var slot = lanes.count
        for lane in lanes where Double(y) < lane.top - top + lane.height / 2 {
            slot = lane.index
            break
        }
        r.slot = slot
        reorder = r
        let lineY = slot < lanes.count ? lanes[slot].top - top : (lanes.last.map { $0.bottom - top } ?? 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropLine.isHidden = slot == r.from || slot == r.from + 1
        dropLine.frame = CGRect(x: 0, y: lineY - 1, width: bounds.width, height: 2)
        CATransaction.commit()
        if Double(y) < 0 { editor.scrollLanes(by: Double(y) / 4) }
        if Double(y) > Double(clip.bounds.height) { editor.scrollLanes(by: (Double(y) - Double(clip.bounds.height)) / 4) }
    }

    func endReorder() {
        dropLine.isHidden = true
        guard let r = reorder else { return }
        reorder = nil
        let target = r.slot > r.from ? r.slot - 1 : r.slot
        if target != r.from { editor.moveTrack(r.id, to: target) }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One track's header: swatch, name, magnetic, mute, solo, gain, pan and a thin peak meter on the right edge.
@MainActor
final class TrackHeaderView: NSView, NSTextFieldDelegate {
    struct State: Equatable {
        var track: Track
        var selected: Bool
        var focused: Bool
        var silenced: Bool
        var level: Int
        var hold: Int
        var clipped: Bool
    }

    private unowned let column: TrackHeaderColumn
    let trackID: UUID
    private var state: State?
    private var editor: EditorController { column.editor }

    private enum Drag { case gain, pan, reorder(downY: CGFloat, started: Bool) }
    private var drag: Drag?
    private var nameField: NSTextField?

    init(column: TrackHeaderColumn, trackID: UUID) {
        self.column = column
        self.trackID = trackID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ next: State) {
        guard next != state else { return }
        state = next
        needsDisplay = true
    }

    private struct Zones {
        var swatch, name, magnet, mute, solo, gain, gainText, pan, panText, meter: NSRect
    }

    private var zones: Zones {
        let w = bounds.width
        let r1: CGFloat = 5
        let r2: CGFloat = bounds.height >= 60 ? 30 : 22
        let solo = NSRect(x: w - 28, y: r1, width: 18, height: 15)
        let mute = NSRect(x: w - 48, y: r1, width: 18, height: 15)
        let magnet = NSRect(x: w - 68, y: r1, width: 18, height: 15)
        return Zones(swatch: NSRect(x: 8, y: r1 + 3, width: 9, height: 9),
                     name: NSRect(x: 22, y: r1, width: magnet.minX - 26, height: 15),
                     magnet: magnet, mute: mute, solo: solo,
                     gain: NSRect(x: 4, y: r2, width: 68, height: 15),
                     gainText: NSRect(x: 72, y: r2, width: 32, height: 15),
                     pan: NSRect(x: 106, y: r2, width: 38, height: 15),
                     panText: NSRect(x: 146, y: r2, width: 24, height: 15),
                     meter: NSRect(x: w - 6, y: 3, width: 3, height: max(4, bounds.height - 7)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = state else { return }
        let z = zones
        let color = Theme.trackColor(s.track.color)
        (s.selected ? NSColor(white: 0.17, alpha: 1) : Theme.chrome).setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        if s.focused {
            Theme.accent.setFill()
            NSRect(x: 0, y: 0, width: 2, height: bounds.height - 1).fill()
        }
        color.setFill()
        NSBezierPath(roundedRect: z.swatch, xRadius: 2, yRadius: 2).fill()
        if nameField == nil {
            HeaderDrawing.text(s.track.name, in: z.name, size: 12, color: s.silenced ? Theme.secondaryText : Theme.primaryText,
                               weight: .medium, mono: false)
        }
        (s.track.magnetic ? Theme.accent : NSColor(white: 1, alpha: 0.08)).setFill()
        NSBezierPath(roundedRect: z.magnet, xRadius: 3, yRadius: 3).fill()
        MagnetIcon.image(size: 10, on: s.track.magnetic)
            .draw(in: NSRect(x: z.magnet.midX - 5, y: z.magnet.midY - 5, width: 10, height: 10), from: .zero,
                  operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        HeaderDrawing.toggle(z.mute, "M", on: s.track.mute, color: NSColor(hex: 0xE8913A))
        HeaderDrawing.toggle(z.solo, "S", on: s.track.solo, color: NSColor(hex: 0xD9C44A))
        HeaderDrawing.slider(z.gain, position: Fader.position(dB: s.track.gainDB), color: color, centered: false,
                             mark: Fader.position(dB: 0))
        HeaderDrawing.text(Fader.text(s.track.gainDB), in: z.gainText, align: .right)
        HeaderDrawing.slider(z.pan, position: (s.track.pan + 1) / 2, color: color, centered: true, mark: 0.5)
        HeaderDrawing.text(Fader.panText(s.track.pan), in: z.panText, align: .center)
        HeaderDrawing.meter(z.meter, levelDB: Double(s.level) / 4, holdDB: Double(s.hold) / 4, clipped: s.clipped, vertical: true)
    }

    /// Centre of a named zone, or a point along a slider (self-test).
    func point(zone: String, fraction: Double?) -> NSPoint {
        let z = zones
        let rect: NSRect
        switch zone {
        case "name": rect = z.name
        case "swatch": rect = z.swatch
        case "magnet": rect = z.magnet
        case "mute": rect = z.mute
        case "solo": rect = z.solo
        case "gain": rect = z.gain
        case "pan": rect = z.pan
        case "meter": rect = z.meter
        default: return NSPoint(x: bounds.midX, y: bounds.height - 6)
        }
        guard let fraction else { return NSPoint(x: rect.midX, y: rect.midY) }
        return NSPoint(x: rect.minX + 4 + (rect.width - 8) * CGFloat(fraction), y: rect.midY)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let z = zones
        let doc = editor.document
        guard let track = editor.project.track(trackID) else { return }
        editor.selectTrack(trackID, header: true)
        if nameField == nil, window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
        if z.magnet.insetBy(dx: -1, dy: -3).contains(p) {
            editor.toggleMagnetic(trackID)
        } else if z.mute.insetBy(dx: -2, dy: -3).contains(p) {
            editor.updateTrack(track.mute ? "Unmute" : "Mute", trackID) { $0.mute.toggle() }
        } else if z.solo.insetBy(dx: -2, dy: -3).contains(p) {
            editor.updateTrack(track.solo ? "Unsolo" : "Solo", trackID) { $0.solo.toggle() }
        } else if z.swatch.insetBy(dx: -4, dy: -4).contains(p) {
            showColorMenu(at: p, current: track.color)
        } else if z.gain.contains(p) || z.gainText.contains(p) {
            if event.clickCount == 2 {
                editor.updateTrack("Reset Gain", trackID) { $0.gainDB = 0 }
                return
            }
            doc.beginGesture()
            drag = .gain
            setGain(at: p)
        } else if z.pan.contains(p) || z.panText.contains(p) {
            if event.clickCount == 2 {
                editor.updateTrack("Reset Pan", trackID) { $0.pan = 0 }
                return
            }
            doc.beginGesture()
            drag = .pan
            setPan(at: p)
        } else if z.meter.insetBy(dx: -3, dy: 0).contains(p) {
            editor.resetClips()
        } else if event.clickCount == 2, z.name.contains(p) {
            beginRename()
        } else {
            drag = .reorder(downY: p.y, started: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .gain: setGain(at: p)
        case .pan: setPan(at: p)
        case let .reorder(downY, started):
            if !started {
                guard abs(p.y - downY) >= 4 else { return }
                column.beginReorder(trackID)
                drag = .reorder(downY: downY, started: true)
            }
            column.updateReorder(y: convert(p, to: column).y)
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .gain: editor.document.endGesture("Track Gain")
        case .pan: editor.document.endGesture("Track Pan")
        case let .reorder(_, started): if started { column.endReorder() }
        case nil: break
        }
        drag = nil
    }

    private func setGain(at p: NSPoint) {
        let r = zones.gain
        let v = Double((p.x - r.minX - 4) / (r.width - 8))
        var dB = Fader.dB(position: v)
        if abs(dB) < 0.3 { dB = 0 }
        let id = trackID
        editor.document.updateGesture { EditOperations.updateTrack(&$0, id: id) { $0.gainDB = dB } }
    }

    private func setPan(at p: NSPoint) {
        let r = zones.pan
        var pan = Double((p.x - r.minX - 4) / (r.width - 8)) * 2 - 1
        if abs(pan) < 0.04 { pan = 0 }
        pan = (min(max(pan, -1), 1) * 100).rounded() / 100
        let id = trackID
        editor.document.updateGesture { EditOperations.updateTrack(&$0, id: id) { $0.pan = pan } }
    }

    // MARK: Color

    private func showColorMenu(at p: NSPoint, current: Int) {
        let menu = NSMenu()
        for i in 0..<Track.paletteCount {
            let item = NSMenuItem(title: Fader.colorNames[i], action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == current ? .on : .off
            let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                Theme.trackColor(i).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
                return true
            }
            item.image = image
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: zones.swatch.minX, y: zones.swatch.maxY + 4), in: self)
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        let color = sender.tag
        editor.updateTrack("Track Color", trackID) { $0.color = color }
    }

    // MARK: Rename

    func beginRename() {
        guard nameField == nil, let track = editor.project.track(trackID) else { return }
        let field = NSTextField(string: track.name)
        field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: 0.1, alpha: 1)
        field.textColor = Theme.primaryText
        field.focusRingType = .none
        field.delegate = self
        field.frame = zones.name.insetBy(dx: -2, dy: -1)
        addSubview(field)
        nameField = field
        needsDisplay = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { endRename(commit: true) }

    private func endRename(commit: Bool) {
        guard let field = nameField else { return }
        nameField = nil
        let name = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        if commit { editor.renameTrack(trackID, to: name) }
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }
}

/// Bottom of the header column: add track button, master gain and stereo meter.
@MainActor
final class MasterStripView: NSView {
    let editor: EditorController
    private var drawn: [Int]?
    private var dragging = false

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Centre of `add` or `gain`, with a fraction along the gain slider (self-test).
    func point(zone: String, fraction: Double?) -> NSPoint {
        guard zone == "gain" else { return NSPoint(x: addRect.midX, y: addRect.midY) }
        guard let fraction else { return NSPoint(x: gainRect.midX, y: gainRect.midY) }
        return NSPoint(x: gainRect.minX + 4 + (gainRect.width - 8) * CGFloat(fraction), y: gainRect.midY)
    }

    private var addRect: NSRect { NSRect(x: bounds.width - 30, y: 6, width: 22, height: 18) }
    private var gainRect: NSRect { NSRect(x: 4, y: 28, width: 120, height: 15) }
    private var gainText: NSRect { NSRect(x: 124, y: 28, width: 40, height: 15) }
    private func meterRect(_ c: Int) -> NSRect { NSRect(x: 8, y: 48 + CGFloat(c) * 5, width: bounds.width - 16, height: 3) }

    func refresh() {
        let m = editor.masterMeters
        var key = [Int((editor.project.master.gainDB * 100).rounded()), editor.project.mixChannelCount]
        for c in m { key += [Int((c.levelDB * 4).rounded()), Int((c.holdDB * 4).rounded()), c.clipped ? 1 : 0] }
        guard key != drawn else { return }
        drawn = key
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        HeaderDrawing.text("Master", in: NSRect(x: 8, y: 6, width: 100, height: 18), size: 12, color: Theme.primaryText,
                           weight: .medium, mono: false)
        NSColor(white: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: addRect, xRadius: 4, yRadius: 4).fill()
        HeaderDrawing.text("+", in: addRect, size: 14, color: Theme.primaryText, align: .center, mono: false)
        let gain = editor.project.master.gainDB
        HeaderDrawing.slider(gainRect, position: Fader.position(dB: gain), color: Theme.accent, centered: false,
                             mark: Fader.position(dB: 0))
        HeaderDrawing.text(Fader.text(gain), in: gainText, align: .right)
        let channels = editor.project.mixChannelCount >= 2 ? 2 : 1
        for c in 0..<channels {
            let m = editor.masterMeters[c]
            HeaderDrawing.meter(meterRect(c), levelDB: m.levelDB, holdDB: m.holdDB, clipped: m.clipped, vertical: false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if addRect.insetBy(dx: -2, dy: -2).contains(p) {
            editor.addTrack()
        } else if gainRect.contains(p) || gainText.contains(p) {
            if event.clickCount == 2 {
                editor.document.apply("Reset Master Gain") { EditOperations.setMasterGain(&$0, dB: 0) }
                return
            }
            editor.document.beginGesture()
            dragging = true
            setGain(at: p)
        } else if p.y >= 46 {
            editor.resetClips()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        setGain(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        editor.document.endGesture("Master Gain")
    }

    private func setGain(at p: NSPoint) {
        let r = gainRect
        var dB = Fader.dB(position: Double((p.x - r.minX - 4) / (r.width - 8)))
        if abs(dB) < 0.3 { dB = 0 }
        editor.document.updateGesture { EditOperations.setMasterGain(&$0, dB: dB) }
    }
}
