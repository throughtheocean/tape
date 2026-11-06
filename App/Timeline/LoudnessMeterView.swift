import AppKit
import TapeCore

/// Column at the right edge: loudness of what is played, as one reading (momentary, short term or integrated,
/// switched with the button on top), the same reading per channel as a left and a right bar with a LUFS scale,
/// and an optional target line.
@MainActor
final class LoudnessMeterView: NSView {
    static let width: CGFloat = 56
    static let floorLUFS = -54.0

    let editor: EditorController
    private var drawnKey: [Int]?

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var modeRect: NSRect { NSRect(x: 2, y: 5, width: bounds.width - 4, height: 18) }
    private var valueRect: NSRect { NSRect(x: 0, y: 27, width: bounds.width, height: 18) }
    private var unitRect: NSRect { NSRect(x: 0, y: 44, width: bounds.width, height: 12) }
    private var targetRect: NSRect { NSRect(x: 3, y: 60, width: bounds.width - 6, height: 18) }
    /// Both bars together; the left bar is the left half, the right bar the right half, with a gap.
    private var barRect: NSRect {
        NSRect(x: 6, y: 92, width: 17, height: max(20, bounds.height - 92 - 10))
    }

    private func barRect(channel: Int) -> NSRect {
        let r = barRect
        return NSRect(x: r.minX + CGFloat(channel) * 9, y: r.minY, width: 8, height: r.height)
    }

    private func y(forLUFS v: Double) -> CGFloat {
        let r = barRect
        let f = min(max((v - Self.floorLUFS) / -Self.floorLUFS, 0), 1)
        return r.maxY - r.height * CGFloat(f)
    }

    func refresh() {
        let s = AppSettings.shared
        let key = [LoudnessMode.allCases.firstIndex(of: s.loudnessMode)!, Int(s.loudnessTarget), Int(bounds.height)]
            + ([editor.loudnessReading] + editor.loudnessChannelReadings).map { $0.isFinite ? Int(($0 * 10).rounded()) : Int.min }
        guard key != drawnKey else { return }
        drawnKey = key
        needsDisplay = true
    }

    private func color(for v: Double, target: Double) -> NSColor {
        guard target != 0, v.isFinite else { return Theme.accent }
        if v > target + 1 { return NSColor(hex: 0xE8913A) }
        if v >= target - 1 { return NSColor(hex: 0x5DBB63) }
        return Theme.accent
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = AppSettings.shared
        let v = editor.loudnessReading
        let target = s.loudnessTarget
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        NSColor(white: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: modeRect, xRadius: 4, yRadius: 4).fill()
        HeaderDrawing.text(s.loudnessMode.title, in: modeRect, size: 8, color: Theme.primaryText, align: .center,
                           weight: .semibold, mono: false)
        HeaderDrawing.text(v.isFinite ? String(format: "%.1f", v) : "-inf", in: valueRect, size: 14,
                           color: v.isFinite ? color(for: v, target: target) : Theme.secondaryText, align: .center, weight: .medium)
        HeaderDrawing.text("LUFS", in: unitRect, size: 9, color: Theme.secondaryText, align: .center, mono: false)
        NSColor(white: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: targetRect, xRadius: 4, yRadius: 4).fill()
        HeaderDrawing.text(target == 0 ? "No target" : String(format: "Target %.0f", target), in: targetRect, size: 9,
                           color: Theme.secondaryText, align: .center, mono: false)

        let bar = barRect
        for (channel, cv) in editor.loudnessChannelReadings.enumerated() {
            let r = barRect(channel: channel)
            NSColor(white: 1, alpha: 0.06).setFill()
            r.fill()
            if cv.isFinite, cv > Self.floorLUFS {
                color(for: cv, target: target).setFill()
                let top = y(forLUFS: cv)
                NSRect(x: r.minX, y: top, width: r.width, height: r.maxY - top).fill()
            }
        }
        var mark = 0.0
        while mark >= Self.floorLUFS {
            let yy = y(forLUFS: mark)
            NSColor(white: 1, alpha: 0.25).setFill()
            NSRect(x: bar.maxX + 1, y: yy.rounded() - 0.5, width: 3, height: 1).fill()
            HeaderDrawing.text(String(format: "%.0f", mark), in: NSRect(x: bar.maxX + 5, y: yy - 6, width: 26, height: 12),
                               size: 9, color: Theme.secondaryText)
            mark -= 6
        }
        if target != 0 {
            let yy = y(forLUFS: target)
            Theme.accent.setFill()
            NSRect(x: bar.minX - 3, y: yy - 1, width: bar.width + 6, height: 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let s = AppSettings.shared
        if modeRect.contains(p) {
            s.loudnessMode = s.loudnessMode.next
        } else if targetRect.contains(p) {
            let targets = AppSettings.loudnessTargets
            let i = targets.firstIndex(of: s.loudnessTarget) ?? 0
            s.loudnessTarget = targets[(i + 1) % targets.count]
        } else {
            editor.resetLoudness()
        }
        refresh()
    }

    override func resetCursorRects() {
        addCursorRect(modeRect, cursor: .pointingHand)
        addCursorRect(targetRect, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        toolTip = nil
        removeAllToolTips()
        addToolTip(modeRect, owner: self, userData: nil)
        addToolTip(targetRect, owner: self, userData: nil)
        addToolTip(NSRect(x: 0, y: valueRect.minY, width: bounds.width, height: bounds.height - valueRect.minY), owner: self,
                   userData: nil)
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }
}

extension LoudnessMeterView: NSViewToolTipOwner {
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                          userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated {
            if modeRect.contains(point) { return "Loudness reading: momentary (400 ms), short term (3 s) or integrated. Click to switch." }
            if targetRect.contains(point) { return "Target line: none, -14, -16 or -23 LUFS. Click to switch." }
            return "Loudness of what plays (ITU-R BS.1770), with a bar for the left and the right channel. Integrated restarts with playback. Click to reset it."
        }
    }
}
