import Foundation

/// Pure edits on the document model. Each returns the changed project; the app wraps one call in one undo step.
public enum EditOperations {
    /// Shortest region an edit may leave, in frames.
    public static let minimumLength: Int64 = 16

    // MARK: Blade

    /// Splits every region (or only `ids`) that strictly contains one of `frames`.
    /// The left part keeps the fade in, the right part keeps the fade out. Returns the ids of the new right parts.
    /// Regions connected to a split region at or after the cut move their connection to the right part.
    @discardableResult
    public static func blade(_ project: inout Project, at frames: [Int64], only ids: Set<UUID>? = nil) -> [UUID] {
        var created: [UUID] = []
        var splits: [(left: UUID, right: UUID, frame: Int64)] = []
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
                splits.append((region.id, right.id, frame))
            }
            project.regions = next
        }
        for split in splits {
            for i in project.regions.indices {
                guard let anchor = project.regions[i].anchor, anchor.regionId == split.left,
                      project.regions[i].position >= split.frame else { continue }
                project.regions[i].anchor = Anchor(regionId: split.right, offset: project.regions[i].position - split.frame)
            }
        }
        project.sortRegions()
        return created
    }

    // MARK: Delete

    /// Removes `ids`. With `ripple`, per track, the timeline span the removed regions covered, minus what remaining
    /// regions of that track still cover, is closed by moving the track's later regions left. Other tracks stay.
    public static func delete(_ project: inout Project, ids: Set<UUID>, ripple: Bool) {
        let removed = project.regions.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        project.regions.removeAll { ids.contains($0.id) }
        if ripple {
            for track in Set(removed.map(\.trackId)) {
                let remaining = project.regions.filter { $0.trackId == track }
                let gaps = subtract(union(removed.filter { $0.trackId == track }.map(\.timelineRange)),
                                    union(remaining.map(\.timelineRange)))
                for gap in gaps.reversed() {
                    for i in project.regions.indices where project.regions[i].trackId == track && project.regions[i].position >= gap.end {
                        project.regions[i].position -= gap.length
                    }
                }
            }
        }
        project.sortRegions()
    }

    // MARK: Remove range

    /// Cuts `range` out of the regions on `tracks`: they are split at its edges and the parts inside go.
    /// With `ripple` everything on those tracks after the range moves left by its length; without, the time stays
    /// empty, and on a magnetic track a gap region of the range's length keeps the sequence. Other tracks stay.
    public static func removeRange(_ project: inout Project, _ range: SampleRange, tracks: Set<UUID>, ripple: Bool) {
        guard !range.isEmpty else { return }
        let hit = Set(project.regions.filter {
            tracks.contains($0.trackId) && $0.position < range.end && $0.end > range.start
        }.map(\.id))
        guard !hit.isEmpty else { return }
        let created = blade(&project, at: [range.start, range.end], only: hit)
        let candidates = hit.union(created)
        let inside = Set(project.regions.filter {
            candidates.contains($0.id) && $0.position >= range.start && $0.end <= range.end
        }.map(\.id))
        let emptied = Set(project.regions.filter { inside.contains($0.id) }.map(\.trackId))
        project.regions.removeAll { inside.contains($0.id) }
        if ripple {
            for i in project.regions.indices where tracks.contains(project.regions[i].trackId)
                && project.regions[i].position >= range.end {
                project.regions[i].position -= range.length
            }
        } else {
            for track in emptied where project.track(track)?.magnetic == true {
                project.regions.append(.gap(track: track, position: range.start, length: range.length))
            }
        }
        project.sortRegions()
    }

    // MARK: Duplicate

    /// Copies `ids` and places the copies right after the selection's span, on their own tracks; later regions
    /// on those tracks move right by the span. Returns the ids of the copies.
    @discardableResult
    public static func duplicate(_ project: inout Project, ids: Set<UUID>) -> [UUID] {
        let selected = project.regions.filter { ids.contains($0.id) }
        guard let start = selected.map(\.position).min(), let end = selected.map(\.end).max() else { return [] }
        let span = end - start
        let tracks = Set(selected.map(\.trackId))
        for i in project.regions.indices where !ids.contains(project.regions[i].id) && project.regions[i].position >= end
            && tracks.contains(project.regions[i].trackId) {
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

    // MARK: Copy and overwrite

    /// Adds a copy of every region in `ids`, in place, with the id from `newIDs` (a fresh one when missing).
    /// Everything except the id is kept. Returns the copies' ids.
    @discardableResult
    public static func copy(_ project: inout Project, ids: Set<UUID>, newIDs: [UUID: UUID] = [:]) -> [UUID] {
        var copies: [UUID] = []
        for var r in project.regions where ids.contains(r.id) {
            r.id = newIDs[r.id] ?? UUID()
            project.regions.append(r)
            copies.append(r.id)
        }
        project.sortRegions()
        return copies
    }

    /// Regions in `ids` cover what lies under them on their own track: every other region there loses the covered
    /// part. A region covered in the middle splits in two, one covered entirely is removed. A cut edge has no
    /// fade; an untouched edge keeps its fade. Regions on other tracks and the regions in `ids` stay as they are.
    /// `pieceID` names the second and later pieces of a split region (a live drag passes stable ones).
    public static func overwrite(_ project: inout Project, by ids: Set<UUID>,
                                 pieceID: (UUID, Int) -> UUID = { _, _ in UUID() }) {
        let top = project.regions.filter { ids.contains($0.id) }
        guard !top.isEmpty else { return }
        var next: [Region] = []
        for r in project.regions {
            let covers = top.filter { $0.trackId == r.trackId }.map(\.timelineRange).filter { $0.start < r.end && $0.end > r.position }
            guard !ids.contains(r.id), !covers.isEmpty else {
                next.append(r)
                continue
            }
            let pieces = subtract([r.timelineRange], union(covers))
            for (k, piece) in pieces.enumerated() {
                var p = r
                if k > 0 { p.id = pieceID(r.id, k) }
                p.sourceIn = r.sourceIn + (piece.start - r.position)
                p.sourceOut = p.sourceIn + piece.length
                p.position = piece.start
                if piece.start != r.position { p.fadeIn = .none }
                if piece.end != r.end { p.fadeOut = .none }
                fitFades(&p)
                next.append(p)
            }
        }
        project.regions = next
        project.sortRegions()
    }

    /// Puts `regions` on `track` one after another from `start` (a file drop over a lane). With `overwrite` they
    /// cover what lies under them, else they overlap and sum. On a magnetic track they are inserted into the
    /// sequence at `start` instead. Returns their ids.
    @discardableResult
    public static func place(_ project: inout Project, _ regions: [Region], track: UUID, at start: Int64, overwrite: Bool) -> [UUID] {
        var position = max(0, start)
        var ids: [UUID] = []
        for var r in regions {
            r.trackId = track
            r.position = position
            position += r.length
            project.regions.append(r)
            ids.append(r.id)
        }
        project.sortRegions()
        if isMagnetic(project, track) {
            insert(&project, ids: Set(ids), track: track)
        } else if overwrite {
            self.overwrite(&project, by: Set(ids))
        }
        return ids
    }

    /// Start for a block of `lengths` dropped at `start`: moved so one of its edges lands on a target within
    /// `tolerance`, as a region drag snaps.
    public static func snappedStart(_ start: Int64, lengths: [Int64], targets: [Int64], tolerance: Int64) -> Int64 {
        var edges = [start]
        for l in lengths { edges.append(edges.last! + l) }
        return max(0, start + (snapCorrection(edges: edges, targets: targets, tolerance: tolerance) ?? 0))
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
    /// and the minimum length. Fades shrink to fit. On a magnetic track the start stays where it is and the
    /// region gets shorter or longer at the front; `settle` then shifts what follows.
    public static func trimStart(_ project: inout Project, id: UUID, to frame: Int64) {
        guard let i = project.regions.firstIndex(where: { $0.id == id }) else { return }
        var r = project.regions[i]
        let magnetic = isMagnetic(project, r.trackId)
        let earliest = r.position - r.sourceIn
        let latest = r.end - minimumLength
        let target = min(max(frame, earliest, magnetic ? earliest : 0), latest)
        let delta = target - r.position
        if !magnetic { r.position += delta }
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

    // MARK: Tracks

    /// Moves `ids` by `lanes` tracks (positive is down), as a block: limited so every region stays on a track.
    /// Only `trackId` changes. Returns the lanes applied.
    @discardableResult
    public static func moveToTrack(_ project: inout Project, ids: Set<UUID>, byLanes lanes: Int) -> Int {
        let indices = project.regions.filter { ids.contains($0.id) }.compactMap { project.trackIndex($0.trackId) }
        guard let lo = indices.min(), let hi = indices.max() else { return 0 }
        let applied = min(max(lanes, -lo), project.tracks.count - 1 - hi)
        guard applied != 0 else { return 0 }
        for i in project.regions.indices where ids.contains(project.regions[i].id) {
            if let t = project.trackIndex(project.regions[i].trackId) { project.regions[i].trackId = project.tracks[t + applied].id }
        }
        return applied
    }

    /// Adds an empty track at `index` (default: the end) with the next name and palette color. Returns its id.
    @discardableResult
    public static func addTrack(_ project: inout Project, at index: Int? = nil) -> UUID {
        let track = Track(name: project.nextTrackName, color: project.nextTrackColor)
        project.tracks.insert(track, at: min(max(index ?? project.tracks.count, 0), project.tracks.count))
        return track.id
    }

    /// Removes a track and its regions. The last track cannot be removed.
    public static func removeTrack(_ project: inout Project, id: UUID) {
        guard project.tracks.count > 1, let i = project.trackIndex(id) else { return }
        project.tracks.remove(at: i)
        project.regions.removeAll { $0.trackId == id }
    }

    /// Moves a track to `index` in the final order.
    public static func moveTrack(_ project: inout Project, id: UUID, to index: Int) {
        guard let i = project.trackIndex(id) else { return }
        let track = project.tracks.remove(at: i)
        project.tracks.insert(track, at: min(max(index, 0), project.tracks.count))
    }

    public static func updateTrack(_ project: inout Project, id: UUID, _ change: (inout Track) -> Void) {
        guard let i = project.trackIndex(id) else { return }
        change(&project.tracks[i])
        project.tracks[i].gainDB = min(max(project.tracks[i].gainDB, Track.silentDB), Track.maxGainDB)
        project.tracks[i].pan = min(max(project.tracks[i].pan, -1), 1)
        project.tracks[i].color = ((project.tracks[i].color % Track.paletteCount) + Track.paletteCount) % Track.paletteCount
    }

    public static func setMasterGain(_ project: inout Project, dB: Double) {
        project.master.gainDB = min(max(dB, Track.silentDB), Track.maxGainDB)
    }

    // MARK: Snapping

    /// Region edges and extra frames (the playhead) that a dragged edge can snap to, excluding `ids`.
    /// With `tracks`, only regions on those tracks count.
    public static func snapTargets(_ project: Project, excluding ids: Set<UUID>, extra: [Int64], tracks: Set<UUID>? = nil) -> [Int64] {
        var targets = extra
        for r in project.regions where !ids.contains(r.id) && (tracks == nil || tracks!.contains(r.trackId)) {
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

    /// The smallest shift that puts one of `edges` on a target within `tolerance`, or nil when none is close.
    public static func snapCorrection(edges: [Int64], targets: [Int64], tolerance: Int64) -> Int64? {
        var best: Int64?
        for edge in edges {
            if let t = nearest(edge, in: targets, tolerance: tolerance) {
                let correction = t - edge
                if best == nil || abs(correction) < abs(best!) { best = correction }
            }
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
