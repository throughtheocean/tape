import AppKit
import Combine
import MetalKit
import QuartzCore
import TapeCore

/// Ruler, Metal track with minimap, and text labels. Drives redraws from a display link.
@MainActor
final class TimelineView: NSView {
    static let rulerHeight: CGFloat = 24

    let editor: EditorController
    let ruler: RulerView
    let metalView: TimelineMetalView
    let labels: LabelsOverlayView
    let toolStrip = TimelineToolStrip(frame: .zero)
    let sideBar = TimelineSideBar(frame: .zero)
    var amplitudeBar: ZoomBarView { sideBar.amplitudeBar }
    private let corner = NSView()
    let headers: TrackHeaderColumn
    let loudnessMeter: LoudnessMeterView
    private let headerCorner = NSView()
    private var observers: Set<AnyCancellable> = []
    private(set) var renderer: TimelineRenderer?
    private var displayLink: CADisplayLink?
    private var dirty = true

    init(editor: EditorController) {
        self.editor = editor
        ruler = RulerView(editor: editor)
        metalView = TimelineMetalView(editor: editor)
        labels = LabelsOverlayView(editor: editor)
        headers = TrackHeaderColumn(editor: editor)
        loudnessMeter = LoudnessMeterView(editor: editor)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.timeline.cgColor

        renderer = TimelineRenderer(view: metalView)
        renderer?.editor = editor
        metalView.device = renderer?.device
        metalView.delegate = renderer
        addSubview(metalView)
        addSubview(labels)
        addSubview(ruler)
        addSubview(toolStrip)
        addSubview(sideBar)
        corner.wantsLayer = true
        corner.layer?.backgroundColor = Theme.chrome.cgColor
        addSubview(corner)
        headerCorner.wantsLayer = true
        headerCorner.layer?.backgroundColor = Theme.chrome.cgColor
        addSubview(headerCorner)
        addSubview(headers)
        addSubview(loudnessMeter)
        editor.$multitrack.sink { [weak self] _ in self?.needsLayout = true }.store(in: &observers)

        let zoomBar = toolStrip.zoomBar
        zoomBar.value = { [unowned editor] in editor.zoom.normalized }
        zoomBar.setValue = { [unowned editor] in editor.setZoomNormalized($0) }
        zoomBar.reset = { [unowned editor] in editor.fitAll() }
        amplitudeBar.value = { [unowned editor] in editor.amplitudeNormalized }
        amplitudeBar.setValue = { [unowned editor] in editor.setAmplitudeNormalized($0) }
        amplitudeBar.reset = { [unowned editor] in editor.setAmplitudeNormalized(0) }
        sideBar.snap.isOn = { AppSettings.shared.snapToZeroCrossing }
        sideBar.snap.toggle = { [unowned editor] in
            AppSettings.shared.snapToZeroCrossing.toggle()
            editor.needsDisplay?()
        }

        sideBar.select.isOn = { [unowned editor] in editor.tool == .select }
        sideBar.select.toggle = { [unowned editor] in editor.tool = .select }
        sideBar.blade.isOn = { [unowned editor] in editor.tool == .blade }
        sideBar.blade.toggle = { [unowned editor] in editor.tool = editor.tool == .blade ? .select : .blade }
        sideBar.laneBar.value = { [unowned editor] in editor.laneHeightNormalized }
        sideBar.laneBar.setValue = { [unowned editor] in editor.setLaneHeightNormalized($0) }
        sideBar.laneBar.reset = { [unowned editor] in editor.laneHeight = EditorController.defaultLaneHeight }
        sideBar.expand.isOn = { [unowned editor] in editor.expandSelected }
        sideBar.expand.toggle = { [unowned editor] in editor.expandSelected.toggle() }

        editor.needsDisplay = { [weak self] in self?.setDirty() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        // Tool bar at the left edge, then in the multitrack view the header column, then everything that scrolls
        // in time, and the loudness column at the right edge.
        let side = TimelineSideBar.width
        let w = max(side, b.width - LoudnessMeterView.width)
        loudnessMeter.frame = NSRect(x: w, y: 0, width: LoudnessMeterView.width, height: b.height)
        let multi = editor.multitrack
        let h0 = side
        let x0 = h0 + (multi ? min(EditorController.headerWidth, w - side) : 0)
        ruler.frame = NSRect(x: x0, y: 0, width: w - x0, height: Self.rulerHeight)
        let track = NSRect(x: x0, y: Self.rulerHeight, width: w - x0, height: max(0, b.height - Self.rulerHeight))
        metalView.frame = track
        labels.frame = track
        toolStrip.frame = NSRect(x: x0, y: track.minY + TimelineLayout.minimapHeight + 1,
                                 width: w - x0, height: TimelineLayout.toolStripHeight - 1)
        let barTop = track.minY + TimelineLayout.trackTop
        corner.frame = NSRect(x: 0, y: 0, width: side, height: barTop)
        sideBar.frame = NSRect(x: 0, y: barTop, width: side, height: max(0, b.height - barTop))
        sideBar.showsLaneTools = multi
        headers.isHidden = !multi
        headerCorner.isHidden = !multi
        headerCorner.frame = NSRect(x: h0, y: 0, width: x0 - h0, height: barTop)
        headers.frame = NSRect(x: h0, y: barTop, width: x0 - h0, height: max(0, b.height - barTop))
        editor.timelineWidth = Double(w - x0)
        editor.timelineHeight = Double(track.height)
        if multi { headers.refresh() }
        setDirty()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func setDirty() { dirty = true }

    func invalidateWaveforms() {
        renderer?.invalidateWaveforms()
        setDirty()
    }

    /// Main thread milliseconds per display link tick, collected while non-nil (benchmark).
    var tickDurations: [Double]?

    @objc private func tick(_ link: CADisplayLink) {
        let t0 = CACurrentMediaTime()
        editor.tick()
        editor.updateMeters(now: t0)
        if editor.multitrack { headers.refresh() }
        loudnessMeter.refresh()
        guard dirty else { return }
        dirty = false
        metalView.draw()
        ruler.needsDisplay = true
        toolStrip.refresh()
        sideBar.refresh()
        labels.update()
        if tickDurations != nil { tickDurations?.append((CACurrentMediaTime() - t0) * 1000) }
    }
}

/// Metal canvas for minimap, regions, waveforms and playhead. Handles pointer input.
@MainActor
final class TimelineMetalView: MTKView {
    let editor: EditorController
    enum Drag {
        case none
        case minimapScroll(grabOffset: Double)
        case minimapEdge(left: Bool, fixedFrame: Double)
        /// Mouse down on a region; becomes a move once the pointer travels.
        case pressRegion(id: UUID, downX: Double, downY: Double, downFrame: Int64)
        /// `copies` maps each region to its copy's id for an Option drag; nil moves the regions themselves.
        case move(ids: Set<UUID>, downFrame: Int64, downLane: Int, copies: [UUID: UUID]?)
        /// Option Command drag: moves `ids` in time on their own track and connects them to the region it is
        /// released over on a magnetic track.
        case connect(ids: Set<UUID>, downFrame: Int64)
        case trim(id: UUID, start: Bool)
        case fade(id: UUID, end: EditOperations.FadeEnd, ids: Set<UUID>)
        case fadeShape(id: UUID, end: EditOperations.FadeEnd, ids: Set<UUID>, startValue: Double, downY: Double)
        case mark(anchor: Int64)
        /// Mouse down on empty track; a click locates, a drag draws a rubber band.
        case pressEmpty(downX: Double, downY: Double, additive: Bool)
        case rubber(anchor: Double, anchorY: Double, base: Set<UUID>)
    }

    var drag = Drag.none
    /// Ids for the pieces of regions split by an overwrite, stable through one drag.
    var pieceIDs: [UUID: [Int: UUID]] = [:]
    /// Project at the start of the current drag.
    var gestureBase = Project()
    private var trackingArea: NSTrackingArea?

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: .zero, device: nil)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.059, green: 0.059, blue: 0.063, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = false
        framebufferOnly = true
        preferredFramesPerSecond = 120
        if let layer = layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.maximumDrawableCount = 3
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Scroll and zoom

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let precise = event.hasPreciseScrollingDeltas
        let flags = event.modifierFlags
        // Shift turns a mouse wheel into horizontal deltas, so take the larger axis.
        let dy = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        if flags.contains(.option), flags.contains(.shift) {
            editor.zoomAmplitude(by: exp(Double(dy) * (precise ? 0.01 : 0.12)))
        } else if flags.contains(.command) || flags.contains(.option) {
            editor.zoom(by: exp(-Double(dy) * (precise ? 0.01 : 0.12)), anchorX: Double(point.x))
        } else if editor.multitrack, editor.maxLaneScroll > 0, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            // Lanes taller than the window scroll vertically; Shift scroll (horizontal deltas) still pans.
            editor.scrollLanes(by: -Double(event.scrollingDeltaY) * (precise ? 1 : 12))
        } else {
            var dx = event.scrollingDeltaX
            if abs(event.scrollingDeltaY) > abs(dx) { dx = event.scrollingDeltaY }
            editor.scroll(byPoints: -Double(dx) * (precise ? 1 : 12))
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        editor.zoom(by: 1 / max(0.2, 1 + Double(event.magnification)), anchorX: Double(point.x))
    }

