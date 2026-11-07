// Shared visual tokens. Origin: Tape (App/Support/Theme.swift).
// This file is identical in Tape and Paradise Player (ParadisePlayer/Sources/Views/Theme.swift):
// change it in Tape and copy it over. App specific additions live in Theme+Tape.swift and
// Theme+Paradise.swift. Dark only.
import AppKit
import SwiftUI

enum Theme {
    // Surfaces, darkest first.
    static let canvas = NSColor(hex: 0x0F0F10)
    static let chrome = NSColor(hex: 0x1C1C1E)
    /// Wells, tracks and controls that are off.
    static let control = NSColor(white: 1, alpha: 0.06)
    /// Selected row or header on chrome.
    static let selection = NSColor(white: 0.17, alpha: 1)
    static let separator = NSColor(white: 1, alpha: 0.08)

    static let primaryText = NSColor(white: 1, alpha: 0.9)
    static let secondaryText = NSColor(white: 1, alpha: 0.55)

    static let defaultAccent: UInt32 = 0x3B82F6
    static let range = NSColor(hex: 0xF5C542)
    static let red = NSColor(hex: 0xE05D5D)
    static let green = NSColor(hex: 0x34C759)
    static let playhead = NSColor.white

    // Metrics.
    static let controlHeight: CGFloat = 22
    static let radius: CGFloat = 3
    static let panelPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 6
    static let transportHeight: CGFloat = 52

    // Type scale.
    static let headerSize: CGFloat = 10
    static let smallSize: CGFloat = 11
    static let bodySize: CGFloat = 12
    static let elapsedSize: CGFloat = 13
    static let timecodeSize: CGFloat = 22

    static func monoDigits(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    static let tapeCanvas = Color(nsColor: Theme.canvas)
    static let tapeChrome = Color(nsColor: Theme.chrome)
    static let tapeControl = Color(nsColor: Theme.control)
    static let tapeSelection = Color(nsColor: Theme.selection)
    static let tapeSeparator = Color(nsColor: Theme.separator)
    static let tapePrimary = Color(nsColor: Theme.primaryText)
    static let tapeSecondary = Color(nsColor: Theme.secondaryText)
}

extension Font {
    /// Section header: 10 pt semibold, used uppercased in secondary.
    static let tapeHeader = Font.system(size: Theme.headerSize, weight: .semibold)
    static let tapeSmall = Font.system(size: Theme.smallSize)
    static let tapeBody = Font.system(size: Theme.bodySize)

    static func tapeMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}
