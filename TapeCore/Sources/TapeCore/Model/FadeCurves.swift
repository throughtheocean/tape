import Foundation

/// Fade-in gain curves as 4096 point lookup tables, linearly interpolated.
/// A fade-out uses the same curve mirrored in time.
public enum FadeCurves {
    public static let tableSize = 4096

    /// All tables back to back, indexed by `FadeShape` order in `allCases`.
    static let tables: [Float] = {
        var out = [Float]()
        out.reserveCapacity(tableSize * FadeShape.allCases.count)
        for shape in FadeShape.allCases {
            for i in 0..<tableSize {
                let x = Double(i) / Double(tableSize - 1)
                out.append(Float(analytic(shape, x)))
            }
            out[out.count - tableSize] = 0
            out[out.count - 1] = 1
        }
        return out
    }()

    /// Exact curve the tables are sampled from.
    public static func analytic(_ shape: FadeShape, _ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        switch shape {
        case .linear: return x
        case .sCurve: return 0.5 - 0.5 * cos(Double.pi * x)
        case .log: return log10(1 + 99 * x) / 2
        case .exp: return (pow(100, x) - 1) / 99
        }
    }

    static func shapeIndex(_ shape: FadeShape) -> Int {
        switch shape {
        case .linear: return 0
        case .sCurve: return 1
        case .log: return 2
        case .exp: return 3
        }
    }

    public static func table(_ shape: FadeShape) -> ArraySlice<Float> {
        let base = shapeIndex(shape) * tableSize
        return tables[base..<(base + tableSize)]
    }

    @inline(__always)
    static func lookup(_ table: UnsafePointer<Float>, _ x: Double) -> Float {
        if x <= 0 { return table[0] }
        if x >= 1 { return table[tableSize - 1] }
        let p = x * Double(tableSize - 1)
        let i = Int(p)
        let f = Float(p - Double(i))
        return table[i] + (table[i + 1] - table[i]) * f
    }

    /// Gain of a fade-in at normalised time `x` (0 start, 1 end).
    public static func value(_ fade: Fade, at x: Double) -> Float {
        tables.withUnsafeBufferPointer { buf in
            value(buf.baseAddress!, shape: fade.shape, blend: fade.blend, x: x)
        }
    }

    @inline(__always)
    static func value(_ base: UnsafePointer<Float>, shape: FadeShape, blend: Double, x: Double) -> Float {
        let a = lookup(base + shapeIndex(shape) * tableSize, x)
        guard blend > 0, let next = shape.next else { return a }
        let b = lookup(base + shapeIndex(next) * tableSize, x)
        let t = Float(min(blend, 1))
        return a + (b - a) * t
    }
}
