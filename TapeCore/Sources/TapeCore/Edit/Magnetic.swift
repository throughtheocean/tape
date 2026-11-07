import Foundation

/// Magnetic tracks and connected regions. Edits change order and lengths; `settle` derives the positions.
extension EditOperations {
    /// Runs `change` as one edit and settles positions against the state before it.
    public static func edit(_ project: inout Project, _ change: (inout Project) -> Void) {
        let before = project
        change(&project)
        settle(&project, from: before)
    }

    /// Positions after an edit, `before` being the state the edit started from:
    /// 1. Every magnetic track is one sequence from 0, in position order; its regions carry no anchor.
    /// 2. A connected region the edit did not move follows its anchor by as much as the anchor moved. One the edit
    ///    moved, connected or created keeps its place, and its offset is measured again.
    /// 3. An anchor that is gone, or is itself connected, disconnects; the region keeps its position. An anchor on a
    ///    track that was magnetic and is not any more keeps its connections, so Magnetic Off and On loses nothing.
    public static func settle(_ project: inout Project, from before: Project) {
        let magnetic = Set(project.tracks.filter(\.magnetic).map(\.id))
        let old = Dictionary(before.regions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if !magnetic.isEmpty {
            // On a tie, a region the edit added goes first (a take recorded at a region's start lands before it).
            let order = project.regions.indices.filter { magnetic.contains(project.regions[$0].trackId) }.sorted { i, j in
                let a = project.regions[i], b = project.regions[j]
                if a.position != b.position { return a.position < b.position }
                let an = old[a.id] == nil, bn = old[b.id] == nil
                if an != bn { return an }
                return a.id.uuidString < b.id.uuidString
            }
            var next: [UUID: Int64] = [:]
            for i in order {
                let track = project.regions[i].trackId
                project.regions[i].position = next[track, default: 0]
                next[track, default: 0] += project.regions[i].length
                project.regions[i].anchor = nil
            }
        }
        if project.regions.contains(where: { $0.anchor != nil }) {
            var index: [UUID: Int] = [:]
            for (i, r) in project.regions.enumerated() { index[r.id] = i }
            for i in project.regions.indices {
                guard var anchor = project.regions[i].anchor else { continue }
                guard let ai = index[anchor.regionId], ai != i, project.regions[ai].anchor == nil else {
                    project.regions[i].anchor = nil
                    continue
                }
                let r = project.regions[i], a = project.regions[ai]
                if let was = old[r.id], was.position == r.position, was.anchor == r.anchor {
                    project.regions[i].position = max(0, a.position + anchor.offset)
                } else {
                    anchor.offset = r.position - a.position
                    project.regions[i].anchor = anchor
                }
            }
        }
        project.sortRegions()
    }

    /// Turns a track magnetic or back. On, its regions lose their anchors and `settle` closes the gaps;
    /// off, positions and the connections to its regions stay as they are.
    public static func setMagnetic(_ project: inout Project, track: UUID, on: Bool) {
        updateTrack(&project, id: track) { $0.magnetic = on }
        guard on else { return }
        for i in project.regions.indices where project.regions[i].trackId == track { project.regions[i].anchor = nil }
    }

    /// Regions on `track` that are connected to something; making the track magnetic disconnects them.
    public static func connectedRegions(_ project: Project, onTrack track: UUID) -> [Region] {
        project.regions.filter { $0.trackId == track && $0.anchor != nil }
    }

    /// Puts `ids` (already on the magnetic `track`) into its sequence where their block starts: after every other
    /// region whose middle lies before that frame. Lays the track out from 0. Returns the insertion frame.
    @discardableResult
    public static func insert(_ project: inout Project, ids: Set<UUID>, track: UUID) -> Int64? {
        let onTrack = project.regions.filter { $0.trackId == track }
        let moved = onTrack.filter { ids.contains($0.id) }.sorted { $0.position < $1.position }
        guard let start = moved.first?.position else { return nil }
        let others = onTrack.filter { !ids.contains($0.id) }.sorted { $0.position < $1.position }
        let k = others.filter { $0.position + $0.length / 2 < start }.count
        var positions: [UUID: Int64] = [:]
        var position: Int64 = 0
        for r in Array(others[..<k]) + moved + Array(others[k...]) {
            positions[r.id] = position
            position += r.length
        }
        for i in project.regions.indices {
            if let p = positions[project.regions[i].id] { project.regions[i].position = p }
        }
        project.sortRegions()
        return positions[moved[0].id]
    }

    /// Connects `id` (on a track that is not magnetic) to `anchor` (on a magnetic track), keeping its position.
    /// A region others are connected to is not connected itself, so connections never chain.
    @discardableResult
    public static func connect(_ project: inout Project, id: UUID, to anchor: UUID) -> Bool {
        guard id != anchor, !project.regions.contains(where: { $0.anchor?.regionId == id }),
              let i = project.regions.firstIndex(where: { $0.id == id }),
              let a = project.regions.first(where: { $0.id == anchor }),
              project.track(project.regions[i].trackId)?.magnetic == false,
              project.track(a.trackId)?.magnetic == true else { return false }
        project.regions[i].anchor = Anchor(regionId: anchor, offset: project.regions[i].position - a.position)
        return true
    }

    public static func disconnect(_ project: inout Project, ids: Set<UUID>) {
        for i in project.regions.indices where ids.contains(project.regions[i].id) { project.regions[i].anchor = nil }
    }

    /// Forward Delete on a magnetic track: each region becomes a gap of its length. The gap keeps the region's id,
    /// so regions connected to it stay connected.
    public static func replaceWithGap(_ project: inout Project, ids: Set<UUID>) {
        for i in project.regions.indices where ids.contains(project.regions[i].id) && !project.regions[i].isGap {
            let r = project.regions[i]
            project.regions[i] = .gap(id: r.id, track: r.trackId, position: r.position, length: r.length)
        }
    }

    static func isMagnetic(_ project: Project, _ track: UUID) -> Bool { project.track(track)?.magnetic == true }
}
