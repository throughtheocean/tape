import AppKit

/// A horseshoe magnet for the magnetic track buttons; SF Symbols has none.
enum MagnetIcon {
    /// Draws into the square centred in `rect`, opening up, poles in `tip`. `rect` is in unflipped coordinates.
    static func draw(in rect: NSRect, color: NSColor, tip: NSColor) {
        let side = min(rect.width, rect.height)
        let box = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let line = side * 0.3
        let radius = (side - line) / 2
        let centre = NSPoint(x: box.midX, y: box.minY + line / 2 + radius)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre.x - radius, y: box.maxY))
        path.line(to: NSPoint(x: centre.x - radius, y: centre.y))
        path.appendArc(withCenter: centre, radius: radius, startAngle: 180, endAngle: 360, clockwise: false)
        path.line(to: NSPoint(x: centre.x + radius, y: box.maxY))
        path.lineWidth = line
        color.setStroke()
        path.stroke()
        tip.setFill()
        let height = line * 0.9
        NSRect(x: centre.x - radius - line / 2, y: box.maxY - height, width: line, height: height).fill()
        NSRect(x: centre.x + radius - line / 2, y: box.maxY - height, width: line, height: height).fill()
    }

    static func image(size: CGFloat, color: NSColor, tip: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, color: color, tip: tip)
            return true
        }
    }

    /// Colours for a button: dark on the accent when on, secondary text when off.
    static func image(size: CGFloat, on: Bool) -> NSImage {
        on ? image(size: size, color: NSColor(white: 0, alpha: 0.85), tip: NSColor(white: 1, alpha: 0.9))
            : image(size: size, color: Theme.secondaryText, tip: Theme.primaryText)
    }
}
