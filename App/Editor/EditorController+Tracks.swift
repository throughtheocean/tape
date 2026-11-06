import AppKit
import TapeCore

/// One track's lane in the Metal timeline, in its points (top down).
struct Lane {
    var track: Track
    var index: Int
    var top: Double
    var height: Double
    /// Lanes in the multitrack view keep a gap to their neighbours.
    var stacked = false

    var bottom: Double { top + height }
    /// Region bodies, inside the lane.
    var bodyTop: Double { top + (stacked ? 1 : 0) }
    var bodyBottom: Double { bottom - (stacked ? 2 : 0) }
    /// Name strip height; thinner in small lanes.
    var strip: Double { height >= 60 ? Double(TimelineLayout.nameStrip) : 13 }
    var waveTop: Double { bodyTop + strip }
}

/// Tracks, lanes and meters.
extension EditorController {
    /// Steps for Lane Height in the Track menu; the lane height slider sets any height in between.
    static let laneHeights: [Double] = [40, 80, 160]
    static let minLaneHeight = 40.0
    static let maxLaneHeight = 400.0
    static let defaultLaneHeight = 80.0
    static let headerWidth: CGFloat = 180
    /// Master strip and add button under the header column.
    static let masterStripHeight: Double = 64

    var selectedTrack: Track { project.track(selectedTrackID) ?? project.tracks[0] }

    /// Tracks drawn: all of them in the multitrack view, the selected one in the single view.
    var visibleTrackIDs: Set<UUID> { multitrack ? Set(project.tracks.map(\.id)) : [selectedTrackID] }

    /// Regions on the visible tracks.
    var visibleRegions: [Region] {
        multitrack ? project.regions : project.regions.filter { $0.trackId == selectedTrackID }
    }

    func selectTrack(_ id: UUID, header: Bool) {
        guard project.track(id) != nil else { return }
        if selectedTrackID != id {
            selectedTrackID = id
            layoutChanged()
        }
        headerFocused = header
        if header { selection = [] }
        saveView()
    }

    // MARK: Lanes

    /// Top and bottom of the area lanes are drawn in.
    var laneViewport: (top: Double, bottom: Double) {
        let top = Double(TimelineLayout.trackTop)
        let bottom = multitrack ? timelineHeight - Self.masterStripHeight : Double(TimelineLayout.regionBottom(CGFloat(timelineHeight)))
        return (top, max(top + 20, bottom))
    }

    func laneHeight(for track: Track) -> Double {
        guard multitrack else { return laneViewport.bottom - laneViewport.top }
        guard expandSelected, track.id == selectedTrackID else { return laneHeight }
        let viewport = laneViewport.bottom - laneViewport.top
        let others = Double(project.tracks.count - 1) * laneHeight
        return max(viewport - others, min(viewport, 320), laneHeight)
    }

    var lanesContentHeight: Double { project.tracks.reduce(0) { $0 + laneHeight(for: $1) } }

    var maxLaneScroll: Double {
        guard multitrack else { return 0 }
        return max(0, lanesContentHeight - (laneViewport.bottom - laneViewport.top))
    }

    /// Every visible lane, top down. In the single view one lane fills the track area.
    func lanes() -> [Lane] {
        let viewport = laneViewport
        guard multitrack else {
            let t = selectedTrack
            return [Lane(track: t, index: project.trackIndex(t.id) ?? 0, top: viewport.top, height: viewport.bottom - viewport.top)]
        }
        var y = viewport.top - laneScroll
        return project.tracks.enumerated().map { i, t in
            let h = laneHeight(for: t)
            defer { y += h }
            return Lane(track: t, index: i, top: y, height: h, stacked: true)
        }
    }

    func lane(for trackId: UUID) -> Lane? { lanes().first { $0.track.id == trackId } }

    /// The lane under `y`; with `clamped`, the nearest lane when `y` is above or below all of them.
    func lane(atY y: Double, clamped: Bool = false) -> Lane? {
        let all = lanes()
        if let hit = all.first(where: { y >= $0.top && y < $0.bottom }) { return hit }
        guard clamped, let first = all.first, let last = all.last else { return nil }
        return y < first.top ? first : last
    }

    /// Topmost visible region at `frame` in the lane under `y`.
    func region(at frame: Double, y: Double) -> Region? {
        guard let lane = lane(atY: y) else { return nil }
        return project.regions.last {
            $0.trackId == lane.track.id && Double($0.position) <= frame && frame < Double($0.end)
        }
    }

    func scrollLanes(by dy: Double) {
        let next = min(max(laneScroll + dy, 0), maxLaneScroll)
        guard next != laneScroll else { return }
        laneScroll = next
        layoutChanged()
    }

    /// Keeps the selected lane on screen in the multitrack view.
    func revealSelectedLane() {
        guard multitrack, let lane = lane(for: selectedTrackID) else { return }
        let v = laneViewport
        if lane.top < v.top { scrollLanes(by: lane.top - v.top) }
        if lane.bottom > v.bottom { scrollLanes(by: min(lane.bottom - v.bottom, lane.top - v.top)) }
    }

