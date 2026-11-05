import AppKit

/// Slider with a round handle, horizontal or vertical. Value 0...1, double click resets.
@MainActor
final class ZoomBarView: NSView {
    let vertical: Bool
    var value: () -> Double = { 0 }
    var setValue: (Double) -> Void = { _ in }
    var reset: () -> Void = {}

    private let handleSize: CGFloat = 11
    private let inset: CGFloat = 8
    private var drawnValue = -1.0

    func refreshIfChanged() {
        if abs(value() - drawnValue) > 1e-4 { needsDisplay = true }
    }

    init(vertical: Bool, toolTip: String) {
        self.vertical = vertical
        super.init(frame: .zero)
        self.toolTip = toolTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Track from `start` to `end` along the main axis; for vertical bars 1 is at the top.
    private var track: (start: CGFloat, end: CGFloat) {
        let length = vertical ? bounds.height : bounds.width
        return (inset + handleSize / 2, max(inset + handleSize / 2, length - inset - handleSize / 2))
    }

    private func position(for v: Double) -> CGFloat {
        let t = track
        let f = CGFloat(min(max(v, 0), 1))
        return vertical ? t.end - f * (t.end - t.start) : t.start + f * (t.end - t.start)
    }

    private func value(at point: NSPoint) -> Double {
        let t = track
        let span = max(t.end - t.start, 1)
        let f = vertical ? (t.end - point.y) / span : (point.x - t.start) / span
        return Double(min(max(f, 0), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        let t = track
        drawnValue = value()
        let p = position(for: drawnValue)
        let mid = (vertical ? bounds.width : bounds.height) / 2
        func bar(_ a: CGFloat, _ b: CGFloat) -> NSRect {
            vertical ? NSRect(x: mid - 1.5, y: min(a, b), width: 3, height: abs(b - a))
                : NSRect(x: min(a, b), y: mid - 1.5, width: abs(b - a), height: 3)
        }
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: bar(t.start, t.end), xRadius: 1.5, yRadius: 1.5).fill()
        Theme.accent.setFill()
        NSBezierPath(roundedRect: bar(vertical ? t.end : t.start, p), xRadius: 1.5, yRadius: 1.5).fill()
        let knob = vertical ? NSRect(x: mid - handleSize / 2, y: p - handleSize / 2, width: handleSize, height: handleSize)
            : NSRect(x: p - handleSize / 2, y: mid - handleSize / 2, width: handleSize, height: handleSize)
        NSColor(white: 0.92, alpha: 1).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            reset()
            return
        }
        setValue(value(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        setValue(value(at: convert(event.locationInWindow, from: nil)))
    }

    override func scrollWheel(with event: NSEvent) {
        let d = vertical ? event.scrollingDeltaY : (abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY)
        setValue(value() + Double(d) * (event.hasPreciseScrollingDeltas ? 0.002 : 0.02))
    }
}

/// Toggle drawn as a sine crossing a centre line, with a dot on the crossing.
@MainActor
final class SnapToZeroButton: NSView {
    var isOn: () -> Bool = { false }
    var toggle: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Snap to Zero Crossing (N)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var drawnState: Bool?

    func refreshIfChanged() {
        if drawnState != isOn() { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = isOn()
        drawnState = on
        let box = bounds.insetBy(dx: 1, dy: 2)
        (on ? Theme.accent.withAlphaComponent(0.22) : NSColor(white: 1, alpha: 0.06)).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        let color = on ? Theme.accent : Theme.secondaryText
        let mid = box.midY, cx = box.midX
        let half = min(box.width / 2 - 5, 9)
        let amp = box.height / 2 - 4

        NSColor(white: 1, alpha: 0.25).setFill()
        NSRect(x: cx - half - 2, y: mid - 0.5, width: 2 * half + 4, height: 1).fill()
        let wave = NSBezierPath()
        let steps = 24
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let pt = NSPoint(x: cx - half + CGFloat(f) * 2 * half, y: mid - CGFloat(sin(f * 2 * .pi)) * amp)
            i == 0 ? wave.move(to: pt) : wave.line(to: pt)
        }
        wave.lineWidth = 1.4
        color.setStroke()
        wave.stroke()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - 2.5, y: mid - 2.5, width: 5, height: 5)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        toggle()
        needsDisplay = true
    }
}

/// Strip under the minimap: snap toggle and horizontal zoom, right aligned.
@MainActor
final class TimelineToolStrip: NSView {
    let snap = SnapToZeroButton(frame: .zero)
    let zoomBar = ZoomBarView(vertical: false, toolTip: "Horizontal zoom (Option scroll, Command scroll, pinch). Double click to fit.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(snap)
        addSubview(zoomBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let barWidth: CGFloat = min(220, max(80, bounds.width * 0.3))
        zoomBar.frame = NSRect(x: bounds.width - barWidth - 4, y: 0, width: barWidth, height: bounds.height - 1)
        snap.frame = NSRect(x: zoomBar.frame.minX - 34, y: 0, width: 30, height: bounds.height - 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func refresh() {
        snap.refreshIfChanged()
        zoomBar.refreshIfChanged()
    }
}
