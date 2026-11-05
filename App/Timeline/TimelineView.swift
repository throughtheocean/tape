import AppKit
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
    private(set) var renderer: TimelineRenderer?
    private var displayLink: CADisplayLink?
    private var dirty = true

    init(editor: EditorController) {
        self.editor = editor
        ruler = RulerView(editor: editor)
        metalView = TimelineMetalView(editor: editor)
        labels = LabelsOverlayView(editor: editor)
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

        editor.needsDisplay = { [weak self] in self?.setDirty() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        ruler.frame = NSRect(x: 0, y: 0, width: b.width, height: Self.rulerHeight)
        let track = NSRect(x: 0, y: Self.rulerHeight, width: b.width, height: max(0, b.height - Self.rulerHeight))
        metalView.frame = track
        labels.frame = track
        editor.timelineWidth = Double(b.width)
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
        guard dirty else { return }
        dirty = false
        metalView.draw()
        ruler.needsDisplay = true
        labels.update()
        if tickDurations != nil { tickDurations?.append((CACurrentMediaTime() - t0) * 1000) }
    }
}

/// Metal canvas for minimap, regions, waveforms and playhead. Handles pointer input.
@MainActor
final class TimelineMetalView: MTKView {
    let editor: EditorController
    private enum Drag {
        case none
        case scrub
        case minimapScroll(grabOffset: Double)
        case minimapEdge(left: Bool, fixedFrame: Double)
    }

    private var drag = Drag.none

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
        if flags.contains(.command) {
            let dy = event.scrollingDeltaY
            editor.zoom(by: exp(-Double(dy) * (precise ? 0.01 : 0.12)), anchorX: Double(point.x))
        } else if flags.contains(.option) {
            let dy = event.scrollingDeltaY
            editor.zoomAmplitude(by: exp(Double(dy) * (precise ? 0.01 : 0.12)))
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

    // MARK: Mouse

    private func minimapGeometry() -> (length: Double, scale: Double, windowX: Double, windowW: Double)? {
        let length = Double(editor.documentLength)
        guard length > 0, editor.samplesPerPoint > 0 else { return nil }
        let w = Double(bounds.width)
        let scale = w / length
        let visible = w * editor.samplesPerPoint
        return (length, scale, editor.viewStart * scale, max(visible * scale, 4))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if p.y < TimelineLayout.minimapHeight {
            guard let g = minimapGeometry() else { return }
            let x = Double(p.x)
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
        } else {
            drag = .scrub
            editor.locate(Int64(editor.frame(forX: Double(p.x)).rounded()))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            break
        case .scrub:
            editor.locate(Int64(editor.frame(forX: Double(p.x)).rounded()))
        case let .minimapScroll(grabOffset):
            minimapScroll(to: Double(p.x), grabOffset: grabOffset)
        case let .minimapEdge(left, fixedFrame):
            guard let g = minimapGeometry() else { return }
            let frameAtMouse = min(max(Double(p.x) / g.scale, 0), g.length)
            let a = left ? frameAtMouse : fixedFrame
            let b = left ? fixedFrame : frameAtMouse
            let span = max(b - a, EditorController.minSamplesPerPoint * Double(bounds.width))
            editor.setView(start: a, samplesPerPoint: span / Double(bounds.width))
        }
    }

    override func mouseUp(with event: NSEvent) { drag = .none }

    private func minimapScroll(to x: Double, grabOffset: Double) {
        guard let g = minimapGeometry() else { return }
        editor.setView(start: (x - grabOffset) / g.scale, samplesPerPoint: editor.samplesPerPoint)
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
        if editor.samplesPerPoint > 0 {
            for region in doc.project.regions {
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
                layer.frame = CGRect(x: left, y: TimelineLayout.trackTop + 2, width: max(0, min(x1, width) - left - 4), height: 14)
            }
        }
        for i in used..<pool.count where !pool[i].isHidden { pool[i].isHidden = true }
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
