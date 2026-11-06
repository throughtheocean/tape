import AppKit
import TapeCore

extension TimelineLayout {
    static let handleSize: CGFloat = 8
    static let edgeGrab: CGFloat = 5
}

/// Where a region's fade handles sit, in view points. Shared by hit testing and drawing.
struct FadeHandles {
    var inCorner: CGPoint
    var outCorner: CGPoint
    var inMid: CGPoint?
    var outMid: CGPoint?

    @MainActor
    init(_ r: Region, editor: EditorController, lane: Lane) {
        let top = CGFloat(lane.waveTop)
        let bottom = CGFloat(lane.bodyBottom)
        let x0 = editor.x(forFrame: Double(r.position)), x1 = editor.x(forFrame: Double(r.end))
        let inset = Double(TimelineLayout.handleSize) / 2 + 1
        let inX = max(editor.x(forFrame: Double(r.position + r.fadeIn.length)), x0 + inset)
        let outX = min(editor.x(forFrame: Double(r.end - r.fadeOut.length)), x1 - inset)
        inCorner = CGPoint(x: inX, y: top)
        outCorner = CGPoint(x: outX, y: top)
        func midY(_ fade: Fade) -> CGFloat { top + (1 - CGFloat(FadeCurves.value(fade, at: 0.5))) * (bottom - top) }
        let minimumSpan = Double(TimelineLayout.handleSize) * 2
        if Double(r.fadeIn.length) / editor.samplesPerPoint >= minimumSpan {
            inMid = CGPoint(x: editor.x(forFrame: Double(r.position) + Double(r.fadeIn.length) / 2), y: midY(r.fadeIn))
        }
        if Double(r.fadeOut.length) / editor.samplesPerPoint >= minimumSpan {
            outMid = CGPoint(x: editor.x(forFrame: Double(r.end) - Double(r.fadeOut.length) / 2), y: midY(r.fadeOut))
        }
    }
}

/// Pointer input on the track: selection, move, trim, fades, blade tool, Shift marking, rubber band.
extension TimelineMetalView {
    enum Hit {
        case handle(Region, EditOperations.FadeEnd)
        case mid(Region, EditOperations.FadeEnd)
        case edge(Region, start: Bool)
        case body(Region)
        case empty
    }

    /// Midpoint handles only take part with Option held, so plain clicks inside a fade select and move.
    func hitTest(at p: CGPoint, option: Bool) -> Hit {
        let y = Double(p.y)
        let handle = Double(TimelineLayout.handleSize)
        let viewport = editor.laneViewport
        guard y >= viewport.top - handle, y <= viewport.bottom else { return .empty }
        let lanes = editor.lanes().filter { y >= $0.bodyTop - handle && y <= $0.bodyBottom }
        guard !lanes.isEmpty else { return .empty }
        let grab = TimelineLayout.handleSize / 2 + 3
        // Handles first, nearest wins; topmost region on ties.
        var best: (Hit, CGFloat)?
        for lane in lanes {
            for r in editor.project.regions.reversed() where r.trackId == lane.track.id {
                let x0 = editor.x(forFrame: Double(r.position)), x1 = editor.x(forFrame: Double(r.end))
                if Double(p.x) < x0 - 8 || Double(p.x) > x1 + 8 { continue }
                let h = FadeHandles(r, editor: editor, lane: lane)
                var candidates: [(CGPoint?, Hit)] = [(h.inCorner, .handle(r, .fadeIn)), (h.outCorner, .handle(r, .fadeOut))]
                if option { candidates += [(h.inMid, .mid(r, .fadeIn)), (h.outMid, .mid(r, .fadeOut))] }
                for (point, hit) in candidates {
                    guard let point else { continue }
                    let d = max(abs(point.x - p.x), abs(point.y - p.y))
                    if d <= grab, best == nil || d < best!.1 { best = (hit, d) }
                }
            }
        }
        if let best { return best.0 }
        guard let lane = lanes.first(where: { y >= $0.bodyTop }) else { return .empty }
        let regions = editor.project.regions.filter { $0.trackId == lane.track.id }
        // Trim edges: on a shared edge the side the pointer is on decides.
        var edge: (Hit, CGFloat)?
        for r in regions.reversed() {
            let x0 = CGFloat(editor.x(forFrame: Double(r.position))), x1 = CGFloat(editor.x(forFrame: Double(r.end)))
            if x1 - x0 < 3 * TimelineLayout.edgeGrab { continue }
            let ds = p.x - x0, de = x1 - p.x
            if ds >= -TimelineLayout.edgeGrab, ds <= TimelineLayout.edgeGrab, edge == nil || abs(ds) < edge!.1 || (abs(ds) == edge!.1 && ds >= 0) {
                edge = (.edge(r, start: true), abs(ds))
            }
            if de >= -TimelineLayout.edgeGrab, de <= TimelineLayout.edgeGrab, edge == nil || abs(de) < edge!.1 || (abs(de) == edge!.1 && de >= 0) {
                edge = (.edge(r, start: false), abs(de))
            }
        }
        if let edge { return edge.0 }
        let frame = editor.frame(forX: Double(p.x))
        if let r = regions.last(where: { Double($0.position) <= frame && frame < Double($0.end) }) { return .body(r) }
        return .empty
    }

