import AppKit

/// Slider with a round handle, horizontal or vertical. Value 0...1, double click resets.
@MainActor
final class ZoomBarView: NSView {
    let vertical: Bool
    var value: () -> Double = { 0 }
    var setValue: (Double) -> Void = { _ in }
    var reset: () -> Void = {}

    private var handleSize: CGFloat { vertical ? 14 : 11 }
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
        let thick: CGFloat = vertical ? 5 : 3
        func bar(_ a: CGFloat, _ b: CGFloat) -> NSRect {
            vertical ? NSRect(x: mid - thick / 2, y: min(a, b), width: thick, height: abs(b - a))
                : NSRect(x: min(a, b), y: mid - thick / 2, width: abs(b - a), height: thick)
        }
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: bar(t.start, t.end), xRadius: thick / 2, yRadius: thick / 2).fill()
        Theme.accent.setFill()
        NSBezierPath(roundedRect: bar(vertical ? t.end : t.start, p), xRadius: thick / 2, yRadius: thick / 2).fill()
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

/// Toggle drawn as an SF Symbol, used for the tool buttons.
@MainActor
final class SymbolToolButton: NSView {
    var isOn: () -> Bool = { false }
    var toggle: () -> Void = {}
    private let symbolName: String
    private var drawnState: Bool?

    init(symbol: String, toolTip: String) {
        symbolName = symbol
        super.init(frame: .zero)
        self.toolTip = toolTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func refreshIfChanged() {
        if drawnState != isOn() { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = isOn()
        drawnState = on
        let box = bounds.insetBy(dx: 1, dy: 2)
        (on ? Theme.accent.withAlphaComponent(0.22) : NSColor(white: 1, alpha: 0.06)).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config) else { return }
        let color = on ? Theme.accent : Theme.secondaryText
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: box.midX - symbol.size.width / 2, y: box.midY - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height))
    }

    override func mouseDown(with event: NSEvent) {
        toggle()
        needsDisplay = true
    }
}

/// Button showing a short text that changes with state, used for the lane height.
@MainActor
final class TextToolButton: NSView {
    var label: () -> String = { "" }
    var action: () -> Void = {}
    private var drawnLabel: String?

    init(toolTip: String) {
        super.init(frame: .zero)
        self.toolTip = toolTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func refreshIfChanged() {
        if drawnLabel != label() { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = label()
        drawnLabel = text
        let box = bounds.insetBy(dx: 1, dy: 2)
        NSColor(white: 1, alpha: 0.06).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        HeaderDrawing.text(text, in: box, size: 11, color: Theme.secondaryText, align: .center, weight: .semibold, mono: false)
    }

    override func mouseDown(with event: NSEvent) {
        action()
        needsDisplay = true
    }
}

/// Strip under the minimap with the horizontal zoom, right aligned.
@MainActor
final class TimelineToolStrip: NSView {
    let zoomBar = ZoomBarView(vertical: false, toolTip: "Horizontal zoom (Option scroll, Command scroll, pinch). Double click to fit.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(zoomBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let barWidth: CGFloat = min(260, max(80, bounds.width * 0.3))
        zoomBar.frame = NSRect(x: bounds.width - barWidth - 4, y: 0, width: barWidth, height: bounds.height - 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func refresh() {
        zoomBar.refreshIfChanged()
    }
}

/// Vertical bar right of the track: vertical zoom on top, tools below.
@MainActor
final class TimelineSideBar: NSView {
    static let width: CGFloat = 36
    static let zoomHeight: CGFloat = 150

    let amplitudeBar = ZoomBarView(vertical: true, toolTip: "Vertical zoom (Option Shift scroll). Double click to reset.")
    let select = SymbolToolButton(symbol: "cursorarrow", toolTip: "Select tool (A)")
    let blade = SymbolToolButton(symbol: "scissors", toolTip: "Blade tool (B). Click a region to cut it. A returns to the select tool.")
    let snap = SnapToZeroButton(frame: .zero)
    let laneSize = TextToolButton(toolTip: "Lane height in the multitrack view: 40, 80 or 160 points")
    let expand = SymbolToolButton(symbol: "arrow.up.and.down", toolTip: "Expand the selected track")
    /// Lane buttons only show in the multitrack view.
    var showsLaneTools = false {
        didSet { if oldValue != showsLaneTools { needsLayout = true; needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [amplitudeBar, select, blade, snap, laneSize, expand] as [NSView] { addSubview(v) }
    }

    private var zoomHeight: CGFloat {
        min(Self.zoomHeight, max(60, bounds.height - (showsLaneTools ? 170 : 110)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width
        let zoom = zoomHeight
        amplitudeBar.frame = NSRect(x: 0, y: 0, width: w, height: zoom)
        var y = zoom + 9
        laneSize.isHidden = !showsLaneTools
        expand.isHidden = !showsLaneTools
        for button in [select, blade, snap, laneSize, expand] as [NSView] where !button.isHidden {
            button.frame = NSRect(x: 2, y: y, width: w - 4, height: 28)
            y += 30
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 6, y: zoomHeight + 4, width: bounds.width - 12, height: 1).fill()
    }

    func refresh() {
        amplitudeBar.refreshIfChanged()
        select.refreshIfChanged()
        blade.refreshIfChanged()
        snap.refreshIfChanged()
        laneSize.refreshIfChanged()
        expand.refreshIfChanged()
    }
}
