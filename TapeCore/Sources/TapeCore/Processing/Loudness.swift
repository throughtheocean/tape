import Accelerate
import Foundation

/// ITU-R BS.1770-4 loudness and true peak.
public enum Loudness {
    // MARK: K-weighting

    /// Biquad coefficients `[b0, b1, b2, a1, a2]` of the two K-weighting stages for `sampleRate`, derived from
    /// the analog prototype (shelf at 1681.97 Hz, +4 dB; high pass at 38.135 Hz) so they hold at any rate.
    public static func kWeighting(sampleRate fs: Double) -> [Double] {
        // Stage 1: high shelf.
        var f0 = 1681.974450955533
        let gainDB = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                     2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        // Stage 2: high pass.
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highPass = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        return shelf + highPass
    }

    /// Channel weights: 1 for left, right and centre, 1.41 for the surrounds of a 5.1 layout, LFE excluded.
    static func weights(channelCount: Int) -> [Double] {
        guard channelCount == 6 else { return Array(repeating: 1, count: channelCount) }
        return [1, 1, 1, 0, 1.41, 1.41]
    }

    // MARK: Integrated loudness

    /// Mean square of the K-weighted signal per 400 ms block, 75 percent overlap, per channel.
    static func blockPowers(_ input: AudioBuffer, range: SampleRange) -> [[Double]] {
        let r = range.clamped(to: input.all)
        let fs = input.sampleRate
        let blockLength = Int((0.4 * fs).rounded())
        let hop = Int((0.1 * fs).rounded())
        let n = Int(r.length)
        guard n >= blockLength else { return [] }
        let blockCount = (n - blockLength) / hop + 1
        let coefficients = kWeighting(sampleRate: fs)
        var powers = [[Double]](repeating: [Double](repeating: 0, count: input.channelCount), count: blockCount)

        guard let setup = vDSP_biquad_CreateSetup(coefficients, 2) else { return [] }
        defer { vDSP_biquad_DestroySetup(setup) }
        var filtered = [Float](repeating: 0, count: n)
        var squares = [Double](repeating: 0, count: n + 1)
        for c in 0..<input.channelCount {
            var delay = [Float](repeating: 0, count: 2 * 2 + 2)
            input.channels[c].withUnsafeBufferPointer { src in
                vDSP_biquad(setup, &delay, src.baseAddress! + Int(r.start), 1, &filtered, 1, vDSP_Length(n))
            }
            // Running sum of squares in double precision, so long programmes do not drift.
            var sum = 0.0
            for i in 0..<n {
                let v = Double(filtered[i])
                sum += v * v
                squares[i + 1] = sum
            }
            for b in 0..<blockCount {
                let s = b * hop
                powers[b][c] = (squares[s + blockLength] - squares[s]) / Double(blockLength)
            }
        }
        return powers
    }

    /// Integrated loudness in LUFS of `range`, with the -70 LUFS absolute and -10 LU relative gates.
    /// `-infinity` for silence or material shorter than one block.
    public static func integrated(_ input: AudioBuffer, range: SampleRange? = nil) -> Double {
        let powers = blockPowers(input, range: range ?? input.all)
        let g = weights(channelCount: input.channelCount)
        let blocks = powers.map { p in zip(p, g).reduce(0) { $0 + $1.0 * $1.1 } }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        let absolute = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return -.infinity }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    // MARK: True peak

    static let oversampling = 4
    static let halfTaps = 24

    /// Polyphase windowed sinc interpolator: `phases[p][j]` weights `x[k + j - halfTaps + 1]` for the value at
    /// `k + p / 4`. Kaiser window, beta 9.
    static let phases: [[Float]] = {
        func bessel0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum {
                term *= (x / (2 * k)) * (x / (2 * k))
                sum += term
                k += 1
            }
            return sum
        }
        let beta = 9.0
        let span = Double(halfTaps)
        return (0..<oversampling).map { p in
            let d = Double(p) / Double(oversampling)
            return (0..<(2 * halfTaps)).map { j in
                let m = Double(j - halfTaps + 1)
                let t = d - m
                let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
                let ratio = t / span
                let window = abs(ratio) >= 1 ? 0 : bessel0(beta * sqrt(1 - ratio * ratio)) / bessel0(beta)
                return Float(sinc * window)
            }
        }
    }()

    /// Largest absolute value of the 4x oversampled signal over all channels, linear.
    public static func truePeak(_ input: AudioBuffer, range: SampleRange? = nil) -> Float {
        let r = (range ?? input.all).clamped(to: input.all)
        guard !r.isEmpty else { return 0 }
        let taps = 2 * halfTaps
        let chunk = 1 << 18
        var peak: Float = 0
        var padded = [Float](repeating: 0, count: chunk + taps)
        var out = [Float](repeating: 0, count: chunk)
        for c in input.channels {
            var start = Int(r.start)
            while start < Int(r.end) {
                let n = min(chunk, Int(r.end) - start)
                // padded[i] = x[start + i - halfTaps + 1], zero outside the range.
                for i in 0..<(n + taps - 1) {
                    let f = start + i - halfTaps + 1
                    padded[i] = f >= Int(r.start) && f < Int(r.end) ? c[f] : 0
                }
                for phase in phases {
                    phase.withUnsafeBufferPointer { h in
                        vDSP_conv(padded, 1, h.baseAddress!, 1, &out, 1, vDSP_Length(n), vDSP_Length(taps))
                    }
                    var m: Float = 0
                    vDSP_maxmgv(out, 1, &m, vDSP_Length(n))
                    peak = max(peak, m)
                }
                start += n
            }
        }
        return peak
    }

    public static func truePeakDB(_ input: AudioBuffer, range: SampleRange? = nil) -> Double {
        let p = truePeak(input, range: range)
        return p > 0 ? 20 * log10(Double(p)) : -.infinity
    }
}
