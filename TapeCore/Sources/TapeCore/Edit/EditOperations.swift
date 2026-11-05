import Foundation

/// Pure edits on the document model. Each returns the changed project; the app wraps one call in one undo step.
public enum EditOperations {
    /// Shortest region an edit may leave, in frames.
    public static let minimumLength: Int64 = 16

    // MARK: Blade

    /// Splits every region (or only `ids`) that strictly contains one of `frames`.
    /// The left part keeps the fade in, the right part keeps the fade out. Returns the ids of the new right parts.
    @discardableResult
    public static func blade(_ project: inout Project, at frames: [Int64], only ids: Set<UUID>? = nil) -> [UUID] {
        var created: [UUID] = []
        for frame in Set(frames).sorted() {
            var next: [Region] = []
            for region in project.regions {
                guard ids == nil || ids!.contains(region.id) || created.contains(region.id),
                      frame > region.position, frame < region.end else {
                    next.append(region)
                    continue
                }
                let cut = frame - region.position
                var left = region
                left.sourceOut = region.sourceIn + cut
                left.fadeOut = .none
                left.fadeIn.length = min(left.fadeIn.length, left.length)
                var right = region
                right.id = UUID()
                right.sourceIn = region.sourceIn + cut
                right.position = frame
                right.fadeIn = .none
                right.fadeOut.length = min(right.fadeOut.length, right.length)
                next.append(left)
                next.append(right)
                created.append(right.id)
            }
            project.regions = next
        }
        project.sortRegions()
        return created
    }

    // MARK: Delete

    /// Removes `ids`. With `ripple`, the timeline span the removed regions covered, minus what remaining
    /// regions still cover, is closed by moving later regions left.
    public static func delete(_ project: inout Project, ids: Set<UUID>, ripple: Bool) {
        let removed = project.regions.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        project.regions.removeAll { ids.contains($0.id) }
        if ripple {
            let gaps = subtract(union(removed.map(\.timelineRange)), union(project.regions.map(\.timelineRange)))
            for gap in gaps.reversed() {
                for i in project.regions.indices where project.regions[i].position >= gap.end {
                    project.regions[i].position -= gap.length
                }
            }
        }
        project.sortRegions()
    }

    // MARK: Duplicate

    /// Copies `ids` and places the copies right after the selection's span; later regions move right by the span.
    /// Returns the ids of the copies.
    @discardableResult
    public static func duplicate(_ project: inout Project, ids: Set<UUID>) -> [UUID] {
        let selected = project.regions.filter { ids.contains($0.id) }
        guard let start = selected.map(\.position).min(), let end = selected.map(\.end).max() else { return [] }
        let span = end - start
        for i in project.regions.indices where !ids.contains(project.regions[i].id) && project.regions[i].position >= end {
            project.regions[i].position += span
        }
        var copies: [UUID] = []
        for var r in selected {
            r.id = UUID()
            r.position += span
            project.regions.append(r)
            copies.append(r.id)
        }
        project.sortRegions()
        return copies
    }

    // MARK: Move and trim

    /// Moves `ids` by `delta`, limited so no region starts before 0. Returns the delta applied.
    @discardableResult
    public static func move(_ project: inout Project, ids: Set<UUID>, by delta: Int64) -> Int64 {
        let first = project.regions.filter { ids.contains($0.id) }.map(\.position).min() ?? 0
        let applied = max(delta, -first)
        for i in project.regions.indices where ids.contains(project.regions[i].id) {
            project.regions[i].position += applied
        }
        project.sortRegions()
        return applied
    }

    /// Moves the region's start to `frame` (timeline), keeping its end; limited by the source start
    /// and the minimum length. Fades shrink to fit.
    public static func trimStart(_ project: inout Project, id: UUID, to frame: Int64) {
        guard let i = project.regions.firstIndex(where: { $0.id == id }) else { return }
        var r = project.regions[i]
        let earliest = r.position - r.sourceIn
        let latest = r.end - minimumLength
        let target = min(max(frame, earliest, 0), latest)
        let delta = target - r.position
        r.position += delta
        r.sourceIn += delta
        fitFades(&r)
        project.regions[i] = r
        project.sortRegions()
    }

    /// Moves the region's end to `frame` (timeline); limited by the source end (`sourceLength`, session frames)
    /// and the minimum length.
    public static func trimEnd(_ project: inout Project, id: UUID, to frame: Int64, sourceLength: Int64) {
        guard let i = project.regions.firstIndex(where: { $0.id == id }) else { return }
        var r = project.regions[i]
        let latest = r.position + (sourceLength - r.sourceIn)
        let target = min(max(frame, r.position + minimumLength), latest)
        r.sourceOut = r.sourceIn + (target - r.position)
        fitFades(&r)
        project.regions[i] = r
    }

