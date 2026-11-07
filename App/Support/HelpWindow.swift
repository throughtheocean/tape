import AppKit
import WebKit

/// Shows the bundled help page.
@MainActor
final class HelpWindow: NSWindowController {
    static let shared = HelpWindow()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Tape Help"
        window.setFrameAutosaveName("TapeHelp")
        window.isReleasedWhenClosed = false
        let web = WKWebView(frame: window.contentLayoutRect)
        if let url = Bundle.main.url(forResource: "TapeHelp", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        window.contentView = web
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