    /// Right click on a region selects it (unless it is already part of the selection) and offers Export Region.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard editor.samplesPerPoint > 0, p.y >= TimelineLayout.minimapHeight else { return nil }
        let region: Region
        switch hitTest(at: p, option: false) {
        case let .body(r), let .edge(r, _), let .handle(r, _), let .mid(r, _): region = r
        case .empty: return nil
        }
        if !editor.selection.contains(region.id) { editor.selection = [region.id] }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Export Region...", action: #selector(MainWindowController.exportRegion(_:)), keyEquivalent: "")
        item.representedObject = region.id
        menu.addItem(item)
        return menu
    }

    private func frameAt(_ p: CGPoint) -> Int64 {
        max(0, Int64(editor.frame(forX: Double(p.x)).rounded()))
    }

    // MARK: Down

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        drag = .none
        if p.y < TimelineLayout.minimapHeight {
            minimapDown(Double(p.x))
            return
        }
        guard editor.samplesPerPoint > 0 else { return }
        let hit = hitTest(at: p, option: flags.contains(.option))
        let frame = frameAt(p)

        if event.clickCount == 2, case let .body(r) = hit {
            editor.selectTrack(r.trackId, header: false)
            editor.selection = [r.id]
            editor.focusRegionName.send()
            return
        }
        switch hit {
        case let .body(r), let .edge(r, _), let .handle(r, _), let .mid(r, _):
            editor.selectTrack(r.trackId, header: false)
        case .empty:
            if editor.multitrack, let lane = editor.lane(atY: Double(p.y)), Double(p.y) >= editor.laneViewport.top {
                editor.selectTrack(lane.track.id, header: false)
            }
        }
        if editor.tool == .blade {
            if case let .body(r) = hit {
                let at = editor.snapEdge(frame, excluding: [], region: r, zeroCrossing: !flags.contains(.command))
                editor.blade(region: r.id, at: at)
            }
            return
        }
        switch hit {
        case let .handle(r, end):
            let ids = fadeTargets(r, flags)
            beginGesture()
            drag = .fade(id: r.id, end: end, ids: ids)
            return
        case let .mid(r, end):
            let ids = fadeTargets(r, flags)
            beginGesture()
            let fade = end == .fadeIn ? r.fadeIn : r.fadeOut
            drag = .fadeShape(id: r.id, end: end, ids: ids, startValue: EditOperations.continuous(fade), downY: Double(p.y))
            return
        default:
            break
        }
        if flags.contains(.shift) {
            let snapped = flags.contains(.command) ? frame : editor.snapped(frame)
            if let range = editor.range {
                // Extend the existing range from its far edge.
                let anchor = abs(range.start - snapped) > abs(range.end - snapped) ? range.start : range.end
                drag = .mark(anchor: anchor)
                editor.setRange(SampleRange(start: anchor, end: snapped))
            } else {
                drag = .mark(anchor: snapped)
                editor.locate(snapped)
            }
            return
        }
        switch hit {
        case let .edge(r, start):
            editor.selection = flags.contains(.command) ? editor.selection.union([r.id]) : [r.id]
            beginGesture()
            drag = .trim(id: r.id, start: start)
        case let .body(r):
            if flags.contains(.command) {
                editor.selection.formSymmetricDifference([r.id])
                return
            }
            if !editor.selection.contains(r.id) { editor.selection = [r.id] }
            drag = .pressRegion(id: r.id, downX: Double(p.x), downY: Double(p.y), downFrame: frame)
        default:
            drag = .pressEmpty(downX: Double(p.x), downY: Double(p.y), additive: flags.contains(.command))
        }
    }

    /// Shift applies a fade drag to every selected region.
    private func fadeTargets(_ r: Region, _ flags: NSEvent.ModifierFlags) -> Set<UUID> {
        flags.contains(.shift) ? editor.selectedIDs.union([r.id]) : [r.id]
    }

    private func beginGesture() {
        gestureBase = editor.project
        pieceIDs = [:]
        editor.document.beginGesture()
    }

    private func pieceID(_ region: UUID, _ k: Int) -> UUID {
        if let id = pieceIDs[region]?[k] { return id }
        let id = UUID()
        pieceIDs[region, default: [:]][k] = id
        return id
    }

    // MARK: Drag

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        let frame = frameAt(p)
        let doc = editor.document
        switch drag {
        case .none:
            break
        case let .minimapScroll(grabOffset):
            minimapScroll(to: Double(p.x), grabOffset: grabOffset)
        case let .minimapEdge(left, fixedFrame):
            minimapEdge(to: Double(p.x), left: left, fixedFrame: fixedFrame)
        case let .pressRegion(_, downX, downY, downFrame):
            let lanes = editor.multitrack && abs(Double(p.y) - downY) >= 6
            guard abs(Double(p.x) - downX) >= 3 || lanes else { return }
            beginGesture()
            let ids = editor.selectedIDs
            let copies = flags.contains(.option) ? Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID()) }) : nil
            drag = .move(ids: ids, downFrame: downFrame, downLane: editor.lane(atY: downY)?.index ?? 0, copies: copies)
            if let copies { editor.selection = Set(copies.values) }
            mouseDragged(with: event)
        case let .move(ids, downFrame, downLane, copies):
            var delta = frame - downFrame
            if !flags.contains(.command) { delta = editor.snapMove(delta: delta, ids: ids, base: gestureBase) }
            let laneDelta = editor.multitrack ? (editor.lane(atY: Double(p.y), clamped: true)?.index ?? downLane) - downLane : 0
            var applied: Int64 = 0
            var lanes = 0
            let moving = copies.map { Set($0.values) } ?? ids
            doc.updateGesture { project in
                if let copies { EditOperations.copy(&project, ids: ids, newIDs: copies) }
                applied = EditOperations.move(&project, ids: moving, by: delta)
                lanes = EditOperations.moveToTrack(&project, ids: moving, byLanes: laneDelta)
                // A plain move covers what lies under it on its track; an Option drag keeps both and they sum.
                if copies == nil { EditOperations.overwrite(&project, by: moving, pieceID: pieceID) }
            }
            let verb = copies == nil ? "" : "Copy "
            if lanes != 0, let id = moving.first, let r = editor.project.regions.first(where: { $0.id == id }),
               let t = editor.project.track(r.trackId) {
                hint("\(verb)\(editor.durationText(applied))  \(t.name)", at: p)
            } else {
                hint(verb + editor.durationText(applied), at: p)
            }
        case let .trim(id, start):
            guard let r = gestureBase.regions.first(where: { $0.id == id }) else { return }
            let edge = editor.snapEdge(frame, excluding: [id], region: r, zeroCrossing: !flags.contains(.command))
            let sourceLength = doc.sourceLength(r.sourceId)
            doc.updateGesture { p in
                if start {
                    EditOperations.trimStart(&p, id: id, to: edge)
                } else {
                    EditOperations.trimEnd(&p, id: id, to: edge, sourceLength: sourceLength)
                }
            }
            if let now = editor.project.regions.first(where: { $0.id == id }) {
                hint("Length \(editor.lengthText(now.length))", at: p)
            }
        case let .fade(id, end, ids):
            guard let r = gestureBase.regions.first(where: { $0.id == id }) else { return }
            let length = end == .fadeIn ? frame - r.position : r.end - frame
            doc.updateGesture { EditOperations.setFadeLength(&$0, ids: ids, end: end, length: length) }
            if let now = editor.project.regions.first(where: { $0.id == id }) {
                let f = end == .fadeIn ? now.fadeIn : now.fadeOut
                hint("\(end == .fadeIn ? "Fade in" : "Fade out") \(editor.lengthText(f.length))", at: p)
            }
        case let .fadeShape(id, end, ids, startValue, downY):
            let value = min(max(startValue + (downY - Double(p.y)) / 40, 0), 3)
            doc.updateGesture { EditOperations.setFadeShape(&$0, ids: ids, end: end, continuous: value) }
            if let now = editor.project.regions.first(where: { $0.id == id }) {
                hint(Self.shapeText(end == .fadeIn ? now.fadeIn : now.fadeOut), at: p)
            }
        case let .mark(anchor):
            let edge = flags.contains(.command) ? frame : editor.snapped(frame)
            editor.setRange(SampleRange(start: anchor, end: edge))
            if let r = editor.range { hint(editor.lengthText(r.length), at: p) }
        case let .pressEmpty(downX, downY, additive):
            guard abs(Double(p.x) - downX) >= 3 || abs(Double(p.y) - downY) >= 3 else { return }
            drag = .rubber(anchor: editor.frame(forX: downX), anchorY: downY, base: additive ? editor.selection : [])
            mouseDragged(with: event)
        case let .rubber(anchor, anchorY, base):
            let f = editor.frame(forX: Double(p.x))
            let band = SampleRange(start: Int64(min(anchor, f)), end: Int64(max(anchor, f).rounded(.up)))
            var tracks = editor.visibleTrackIDs
            if editor.multitrack {
                let y0 = min(anchorY, Double(p.y)), y1 = max(anchorY, Double(p.y))
                tracks = Set(editor.lanes().filter { $0.bottom > y0 && $0.top < y1 }.map(\.track.id))
                editor.pointer.rubberTop = max(y0, editor.laneViewport.top)
                editor.pointer.rubberBottom = min(y1, editor.laneViewport.bottom)
            }
            let hits = editor.project.regions.filter {
                tracks.contains($0.trackId) && $0.position < band.end && $0.end > band.start
            }.map(\.id)
            editor.selection = base.union(hits)
            editor.pointer.rubberBand = band
        }
        autoscroll(p)
    }

    /// Scrolls the view while dragging past either side.
    private func autoscroll(_ p: CGPoint) {
        switch drag {
        case .move, .trim, .mark, .rubber, .fade: break
        default: return
        }
        if p.x < 0 { editor.scroll(byPoints: Double(p.x) / 4) }
        if p.x > bounds.width { editor.scroll(byPoints: Double(p.x - bounds.width) / 4) }
        if editor.multitrack {
            let v = editor.laneViewport
            if Double(p.y) < v.top { editor.scrollLanes(by: (Double(p.y) - v.top) / 4) }
            if Double(p.y) > v.bottom { editor.scrollLanes(by: (Double(p.y) - v.bottom) / 4) }
        }
    }

    static func shapeText(_ fade: Fade) -> String {
        guard fade.blend > 0.005, let next = fade.shape.next else { return fade.shape.displayName }
        return "\(fade.shape.displayName) \(Int((fade.blend * 100).rounded()))% to \(next.displayName)"
    }

    private func hint(_ text: String, at p: CGPoint) {
        editor.pointer.hint = text
        editor.pointer.hintX = Double(p.x)
        editor.pointer.hintY = editor.multitrack ? Double(p.y) : nil
    }

    // MARK: Up

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let doc = editor.document
        switch drag {
        case let .pressRegion(id, _, _, _):
            editor.selection = [id]
            editor.locate(frameAt(p))
        case let .move(_, _, _, copies): doc.endGesture(copies == nil ? "Move" : "Copy")
        case .trim: doc.endGesture("Trim")
        case .fade: doc.endGesture("Fade")
        case .fadeShape: doc.endGesture("Fade Shape")
        case let .pressEmpty(_, _, additive):
            if !additive { editor.selection = [] }
            editor.locate(frameAt(p))
        default:
            break
        }
        if doc.isInGesture { doc.endGesture("Edit") }
        drag = .none
        editor.pointer.hint = nil
        editor.pointer.hintY = nil
        editor.pointer.rubberBand = nil
        editor.pointer.rubberTop = nil
        editor.pointer.rubberBottom = nil
        updateHover(p, flags: event.modifierFlags)
    }

    // MARK: Hover

    override func mouseMoved(with event: NSEvent) {
        updateHover(convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        editor.pointer.hoverRegion = nil
        editor.pointer.hoverEdge = nil
        editor.pointer.bladeFrame = nil
        NSCursor.arrow.set()
    }

    func updateHover(_ p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard p.y >= TimelineLayout.minimapHeight, editor.samplesPerPoint > 0 else { return }
        let hit = hitTest(at: p, option: flags.contains(.option))
        var overlay = editor.pointer
        overlay.hoverEdge = nil
        overlay.bladeFrame = nil
        let frame = editor.frame(forX: Double(p.x))
        overlay.hoverRegion = editor.region(at: frame, y: Double(p.y))?.id
        if editor.tool == .blade {
            if case let .body(r) = hit {
                overlay.bladeFrame = editor.snapEdge(frameAt(p), excluding: [], region: r, zeroCrossing: !flags.contains(.command))
            }
            Self.scissors.set()
            editor.pointer = overlay
            return
        }
        switch hit {
        case let .handle(r, _), let .mid(r, _):
            overlay.hoverRegion = r.id
            NSCursor.resizeLeftRight.set()
        case let .edge(r, start):
            overlay.hoverRegion = r.id
            overlay.hoverEdge = (r.id, start)
            NSCursor.resizeLeftRight.set()
        default:
            NSCursor.arrow.set()
        }
        editor.pointer = overlay
    }

    static let scissors: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Blade")?
            .withSymbolConfiguration(config) else { return .crosshair }
        let white = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = NSSize(width: 22, height: 22)
        let out = NSImage(size: size, flipped: false) { rect in
            let shadow = NSShadow()
            shadow.shadowColor = .black
            shadow.shadowBlurRadius = 2
            shadow.set()
            white.draw(in: NSRect(x: (rect.width - image.size.width) / 2, y: (rect.height - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height))
            return true
        }
        return NSCursor(image: out, hotSpot: NSPoint(x: 11, y: 11))
    }()
}
