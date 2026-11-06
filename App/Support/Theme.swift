import AppKit
import SwiftUI

enum Theme {
    static let chrome = NSColor(hex: 0x1C1C1E)
    static let timeline = NSColor(hex: 0x0F0F10)
    static let separator = NSColor(white: 1, alpha: 0.08)
    static let secondaryText = NSColor(white: 1, alpha: 0.55)
    static let primaryText = NSColor(white: 1, alpha: 0.9)
    static let range = NSColor(hex: 0xF5C542)
    static let playhead = NSColor.white

    @MainActor static var accent: NSColor { AppSettings.shared.accentColor }

    /// Track palette; color 0 is the accent, so a one track document looks as before tracks existed.
    @MainActor static func trackColor(_ index: Int) -> NSColor {
        let palette: [UInt32] = [0, 0xE8913A, 0x5DBB63, 0xA77BDB, 0xE05D5D, 0xD9C44A, 0x3FB8B0, 0xE070A8]
        let i = ((index % palette.count) + palette.count) % palette.count
        return i == 0 ? accent : NSColor(hex: palette[i])
    }

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

    /// Straight sRGB components for Metal.
    var rgba: SIMD4<Float> {
        let c = usingColorSpace(.sRGB) ?? self
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
    }

    var hexValue: UInt32 {
        let c = usingColorSpace(.sRGB) ?? self
        return UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
    }
}

extension Color {
    static let tapeChrome = Color(nsColor: Theme.chrome)
    static let tapeTimeline = Color(nsColor: Theme.timeline)
    static let tapeSecondary = Color(nsColor: Theme.secondaryText)
}
