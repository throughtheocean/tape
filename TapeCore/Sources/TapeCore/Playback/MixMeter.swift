import Foundation

/// Peaks and loudness energy of played audio, handed from the render callback to the UI. One entry per played
/// chunk: `maxTracks` track peaks, `maxMasterChannels` master peaks, then per master channel the weighted sum of
/// squares of K-weighted samples, and the chunk's frame count. Single writer (render callback), single reader
/// (main thread). A reader that falls more than `capacity` entries behind skips ahead.
public final class MeterQueue: @unchecked Sendable {
    public static let maxTracks = 64
    public static let maxMasterChannels = 2
    static let energyIndex = maxTracks + maxMasterChannels
    static let framesIndex = energyIndex + maxMasterChannels
    public static let stride = framesIndex + 1
    static let capacity = 256

    private let entries: UnsafeMutablePointer<Float>
    private let writeIndex = AtomicInt64(0)
    private var readIndex: Int64 = 0

    init() {
        entries = .allocate(capacity: Self.capacity * Self.stride)
        entries.initialize(repeating: 0, count: Self.capacity * Self.stride)
    }

    deinit { entries.deallocate() }

    /// Render thread: copies one chunk's peaks.
    @inline(__always)
    func push(_ peaks: UnsafePointer<Float>) {
        let w = writeIndex.load()
        (entries + Int(w % Int64(Self.capacity)) * Self.stride).update(from: peaks, count: Self.stride)
        writeIndex.store(w + 1)
    }

    /// Main thread: the peak maximum of every entry since the last call, and each entry's loudness energy per
    /// channel and frames in play order, or nil when nothing was played.
    public func drain() -> (tracks: [Float], master: [Float], loudness: [(energies: [Double], frames: Double)])? {
        let w = writeIndex.load()
        if w - readIndex > Int64(Self.capacity) { readIndex = w - Int64(Self.capacity) }
        guard w > readIndex else { return nil }
        var out = [Float](repeating: 0, count: Self.energyIndex)
        var loudness: [(energies: [Double], frames: Double)] = []
        while readIndex < w {
            let e = entries + Int(readIndex % Int64(Self.capacity)) * Self.stride
            for i in 0..<Self.energyIndex { out[i] = max(out[i], e[i]) }
            if e[Self.framesIndex] > 0 {
                let energies = (0..<Self.maxMasterChannels).map { Double(e[Self.energyIndex + $0]) }
                loudness.append((energies, Double(e[Self.framesIndex])))
            }
            readIndex += 1
        }
        return (Array(out[0..<Self.maxTracks]), Array(out[Self.maxTracks..<Self.energyIndex]), loudness)
    }
}

/// Display behaviour of one peak meter: instant attack, falling at `fallDBPerSecond`, a hold marker
/// for `holdSeconds`, and a clip indicator latched until `resetClip`.
public struct MeterBallistics: Equatable, Sendable {
    public static let holdSeconds = 1.5
    public static let fallDBPerSecond = 24.0
    public static let clipLevel: Float = 0.9999
    public static let floorDB = -60.0

    /// Current level in dBFS, at least `floorDB`.
    public private(set) var levelDB = MeterBallistics.floorDB
    public private(set) var holdDB = MeterBallistics.floorDB
    public private(set) var clipped = false
    private var holdTime = 0.0
    private var lastTime: Double?

    public init() {}

    public static func dB(_ peak: Float) -> Double {
        peak > 0 ? max(20 * log10(Double(peak)), floorDB) : floorDB
    }

    /// Feeds the peak since the last update (0 for nothing played) at time `now` in seconds.
    public mutating func update(peak: Float, now: Double) {
        let dt = lastTime.map { max(0, now - $0) } ?? 0
        lastTime = now
        let incoming = Self.dB(peak)
        levelDB = max(incoming, levelDB - Self.fallDBPerSecond * dt)
        if incoming >= holdDB {
            holdDB = incoming
            holdTime = now
        } else if now - holdTime > Self.holdSeconds {
            holdDB = levelDB
        }
        if peak >= Self.clipLevel { clipped = true }
    }

    public mutating func resetClip() { clipped = false }
}
