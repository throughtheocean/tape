import Foundation

/// A device's latency in one direction, from the Core Audio HAL, in the device's frames.
public struct DeviceLatency: Equatable, Sendable {
    /// `kAudioDevicePropertyLatency`.
    public var deviceFrames: Int
    /// `kAudioDevicePropertySafetyOffset`.
    public var safetyFrames: Int
    /// `kAudioStreamPropertyLatency` of the first stream.
    public var streamFrames: Int
    /// `kAudioDevicePropertyBufferFrameSize`, the IO buffer.
    public var bufferFrames: Int
    public var sampleRate: Double

    public init(deviceFrames: Int = 0, safetyFrames: Int = 0, streamFrames: Int = 0, bufferFrames: Int = 0, sampleRate: Double) {
        self.deviceFrames = deviceFrames
        self.safetyFrames = safetyFrames
        self.streamFrames = streamFrames
        self.bufferFrames = bufferFrames
        self.sampleRate = sampleRate
    }

    /// Between the converter and the IO buffer: what a buffer timestamp does not contain.
    public var hardwareSeconds: Double { Double(deviceFrames + safetyFrames + streamFrames) / max(sampleRate, 1) }
    public var bufferSeconds: Double { Double(bufferFrames) / max(sampleRate, 1) }
}

/// Where a recording made while playing belongs on the timeline.
///
/// Playback knows which timeline frame it hands to the output at which host time (`RenderAnchor`); the output
/// device makes it audible `outputLatency` later. The input stamps every buffer with the host time its first frame
/// reached the IO buffer; the sound reached the converter `inputLatency` earlier. A frame recorded at host time `t`
/// was played against what was audible at `t - inputLatency`, which playback rendered at
/// `t - inputLatency - outputLatency`. The IO buffers are in the timestamps, so they are not added again.
public enum Overdub {
    public struct RenderAnchor: Equatable, Sendable {
        /// Timeline frame of the first frame of the last buffer handed to the output.
        public var position: Int64
        /// Host time, in seconds, that frame goes to the output IO buffer.
        public var hostSeconds: Double
        public var speed: Int64

        public init(position: Int64, hostSeconds: Double, speed: Int64 = 1) {
            self.position = position
            self.hostSeconds = hostSeconds
            self.speed = speed
        }

        /// Timeline frame playback hands to the output at `hostSeconds`.
        public func position(atHostSeconds t: Double, sessionRate: Double) -> Double {
            Double(position) + (t - hostSeconds) * sessionRate * Double(speed)
        }
    }

    /// Timeline frame of the recorded frame captured at `capturedHostSeconds`.
    public static func position(of capturedHostSeconds: Double, render: RenderAnchor, inputLatency: Double, outputLatency: Double,
                                sessionRate: Double) -> Int64 {
        let played = capturedHostSeconds - inputLatency - outputLatency
        return Int64(render.position(atHostSeconds: played, sessionRate: sessionRate).rounded())
    }

    /// Host time of frame `index` of an input stream, from the stamp of one of its buffers.
    public static func hostSeconds(ofFrame index: Int64, anchorFrame: Int64, anchorHostSeconds: Double, sampleRate: Double) -> Double {
        anchorHostSeconds + Double(index - anchorFrame) / max(sampleRate, 1)
    }

    /// Round trip of input monitoring through the engine: the input's latency and buffer, then the output's.
    public static func monitoringSeconds(input: DeviceLatency, output: DeviceLatency) -> Double {
        input.hardwareSeconds + input.bufferSeconds + output.bufferSeconds + output.hardwareSeconds
    }
}

public extension Double {
    /// Mach host ticks to seconds.
    static func hostSeconds(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
    }
}