    // MARK: Minimap

    func minimapGeometry() -> (length: Double, scale: Double, windowX: Double, windowW: Double)? {
        let length = Double(editor.documentLength)
        guard length > 0, editor.samplesPerPoint > 0 else { return nil }
        let w = Double(bounds.width)
        let scale = w / length
        let visible = w * editor.samplesPerPoint
        return (length, scale, editor.viewStart * scale, max(visible * scale, 4))
    }

    func minimapDown(_ x: Double) {
        guard let g = minimapGeometry() else { return }
        if abs(x - g.windowX) < 6 {
            drag = .minimapEdge(left: true, fixedFrame: editor.viewStart + editor.samplesPerPoint * Double(bounds.width))
        } else if abs(x - (g.windowX + g.windowW)) < 6 {
            drag = .minimapEdge(left: false, fixedFrame: editor.viewStart)
        } else if x >= g.windowX, x <= g.windowX + g.windowW {
            drag = .minimapScroll(grabOffset: x - g.windowX)
        } else {
            drag = .minimapScroll(grabOffset: g.windowW / 2)
            minimapScroll(to: x, grabOffset: g.windowW / 2)
        }
    }

    func minimapScroll(to x: Double, grabOffset: Double) {
        guard let g = minimapGeometry() else { return }
        editor.setView(start: (x - grabOffset) / g.scale, samplesPerPoint: editor.samplesPerPoint)
    }

