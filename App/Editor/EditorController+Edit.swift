import AppKit
import TapeCore

/// Region edits. Each command is one undo step.
extension EditorController {
    var project: Project { document.project }

    /// Selected ids that still exist (undo can remove regions).
    var selectedIDs: Set<UUID> { selection.intersection(project.regions.map(\.id)) }

    var selectedRegions: [Region] { project.regions.filter { selection.contains($0.id) } }

    func frames(ms: Double) -> Int64 { Int64((ms / 1000 * sessionRate).rounded()) }

    func ms(frames: Int64) -> Double { Double(frames) / sessionRate * 1000 }

    /// Topmost visible region at `frame` on the selected track; later regions draw over earlier ones.
    func region(at frame: Double) -> Region? {
        project.regions.last { $0.trackId == selectedTrackID && Double($0.position) <= frame && frame < Double($0.end) }
    }

    // MARK: Commands

    /// Cmd B: at the playhead, or at both range edges if a range is set. Every track in the multitrack view,
    /// the shown track in the single view.
    func blade() {
        let frames = range.map { [$0.start, $0.end] } ?? [playhead]
        let only: Set<UUID>? = multitrack ? nil : Set(visibleRegions.map(\.id))
        document.apply("Blade") { EditOperations.blade(&$0, at: frames, only: only) }
    }

    /// Blade tool click: only the region under the pointer.
    func blade(region id: UUID, at frame: Int64) {
        document.apply("Blade") { EditOperations.blade(&$0, at: [frame], only: [id]) }
    }

    func deleteSelection(ripple: Bool) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        document.apply(ripple ? "Delete" : "Delete Leaving Gap") { EditOperations.delete(&$0, ids: ids, ripple: ripple) }
        selection = []
    }

    func duplicateSelection() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        var copies: [UUID] = []
        document.apply("Duplicate") { copies = EditOperations.duplicate(&$0, ids: ids) }
        selection = Set(copies)
    }

    /// F: default fade on both ends of the selected regions.
    func applyDefaultFades() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        let length = frames(ms: AppSettings.shared.defaultFadeMs)
        document.apply("Fade") { EditOperations.applyDefaultFades(&$0, ids: ids, length: length) }
    }

    /// Fade dialog result for every selected region.
    func setFades(fadeIn: Fade, fadeOut: Fade) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        document.apply("Fades") { p in
            EditOperations.setFadeLength(&p, ids: ids, end: .fadeOut, length: 0)
            EditOperations.setFadeLength(&p, ids: ids, end: .fadeIn, length: fadeIn.length)
            EditOperations.setFadeLength(&p, ids: ids, end: .fadeOut, length: fadeOut.length)
            EditOperations.setFadeShape(&p, ids: ids, end: .fadeIn, continuous: EditOperations.continuous(fadeIn))
            EditOperations.setFadeShape(&p, ids: ids, end: .fadeOut, continuous: EditOperations.continuous(fadeOut))
        }
    }

    /// , and .: moves the selection by the nudge setting.
    func nudge(_ direction: Int) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        let delta = frames(ms: AppSettings.shared.nudgeMs) * Int64(direction)
        document.apply("Nudge") { EditOperations.move(&$0, ids: ids, by: delta) }
    }

    func selectAll() {
        selection = Set(visibleRegions.map(\.id))
        headerFocused = false
    }

    func setGain(_ dB: Double, ids: Set<UUID>) {
        document.apply("Gain") { EditOperations.setGain(&$0, ids: ids, dB: dB) }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        document.apply("Rename") { EditOperations.rename(&$0, id: id, to: trimmed) }
    }

    func setFadeLength(ms value: Double, end: EditOperations.FadeEnd, ids: Set<UUID>) {
        let length = frames(ms: value)
        document.apply("Fade") { EditOperations.setFadeLength(&$0, ids: ids, end: end, length: length) }
    }

    func setFadeShape(_ value: Double, end: EditOperations.FadeEnd, ids: Set<UUID>) {
        document.apply("Fade Shape") { EditOperations.setFadeShape(&$0, ids: ids, end: end, continuous: value) }
    }

    // MARK: Snapping

    func tolerance(points: Double) -> Int64 { Int64(max(points * samplesPerPoint, 1)) }

    /// Snaps an edge: other region edges and the playhead within 8 points win, otherwise the nearest zero
    /// crossing of `region`'s own source within 4 points when snapping is on and `zeroCrossing` is allowed.
    func snapEdge(_ frame: Int64, excluding ids: Set<UUID>, region: Region?, zeroCrossing: Bool) -> Int64 {
        let targets = EditOperations.snapTargets(project, excluding: ids, extra: [playhead], tracks: visibleTrackIDs)
        if let t = EditOperations.nearest(frame, in: targets, tolerance: tolerance(points: 8)) { return t }
        guard zeroCrossing, AppSettings.shared.snapToZeroCrossing, let region,
              let source = document.loaded[region.sourceId]?.source else { return frame }
        let whole = Region(name: "", sourceId: region.sourceId, sourceIn: 0, sourceOut: source.frameCount,
                           position: region.position - region.sourceIn)
        let list = EditList(regions: [whole], sources: [region.sourceId: source], channelCount: project.channelCount)
        let radius = Int(min(max(4 * samplesPerPoint, 1), sessionRate * 0.01))
        return ZeroCrossing.nearest(in: list, around: frame, radius: radius)
    }

    /// Snaps a moved block of regions so one of its edges lands on another region edge or the playhead.
    func snapMove(delta: Int64, ids: Set<UUID>, base: Project) -> Int64 {
        let moved = base.regions.filter { ids.contains($0.id) }
        let targets = EditOperations.snapTargets(base, excluding: ids, extra: [playhead], tracks: visibleTrackIDs)
        let tol = tolerance(points: 8)
        var best: Int64?
        for r in moved {
            for edge in [r.position + delta, r.end + delta] {
                if let t = EditOperations.nearest(edge, in: targets, tolerance: tol) {
                    let correction = t - edge
                    if best == nil || abs(correction) < abs(best!) { best = correction }
                }
            }
        }
        return delta + (best ?? 0)
    }

    // MARK: Text

    func durationText(_ frames: Int64) -> String {
        let ms = ms(frames: abs(frames))
        let sign = frames < 0 ? "-" : "+"
        return ms < 1000 ? String(format: "%@%.1f ms", sign, ms) : String(format: "%@%.3f s", sign, ms / 1000)
    }

    func lengthText(_ frames: Int64) -> String {
        let ms = ms(frames: frames)
        return ms < 1000 ? String(format: "%.1f ms", ms) : String(format: "%.3f s", ms / 1000)
    }
}
