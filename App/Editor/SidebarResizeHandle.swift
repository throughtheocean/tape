import AppKit

/// Invisible strip on the sidebar edge; dragging reports horizontal deltas.
@MainActor
final class SidebarResizeHandle: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag(x - lastX)
        lastX = x
    }
}