    func minimapEdge(to x: Double, left: Bool, fixedFrame: Double) {
        guard let g = minimapGeometry() else { return }
        let frameAtMouse = min(max(x / g.scale, 0), g.length)
        let a = left ? frameAtMouse : fixedFrame
        let b = left ? fixedFrame : frameAtMouse
        let span = max(b - a, EditorController.minSamplesPerPoint * Double(bounds.width))
        editor.setView(start: a, samplesPerPoint: span / Double(bounds.width))
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: TimelineLayout.minimapHeight), cursor: .openHand)
    }
}

/// Time ruler drawn with Core Graphics; no audio data here. Click or drag to move the playhead.
@MainActor
final class RulerView: NSView {
    let editor: EditorController

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard editor.samplesPerPoint > 0 else { return }

        let settings = AppSettings.shared
        let format = TimeFormat(display: settings.timeDisplay, frameRate: settings.frameRate, sampleRate: editor.sessionRate)
        let step = RulerTicks.step(samplesPerPoint: editor.samplesPerPoint, sampleRate: editor.sessionRate,
                                   display: settings.timeDisplay, frameRate: settings.frameRate)
        let minor = max(1, step / 5)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.monoDigits(10),
            .foregroundColor: Theme.secondaryText,
        ]
        let endFrame = editor.frame(forX: Double(bounds.width))
        var f = Int64(max(0, editor.viewStart) / Double(minor)) * minor
        let tickColor = NSColor(white: 1, alpha: 0.28)
        while Double(f) <= endFrame {
            let x = (editor.x(forFrame: Double(f))).rounded() + 0.5
            let major = f % step == 0
            tickColor.setFill()
            let h: CGFloat = major ? 9 : 4
            NSRect(x: x, y: bounds.height - 1 - h, width: 1, height: h).fill()
            if major {
                (format.rulerLabel(f, step: step) as NSString).draw(at: NSPoint(x: x + 3, y: 2), withAttributes: attrs)
            }
            f += minor
        }

        if let range = editor.range {
            let x0 = editor.x(forFrame: Double(range.start)), x1 = editor.x(forFrame: Double(range.end))
            Theme.range.withAlphaComponent(0.35).setFill()
            NSRect(x: x0, y: bounds.height - 4, width: max(x1 - x0, 1), height: 3).fill()
        }
        let px = editor.x(forFrame: Double(editor.playhead))
        if px >= -8, px <= Double(bounds.width) + 8 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: px - 5, y: bounds.height - 9))
            path.line(to: NSPoint(x: px + 5, y: bounds.height - 9))
            path.line(to: NSPoint(x: px, y: bounds.height - 1))
            path.close()
            Theme.playhead.setFill()
            path.fill()
        }
    }

    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }

    private func scrub(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        editor.locate(Int64(editor.frame(forX: Double(p.x)).rounded()))
    }
}

