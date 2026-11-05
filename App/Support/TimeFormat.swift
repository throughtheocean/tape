import Foundation

/// Formats session frames for readouts and the ruler.
struct TimeFormat {
    var display: TimeDisplay
    var frameRate: Double
    var sampleRate: Double

    func string(_ frames: Int64) -> String {
        let negative = frames < 0
        let f = abs(frames)
        let body: String
        switch display {
        case .samples:
            body = String(f)
        case .milliseconds:
            let ms = Int64((Double(f) / sampleRate * 1000).rounded(.down))
            body = String(format: "%02lld:%02lld:%02lld.%03lld", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        case .timecode:
            let nominal = Int64(frameRate.rounded())
            let total = Int64((Double(f) / sampleRate * frameRate).rounded(.down))
            let seconds = total / nominal
            body = String(format: "%02lld:%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60, total % nominal)
        }
        return negative ? "-" + body : body
    }

    /// Short ruler label for a tick at `frames`, given the tick step.
    func rulerLabel(_ frames: Int64, step: Int64) -> String {
        let stepSeconds = Double(step) / sampleRate
        if display == .samples || stepSeconds < 0.001 { return String(frames) }
        switch display {
        case .samples:
            return String(frames)
        case .timecode where stepSeconds >= 1 / frameRate - 1e-9:
            return string(frames)
        case .timecode, .milliseconds:
            let ms = Int64((Double(frames) / sampleRate * 1000).rounded())
            let stepMs = Double(step) / sampleRate * 1000
            if stepMs >= 1000 {
                return String(format: "%lld:%02lld", ms / 60000, ms / 1000 % 60)
            }
            return String(format: "%lld:%02lld.%03lld", ms / 60000, ms / 1000 % 60, ms % 1000)
        }
    }
}

enum RulerTicks {
    /// Major tick step in frames so labels are at least `minSpacing` points apart.
    static func step(samplesPerPoint: Double, sampleRate: Double, minSpacing: Double = 90, display: TimeDisplay, frameRate: Double) -> Int64 {
        let minFrames = samplesPerPoint * minSpacing
        // Samples display, and anything below one millisecond, steps 1, 2, 5, 10, 20, 50 samples.
        if display == .samples || minFrames < sampleRate * 0.001 {
            var s: Int64 = 1
            while Double(s) < minFrames {
                let d = String(s).first!
                s = d == "1" ? s * 2 : (d == "2" ? s / 2 * 5 : s * 2)
            }
            return s
        }
        let frameSeconds = 1 / frameRate
        let subSecond: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02]
        var candidates: [Double] = display == .timecode
            ? subSecond.filter { $0 < frameSeconds } + [frameSeconds, 2 * frameSeconds, 5 * frameSeconds, 10 * frameSeconds]
            : subSecond + [0.05, 0.1, 0.2, 0.5]
        candidates += [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        for seconds in candidates where seconds * sampleRate >= minFrames {
            return max(1, Int64((seconds * sampleRate).rounded()))
        }
        return Int64(7200 * sampleRate)
    }
}
