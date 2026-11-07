import AppKit

extension Theme {
    static let timeline = canvas

    @MainActor static var accent: NSColor { AppSettings.shared.accentColor }

    /// Track palette; color 0 is the accent, so a one track document looks as before tracks existed.
    @MainActor static func trackColor(_ index: Int) -> NSColor {
        let palette: [UInt32] = [0, 0xE8913A, 0x5DBB63, 0xA77BDB, 0xE05D5D, 0xD9C44A, 0x3FB8B0, 0xE070A8]
        let i = ((index % palette.count) + palette.count) % palette.count
        return i == 0 ? accent : NSColor(hex: palette[i])
    }
}

extension NSColor {
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