    // MARK: Fades and gain

    public enum FadeEnd: Sendable { case fadeIn, fadeOut }

    /// Sets the fade length, clamped so fade in plus fade out never exceed the region.
    public static func setFadeLength(_ project: inout Project, ids: Set<UUID>, end: FadeEnd, length: Int64) {
        for i in project.regions.indices where ids.contains(project.regions[i].id) {
            var r = project.regions[i]
            switch end {
            case .fadeIn: r.fadeIn.length = min(max(length, 0), r.length - r.fadeOut.length)
            case .fadeOut: r.fadeOut.length = min(max(length, 0), r.length - r.fadeIn.length)
            }
            project.regions[i] = r
        }
    }

    /// Shape as one continuous value: 0 linear, 1 S curve, 2 log, 3 exp, fractions blend to the next.
    public static func setFadeShape(_ project: inout Project, ids: Set<UUID>, end: FadeEnd, continuous value: Double) {
        let (shape, blend) = shape(continuous: value)
        for i in project.regions.indices where ids.contains(project.regions[i].id) {
            switch end {
            case .fadeIn:
                project.regions[i].fadeIn.shape = shape
                project.regions[i].fadeIn.blend = blend
            case .fadeOut:
                project.regions[i].fadeOut.shape = shape
                project.regions[i].fadeOut.blend = blend
            }
        }
    }

    public static func shape(continuous value: Double) -> (FadeShape, Double) {
        let all = FadeShape.allCases
        let v = min(max(value, 0), Double(all.count - 1))
        let index = min(Int(v.rounded(.down)), all.count - 1)
        let blend = index == all.count - 1 ? 0 : v - Double(index)
        return (all[index], blend)
    }

    public static func continuous(_ fade: Fade) -> Double {
        Double(FadeShape.allCases.firstIndex(of: fade.shape) ?? 0) + fade.blend
    }

    /// Sets both fades of `ids` to `length` (the F key), keeping their shapes.
    public static func applyDefaultFades(_ project: inout Project, ids: Set<UUID>, length: Int64) {
        for i in project.regions.indices where ids.contains(project.regions[i].id) {
            let half = project.regions[i].length / 2
            project.regions[i].fadeIn.length = min(length, half)
            project.regions[i].fadeOut.length = min(length, half)
        }
    }

    public static func setGain(_ project: inout Project, ids: Set<UUID>, dB: Double) {
        for i in project.regions.indices where ids.contains(project.regions[i].id) {
            project.regions[i].gainDB = min(max(dB, -96), 24)
        }
    }

    public static func rename(_ project: inout Project, id: UUID, to name: String) {
        guard let i = project.regions.firstIndex(where: { $0.id == id }) else { return }
        project.regions[i].name = name
    }

    // MARK: Snapping

    /// Region edges and extra frames (the playhead) that a dragged edge can snap to, excluding `ids`.
    public static func snapTargets(_ project: Project, excluding ids: Set<UUID>, extra: [Int64]) -> [Int64] {
        var targets = extra
        for r in project.regions where !ids.contains(r.id) {
            targets.append(r.position)
            targets.append(r.end)
        }
        return targets
    }

    /// The target nearest to `frame` within `tolerance`, if any.
    public static func nearest(_ frame: Int64, in targets: [Int64], tolerance: Int64) -> Int64? {
        var best: Int64?
        for t in targets where abs(t - frame) <= tolerance {
            if best == nil || abs(t - frame) < abs(best! - frame) { best = t }
        }
        return best
    }

    // MARK: Helpers

    private static func fitFades(_ r: inout Region) {
        r.fadeIn.length = min(r.fadeIn.length, r.length)
        r.fadeOut.length = min(r.fadeOut.length, r.length - r.fadeIn.length)
    }

    static func union(_ ranges: [SampleRange]) -> [SampleRange] {
        var out: [SampleRange] = []
        for r in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, r.start <= last.end {
                out[out.count - 1].end = max(last.end, r.end)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Parts of `a` not covered by `b`; both sorted and disjoint.
    static func subtract(_ a: [SampleRange], _ b: [SampleRange]) -> [SampleRange] {
        var out: [SampleRange] = []
        for r in a {
            var pieces = [r]
            for cover in b {
                pieces = pieces.flatMap { p -> [SampleRange] in
                    guard cover.start < p.end, cover.end > p.start else { return [p] }
                    var parts: [SampleRange] = []
                    if cover.start > p.start { parts.append(SampleRange(start: p.start, end: cover.start)) }
                    if cover.end < p.end { parts.append(SampleRange(start: cover.end, end: p.end)) }
                    return parts
                }
            }
            out += pieces
        }
        return out
    }
}