    func layoutChanged() {
        laneScroll = min(max(laneScroll, 0), maxLaneScroll)
        bumpLayout()
        needsDisplay?()
        saveView()
    }

    func cycleLaneHeight() {
        laneHeight = Self.laneHeights.first { $0 > laneHeight + 0.5 } ?? Self.laneHeights[0]
    }

    /// Lane height slider position, 0 (40 pt) to 1 (400 pt), logarithmic.
    var laneHeightNormalized: Double {
        log(laneHeight / Self.minLaneHeight) / log(Self.maxLaneHeight / Self.minLaneHeight)
    }

    func setLaneHeightNormalized(_ value: Double) {
        let h = Self.minLaneHeight * exp(min(max(value, 0), 1) * log(Self.maxLaneHeight / Self.minLaneHeight))
        laneHeight = h.rounded()
    }

    // MARK: Track commands

    /// Cmd T: a new track under the selected one, which becomes selected.
    func addTrack() {
        var id = UUID()
        let at = (project.trackIndex(selectedTrackID) ?? project.tracks.count - 1) + 1
        document.apply("Add Track") { id = EditOperations.addTrack(&$0, at: at) }
        selectTrack(id, header: true)
        revealSelectedLane()
    }

    func removeTrack(_ id: UUID) {
        guard project.tracks.count > 1, let name = project.track(id)?.name else { return }
        let index = project.trackIndex(id) ?? 0
        document.apply("Remove \(name)") { EditOperations.removeTrack(&$0, id: id) }
        let next = project.tracks[min(index, project.tracks.count - 1)].id
        selection = selection.intersection(project.regions.map(\.id))
        selectTrack(next, header: false)
    }

    func moveTrack(_ id: UUID, to index: Int) {
        document.apply("Move Track") { EditOperations.moveTrack(&$0, id: id, to: index) }
    }

    func updateTrack(_ name: String, _ id: UUID, _ change: @escaping (inout Track) -> Void) {
        document.apply(name) { EditOperations.updateTrack(&$0, id: id, change) }
    }

    func renameTrack(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateTrack("Rename Track", id) { $0.name = trimmed }
    }

    // MARK: Meters

    /// Pulls played peaks from the engine and advances the meters. Returns true while any meter shows something.
    @discardableResult
    func updateMeters(now: Double) -> Bool {
        let peaks = playback.meters.drain()
        if loudness.sampleRate != sessionRate || loudness.channels.count != project.channelCount {
            loudness = ChannelLoudness(sampleRate: sessionRate, channelCount: project.channelCount)
        }
        if isPlaying, !loudnessWasPlaying { loudness.reset() }
        for e in peaks?.loudness ?? [] { loudness.add(energies: e.energies, frames: e.frames) }
        if !isPlaying, loudnessWasPlaying { loudness.clearRunning() }
        loudnessWasPlaying = isPlaying
        let tracks = project.tracks
        var active = false
        for (i, t) in tracks.enumerated() {
            var m = trackMeters[t.id] ?? MeterBallistics()
            m.update(peak: i < MeterQueue.maxTracks ? peaks?.tracks[i] ?? 0 : 0, now: now)
            trackMeters[t.id] = m
            active = active || m.levelDB > MeterBallistics.floorDB || m.holdDB > MeterBallistics.floorDB
        }
        if trackMeters.count > tracks.count {
            let ids = Set(tracks.map(\.id))
            trackMeters = trackMeters.filter { ids.contains($0.key) }
        }
        for c in masterMeters.indices {
            let channel = min(c, project.channelCount - 1)
            masterMeters[c].update(peak: peaks?.master[channel] ?? 0, now: now)
            active = active || masterMeters[c].levelDB > MeterBallistics.floorDB || masterMeters[c].holdDB > MeterBallistics.floorDB
        }
        return active || isPlaying
    }

    /// The reading the loudness meter shows, in LUFS (-inf for none).
    var loudnessReading: Double { Self.reading(loudness.total) }

    /// The same reading per channel for the left and right bars; mono shows its one channel in both.
    var loudnessChannelReadings: [Double] {
        let c = loudness.channels
        return [Self.reading(c[0]), Self.reading(c[min(1, c.count - 1)])]
    }

    private static func reading(_ meter: LoudnessMeter) -> Double {
        switch AppSettings.shared.loudnessMode {
        case .momentary: return meter.momentary
        case .shortTerm: return meter.shortTerm
        case .integrated: return meter.integrated
        }
    }

    func resetLoudness() {
        loudness.reset()
        needsDisplay?()
    }

    func resetClips() {
        for k in trackMeters.keys { trackMeters[k]?.resetClip() }
        for i in masterMeters.indices { masterMeters[i].resetClip() }
    }
}
