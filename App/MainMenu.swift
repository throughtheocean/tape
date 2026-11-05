import AppKit

/// Menu bar. Every editor command lives here with its key, so all of it is keyboard reachable.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Tape")
        app.addItem(withTitle: "About Tape", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Tape", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Tape", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New", #selector(AppDelegate.newDocument(_:)), "n")
        item(file, "Open...", #selector(AppDelegate.openDocument(_:)), "o")
        file.addItem(.separator())
        item(file, "Import Audio...", #selector(MainWindowController.importAudio(_:)), "i")
        file.addItem(.separator())
        item(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        item(file, "Save", #selector(MainWindowController.saveDocument(_:)), "s")
        item(file, "Save As...", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift])

        let edit = submenu(main, "Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")

        let view = submenu(main, "View")
        item(view, "Zoom In", #selector(MainWindowController.zoomInTimeline(_:)), "=")
        item(view, "Zoom Out", #selector(MainWindowController.zoomOutTimeline(_:)), "-")
        item(view, "Zoom to Fit", #selector(MainWindowController.zoomToFit(_:)), "z", [.shift])
        view.addItem(.separator())
        item(view, "Snap to Zero Crossing", #selector(MainWindowController.toggleSnapToZero(_:)), "n", [])
        view.addItem(.separator())
        item(view, "Hide Inspector", #selector(MainWindowController.toggleInspector(_:)), "i", [.command, .option])
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let play = submenu(main, "Playback")
        item(play, "Play", #selector(MainWindowController.togglePlay(_:)), " ", [])
        item(play, "Play Reverse", #selector(MainWindowController.shuttleBackward(_:)), "j", [])
        item(play, "Stop", #selector(MainWindowController.stopTransport(_:)), "k", [])
        item(play, "Play Forward", #selector(MainWindowController.shuttleForward(_:)), "l", [])
        play.addItem(.separator())
        item(play, "Set Range Start", #selector(MainWindowController.setRangeIn(_:)), "i", [])
        item(play, "Set Range End", #selector(MainWindowController.setRangeOut(_:)), "o", [])
        item(play, "Clear Range", #selector(MainWindowController.clearRange(_:)), "x", [.option])
        play.addItem(.separator())
        item(play, "Loop Playback", #selector(MainWindowController.toggleLoop(_:)), "l")
        play.addItem(.separator())
        item(play, "Go to Beginning", #selector(MainWindowController.goToStart(_:)), key(NSHomeFunctionKey), [])
        item(play, "Go to End", #selector(MainWindowController.goToEnd(_:)), key(NSEndFunctionKey), [])

        let window = submenu(main, "Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    @discardableResult
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = modifiers
        menu.addItem(i)
        return i
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(UInt16(functionKey))!))
    }
}
