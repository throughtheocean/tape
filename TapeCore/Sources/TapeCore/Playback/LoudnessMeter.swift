import Foundation

/// Live BS.1770 loudness from K-weighted energy as it is played: momentary (400 ms), short term (3 s) and
/// integrated (gated, since the last reset). Fed with the channel weighted sum of squares of K-weighted samples
/// per played chunk; bins them into the 100 ms steps the 75 percent overlapping 400 ms blocks need.
public struct LoudnessMeter: Sendable {
    public static let stepSeconds = 0.1
    static let momentarySteps = 4
    static let shortTermSteps = 30

    public let sampleRate: Double
    private let stepFrames: Double
    private var partialEnergy = 0.0
    private var partialFrames = 0.0
    /// Mean square per 100 ms step, the last `shortTermSteps`.
    private var recent: [Double] = []
    /// Mean square per 400 ms block since the last reset.
    private var blocks: [Double] = []

    public private(set) var momentary = -Double.infinity
    public private(set) var shortTerm = -Double.infinity
    public private(set) var integrated = -Double.infinity

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        stepFrames = (sampleRate * Self.stepSeconds).rounded()
    }

    static func lufs(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    /// `energy` is the weighted sum of squares over `frames` frames. A chunk crossing a step boundary is split
    /// in proportion to its frames.
    public mutating func add(energy: Double, frames: Double) {
        var energy = energy, frames = frames
        while frames > 0 {
            let take = min(frames, stepFrames - partialFrames)
            let part = energy * take / frames
            partialEnergy += part
            partialFrames += take
            energy -= part
            frames -= take
            if partialFrames >= stepFrames {
                completeStep(partialEnergy / stepFrames)
                partialEnergy = 0
                partialFrames = 0
            }
        }
    }

    private mutating func completeStep(_ meanSquare: Double) {
        recent.append(meanSquare)
        if recent.count > Self.shortTermSteps { recent.removeFirst(recent.count - Self.shortTermSteps) }
        guard recent.count >= Self.momentarySteps else { return }
        let block = recent.suffix(Self.momentarySteps).reduce(0, +) / Double(Self.momentarySteps)
        momentary = Self.lufs(block)
        shortTerm = Self.lufs(recent.reduce(0, +) / Double(recent.count))
        blocks.append(block)
        integrated = Self.gated(blocks)
    }

    /// Integrated loudness with the -70 LUFS absolute and -10 LU relative gates.
    static func gated(_ blocks: [Double]) -> Double {
        let absolute = pow(10, (-70 + 0.691) / 10)
        var sum = 0.0, count = 0
        for z in blocks where z > absolute {
            sum += z
            count += 1
        }
        guard count > 0 else { return -.infinity }
        let relative = sum / Double(count) * 0.1
        sum = 0
        count = 0
        for z in blocks where z > absolute && z > relative {
            sum += z
            count += 1
        }
        return count > 0 ? lufs(sum / Double(count)) : -.infinity
    }

    /// Starts a new measurement: all three readings go back to -inf.
    public mutating func reset() {
        clearRunning()
        blocks = []
        integrated = -.infinity
    }

    /// Playback stopped: momentary and short term have nothing to measure; integrated keeps its value.
    public mutating func clearRunning() {
        partialEnergy = 0
        partialFrames = 0
        recent = []
        momentary = -.infinity
        shortTerm = -.infinity
    }
}

/// The combined loudness of all channels plus one meter per channel. A channel's meter reads as if every channel
/// carried that channel's signal, so identical channels all read the combined value.
public struct ChannelLoudness: Sendable {
    public private(set) var total: LoudnessMeter
    public private(set) var channels: [LoudnessMeter]

    public init(sampleRate: Double, channelCount: Int) {
        total = LoudnessMeter(sampleRate: sampleRate)
        channels = Array(repeating: LoudnessMeter(sampleRate: sampleRate), count: max(1, channelCount))
    }

    public var sampleRate: Double { total.sampleRate }

    /// `energies` holds each channel's weighted sum of squares over `frames` frames; extra entries are ignored.
    public mutating func add(energies: [Double], frames: Double) {
        let count = min(energies.count, channels.count)
        total.add(energy: energies.prefix(count).reduce(0, +), frames: frames)
        for c in 0..<count { channels[c].add(energy: energies[c] * Double(channels.count), frames: frames) }
    }

    public mutating func reset() {
        total.reset()
        for c in channels.indices { channels[c].reset() }
    }

    public mutating func clearRunning() {
        total.clearRunning()
        for c in channels.indices { channels[c].clearRunning() }
    }
}