/// Region names and status text as reusable text layers over the Metal view.
@MainActor
final class LabelsOverlayView: NSView {
    let editor: EditorController
    private var pool: [CATextLayer] = []

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let doc = editor.document
        let scale = window?.backingScaleFactor ?? 2
        let width = Double(bounds.width)
        var used = 0
        let viewport = editor.laneViewport
        let lanes = Dictionary(editor.lanes().map { ($0.track.id, $0) }, uniquingKeysWith: { a, _ in a })
        if editor.samplesPerPoint > 0 {
            for region in doc.project.regions {
                guard let lane = lanes[region.trackId] else { continue }
                let y = lane.bodyTop + (lane.strip >= Double(TimelineLayout.nameStrip) ? 2 : 0)
                if y < viewport.top - 1 || y + 12 > viewport.bottom { continue }
                let x0 = editor.x(forFrame: Double(region.position))
                let x1 = editor.x(forFrame: Double(region.end))
                if x1 < 0 || x0 > width || x1 - x0 < 24 { continue }
                var text = region.name
                if doc.loading.contains(region.sourceId) { text += "   Building waveform" }
                if let failure = doc.failures[region.sourceId] { text += "   Offline: \(failure)" }
                let layer = textLayer(at: used, scale: scale)
                used += 1
                if (layer.string as? String) != text { layer.string = text }
                let left = max(x0, 0) + 6
                layer.frame = CGRect(x: left, y: y, width: max(0, min(x1, width) - left - 4), height: 14)
            }
        }
        for i in used..<pool.count where !pool[i].isHidden { pool[i].isHidden = true }
        updateHint(scale: scale)
    }

    private lazy var hintLayer: CATextLayer = {
        let l = CATextLayer()
        l.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        l.fontSize = 11
        l.foregroundColor = NSColor.white.cgColor
        l.backgroundColor = NSColor(white: 0, alpha: 0.75).cgColor
        l.cornerRadius = 3
        l.alignmentMode = .center
        layer?.addSublayer(l)
        return l
    }()

    private func updateHint(scale: CGFloat) {
        guard let text = editor.pointer.hint else {
            if !hintLayer.isHidden { hintLayer.isHidden = true }
            return
        }
        hintLayer.isHidden = false
        hintLayer.contentsScale = scale
        if (hintLayer.string as? String) != text { hintLayer.string = text }
        let width = CGFloat(text.count) * 6.6 + 12
        var x = CGFloat(editor.pointer.hintX) + 12
        if x + width > bounds.width - 4 { x = CGFloat(editor.pointer.hintX) - width - 12 }
        let y = editor.pointer.hintY.map { $0 - 26 } ?? Double(TimelineLayout.trackTop + TimelineLayout.nameStrip + 6)
        hintLayer.frame = CGRect(x: max(4, x), y: max(TimelineLayout.trackTop, y), width: width, height: 16)
    }

    private func textLayer(at index: Int, scale: CGFloat) -> CATextLayer {
        if index < pool.count {
            let l = pool[index]
            l.isHidden = false
            return l
        }
        let l = CATextLayer()
        l.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        l.fontSize = 11
        l.foregroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        l.contentsScale = scale
        l.truncationMode = .end
        l.isWrapped = false
        layer?.addSublayer(l)
        pool.append(l)
        return l
    }
}
