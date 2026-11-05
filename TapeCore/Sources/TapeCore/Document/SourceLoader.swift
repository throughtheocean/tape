import Foundation

/// A source ready for playback and drawing.
public struct LoadedSource: @unchecked Sendable {
    public let ref: SourceRef
    public let source: FileSource
    public let peaks: PeakPyramid
    /// Seconds spent building the pyramid, nil if it came from the cache.
    public let peakBuildSeconds: Double?
}

public enum SourceLoader {
    /// Opens `ref` at `sessionRate`, resampling into the package cache and building or
    /// reading the peak pyramid as needed. Call off the main thread.
    public static func load(_ ref: SourceRef, in package: TapePackage, sessionRate: Double,
                            isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> LoadedSource {
        try package.ensureDirectories()
        let original = package.resolve(ref)
        var readable = original
        if ref.sampleRate != sessionRate {
            let cached = package.resampledURL(for: ref.id, sampleRate: sessionRate)
            if !FileManager.default.fileExists(atPath: cached.path) {
                try Resampler.convert(original, to: cached, sampleRate: sessionRate, isCancelled: isCancelled)
                try? FileManager.default.removeItem(at: package.peakURL(for: ref.id))
            }
            readable = cached
        }
        let source = try FileSource(url: readable)
        let peakURL = package.peakURL(for: ref.id)
        if let peaks = try? PeakPyramid.read(from: peakURL),
           peaks.frameCount == source.frameCount, peaks.channelCount == source.channelCount {
            return LoadedSource(ref: ref, source: source, peaks: peaks, peakBuildSeconds: nil)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let peaks = try PeakPyramid.build(url: readable, isCancelled: isCancelled)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        try? peaks.write(to: peakURL)
        return LoadedSource(ref: ref, source: source, peaks: peaks, peakBuildSeconds: elapsed)
    }
}
