import Foundation

public enum ZeroCrossing {
    /// The frame nearest to `frame`, within `radius` frames, where the rendered mix crosses zero.
    /// A crossing between frames n-1 and n reports whichever of the two is closer to zero.
    /// Channels are summed, so a stereo crossing is where the mono sum crosses.
    /// Returns `frame` when there is no crossing within the radius.
    public static func nearest(in list: EditList, around frame: Int64, radius: Int) -> Int64 {
        guard radius > 0, list.channelCount > 0 else { return frame }
        let start = frame - Int64(radius) - 1
        let count = 2 * radius + 3
        let buffer = SampleBuffer(channelCount: list.channelCount, capacity: count)
        EditListRenderer(maxFrames: count).render(list, start: start, frames: count, into: buffer)

        var mix = [Float](repeating: 0, count: count)
        for c in 0..<list.channelCount {
            let p = buffer.channels[c]
            for i in 0..<count { mix[i] += p[i] }
        }

        var best: Int64?
        var bestDistance = Int64.max
        for i in 1..<count {
            let a = mix[i - 1], b = mix[i]
            let crosses = (a <= 0 && b > 0) || (a >= 0 && b < 0) || b == 0
            guard crosses else { continue }
            let index = (b == 0 || abs(b) < abs(a)) ? i : i - 1
            let candidate = start + Int64(index)
            let distance = abs(candidate - frame)
            if distance <= Int64(radius), distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best ?? frame
    }
}
