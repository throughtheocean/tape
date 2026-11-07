import XCTest
@testable import TapeCore

/// M10c: magnetic tracks and connected regions.
final class MagneticTests: XCTestCase {
    private let src = UUID()

    private func region(_ name: String, _ position: Int64, _ length: Int64, track: UUID = Track.firstID,
                        sourceIn: Int64 = 1000) -> Region {
        Region(name: name, trackId: track, sourceId: src, sourceIn: sourceIn, sourceOut: sourceIn + length, position: position)
    }

    private func positions(_ p: Project, track: UUID = Track.firstID) -> [String] {
        p.regions(onTrack: track).sorted { $0.position < $1.position }.map { "\($0.name)@\($0.position)+\($0.length)" }
    }

    private func at(_ p: Project, _ name: String) -> Region { p.regions.first { $0.name == name }! }

    /// Track 1 magnetic with a, b, c back to back; track 2 free with x connected to b and y to c.
    private func spine() -> (Project, UUID) {
        var p = Project(sessionRate: 48000, channelCount: 2)
        let t2 = EditOperations.addTrack(&p)
        p.regions = [region("a", 0, 1000), region("b", 1000, 2000), region("c", 3000, 500),
                     region("x", 1500, 300, track: t2), region("y", 3100, 200, track: t2)]
        p.sortRegions()
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: true) }
        EditOperations.edit(&p) { q in
            XCTAssertTrue(EditOperations.connect(&q, id: self.at(q, "x").id, to: self.at(q, "b").id))
            XCTAssertTrue(EditOperations.connect(&q, id: self.at(q, "y").id, to: self.at(q, "c").id))
        }
        return (p, t2)
    }

    func testClosingGapsKeepsOrderAndLengths() {
        var p = Project(sessionRate: 48000, channelCount: 2)
        p.regions = [region("a", 500, 1000), region("b", 4000, 2000), region("c", 2000, 700)]
        p.sortRegions()
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: true) }
        XCTAssertEqual(positions(p), ["a@0+1000", "c@1000+700", "b@1700+2000"])
        XCTAssertTrue(p.tracks[0].magnetic)

        // Off keeps positions as they are.
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: false) }
        XCTAssertEqual(positions(p), ["a@0+1000", "c@1000+700", "b@1700+2000"])
        EditOperations.edit(&p) { EditOperations.move(&$0, ids: [self.at($0, "b").id], by: 300) }
        XCTAssertEqual(positions(p), ["a@0+1000", "c@1000+700", "b@2000+2000"], "free again")
    }

    func testReorderByDragProducesTheExpectedSequence() {
        var p = Project(sessionRate: 48000, channelCount: 2)
        p.regions = [region("a", 0, 1000), region("b", 1000, 2000), region("c", 3000, 500), region("d", 3500, 1500)]
        p.sortRegions()
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: true) }
        let base = p
        let a = at(p, "a").id

        // Dragging a right: its start passes b's middle (2000) but not c's (3250): after b.
        var q = base
        EditOperations.edit(&q) { q in
            EditOperations.move(&q, ids: [a], by: 2100)
            XCTAssertEqual(EditOperations.insert(&q, ids: [a], track: Track.firstID), 2000)
        }
        XCTAssertEqual(positions(q), ["b@0+2000", "a@2000+1000", "c@3000+500", "d@3500+1500"])

        // Past the last middle: appended.
        q = base
        EditOperations.edit(&q) { q in
            EditOperations.move(&q, ids: [a], by: 9000)
            EditOperations.insert(&q, ids: [a], track: Track.firstID)
        }
        XCTAssertEqual(positions(q), ["b@0+2000", "c@2000+500", "d@2500+1500", "a@4000+1000"])

        // d dragged to the front, together with c as a block, keeps the block's order.
        q = base
        let cd: Set<UUID> = [at(p, "c").id, at(p, "d").id]
        EditOperations.edit(&q) { q in
            EditOperations.move(&q, ids: cd, by: -3000)
            EditOperations.insert(&q, ids: cd, track: Track.firstID)
        }
        XCTAssertEqual(positions(q), ["c@0+500", "d@500+1500", "a@2000+1000", "b@3000+2000"])

        // Dragged to another lane: it leaves, and the rest closes up.
        q = base
        let t2 = EditOperations.addTrack(&q)
        EditOperations.edit(&q) { EditOperations.moveToTrack(&$0, ids: [self.at($0, "b").id], byLanes: 1) }
        XCTAssertEqual(positions(q), ["a@0+1000", "c@1000+500", "d@1500+1500"])
        XCTAssertEqual(positions(q, track: t2), ["b@1000+2000"])
    }

    func testRippleTrimShiftsFollowersAndTheirConnectedRegionsByTheTrimmedAmount() {
        let (base, t2) = spine()
        XCTAssertEqual(at(base, "x").anchor?.offset, 500)
        XCTAssertEqual(at(base, "y").anchor?.offset, 100)

        // Trim a's end 400 shorter: b, c, x and y all move 400 left; a's start stays.
        var p = base
        EditOperations.edit(&p) { EditOperations.trimEnd(&$0, id: self.at($0, "a").id, to: 600, sourceLength: 1_000_000) }
        XCTAssertEqual(positions(p), ["a@0+600", "b@600+2000", "c@2600+500"])
        XCTAssertEqual(positions(p, track: t2), ["x@1100+300", "y@2700+200"])

        // Trim b's start 250 later: b keeps its start and gets shorter at the front; c and y move 250 left,
        // x (connected to b, whose start did not move) stays.
        p = base
        EditOperations.edit(&p) { EditOperations.trimStart(&$0, id: self.at($0, "b").id, to: 1250) }
        XCTAssertEqual(positions(p), ["a@0+1000", "b@1000+1750", "c@2750+500"])
        XCTAssertEqual(at(p, "b").sourceIn, 1250)
        XCTAssertEqual(positions(p, track: t2), ["x@1500+300", "y@2850+200"])

        // Extending a's end by 300 moves everything after it 300 right.
        p = base
        EditOperations.edit(&p) { EditOperations.trimEnd(&$0, id: self.at($0, "a").id, to: 1300, sourceLength: 1_000_000) }
        XCTAssertEqual(positions(p, track: t2), ["x@1800+300", "y@3400+200"])

        // Trimming a connected region does not touch its anchor; its offset follows its new start.
        p = base
        EditOperations.edit(&p) { EditOperations.trimStart(&$0, id: self.at($0, "x").id, to: 1600) }
        XCTAssertEqual(positions(p), positions(base))
        XCTAssertEqual(at(p, "x").position, 1600)
        XCTAssertEqual(at(p, "x").anchor?.offset, 600)

        // Reorder: c to the front, y travels with it.
        p = base
        EditOperations.edit(&p) { q in
            let c = self.at(q, "c").id
            EditOperations.move(&q, ids: [c], by: -3000)
            EditOperations.insert(&q, ids: [c], track: Track.firstID)
        }
        XCTAssertEqual(positions(p), ["c@0+500", "a@500+1000", "b@1500+2000"])
        XCTAssertEqual(positions(p, track: t2), ["y@100+200", "x@2000+300"])
    }

    func testDeletingTheAnchorDisconnectsAndKeepsTheAbsolutePosition() {
        let (base, t2) = spine()
        var p = base
        EditOperations.edit(&p) { EditOperations.delete(&$0, ids: [self.at($0, "b").id], ripple: true) }
        XCTAssertEqual(positions(p), ["a@0+1000", "c@1000+500"])
        XCTAssertNil(at(p, "x").anchor)
        XCTAssertEqual(at(p, "x").position, 1500, "absolute position kept")
        XCTAssertEqual(positions(p, track: t2), ["y@1100+200", "x@1500+300"])
        XCTAssertEqual(at(p, "y").anchor?.regionId, at(p, "c").id, "y follows c by the deleted length")
    }

    func testReplaceWithGapKeepsTheSequenceAndTheConnection() {
        let (base, t2) = spine()
        var p = base
        let b = at(p, "b").id
        EditOperations.edit(&p) { EditOperations.replaceWithGap(&$0, ids: [b]) }
        let gap = p.regions.first { $0.id == b }!
        XCTAssertTrue(gap.isGap)
        XCTAssertEqual(gap.position, 1000)
        XCTAssertEqual(gap.length, 2000)
        XCTAssertEqual(at(p, "c").position, 3000)
        XCTAssertEqual(at(p, "x").anchor?.regionId, b)
        XCTAssertEqual(positions(p, track: t2), positions(base, track: t2))

        // A gap trims like a region, both ways, and ripples.
        EditOperations.edit(&p) { EditOperations.trimStart(&$0, id: b, to: 0) }
        XCTAssertEqual(p.regions.first { $0.id == b }?.length, 3000)
        XCTAssertEqual(at(p, "c").position, 4000)
    }

    func testBladeMovesConnectionsAfterTheCutToTheRightPart() {
        let (base, _) = spine()
        var p = base
        var right: [UUID] = []
        EditOperations.edit(&p) { right = EditOperations.blade(&$0, at: [1400]) }
        XCTAssertEqual(right.count, 1)
        XCTAssertEqual(at(p, "x").anchor?.regionId, right[0], "x starts at 1500, after the cut")
        XCTAssertEqual(at(p, "x").anchor?.offset, 100)
        XCTAssertEqual(at(p, "x").position, 1500)
        XCTAssertEqual(positions(p).count, 4, "blade inserts no gap")
        XCTAssertEqual(at(p, "c").position, 3000)
    }

    func testConnectionRules() {
        var (p, t2) = spine()
        // Only a free region connects, and only to a region on a magnetic track.
        XCTAssertFalse(EditOperations.connect(&p, id: at(p, "a").id, to: at(p, "x").id))
        XCTAssertFalse(EditOperations.connect(&p, id: at(p, "x").id, to: at(p, "y").id))
        // Moving a connected region keeps the connection with a new offset; its anchor stays.
        EditOperations.edit(&p) { EditOperations.move(&$0, ids: [self.at($0, "x").id], by: 200) }
        XCTAssertEqual(at(p, "x").position, 1700)
        XCTAssertEqual(at(p, "x").anchor?.offset, 700)
        XCTAssertEqual(at(p, "b").position, 1000)
        // Magnetic off keeps the connections: dragging b on the now free track takes x along; on again changes nothing.
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: false) }
        XCTAssertEqual(at(p, "x").anchor?.regionId, at(p, "b").id)
        EditOperations.edit(&p) { EditOperations.move(&$0, ids: [self.at($0, "b").id], by: 1000) }
        XCTAssertEqual(at(p, "x").position, 2700)
        EditOperations.edit(&p) { EditOperations.move(&$0, ids: [self.at($0, "b").id], by: -1000) }
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: true) }
        XCTAssertEqual(at(p, "x").position, 1700)
        XCTAssertEqual(at(p, "x").anchor?.offset, 700)
        // A region others connect to is not connected itself: with track 1 free, b may not join a third, magnetic track.
        var q = p
        let t3 = EditOperations.addTrack(&q)
        q.regions.append(region("z", 0, 5000, track: t3))
        EditOperations.edit(&q) { EditOperations.setMagnetic(&$0, track: t3, on: true) }
        EditOperations.edit(&q) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: false) }
        XCTAssertFalse(EditOperations.connect(&q, id: at(q, "b").id, to: at(q, "z").id))
        XCTAssertTrue(EditOperations.connect(&q, id: at(q, "a").id, to: at(q, "z").id), "a is no anchor")
        // Making track 2 magnetic disconnects its regions.
        XCTAssertEqual(EditOperations.connectedRegions(p, onTrack: t2).count, 2)
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: t2, on: true) }
        XCTAssertTrue(EditOperations.connectedRegions(p, onTrack: t2).isEmpty)
        XCTAssertEqual(positions(p, track: t2), ["x@0+300", "y@300+200"])
    }

    func testDropOntoAMagneticTrackInserts() {
        var p = Project(sessionRate: 48000, channelCount: 2)
        p.regions = [region("a", 0, 1000), region("b", 1000, 2000)]
        p.sortRegions()
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: true) }
        EditOperations.edit(&p) { EditOperations.place(&$0, [self.region("n", 0, 400)], track: Track.firstID, at: 900, overwrite: true) }
        XCTAssertEqual(positions(p), ["a@0+1000", "n@1000+400", "b@1400+2000"])
    }

    func testMagneticTrackRendersIdenticallyToTheSameRegionsOnAFreeTrack() {
        let samples = (0..<30000).map { Float(sin(Double($0) * 0.017)) * 0.6 }
        var p = Project(sessionRate: 48000, channelCount: 2)
        p.regions = [region("a", 0, 7000, sourceIn: 100), region("b", 9000, 5000, sourceIn: 12000),
                     region("c", 7000, 2000, sourceIn: 3000)]
        p.regions[0].fadeOut = Fade(length: 800, shape: .sCurve)
        p.regions[1].gainDB = -4
        p.sortRegions()
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: true) }
        EditOperations.edit(&p) { EditOperations.replaceWithGap(&$0, ids: [self.at($0, "c").id]) }
        var free = p
        EditOperations.edit(&free) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: false) }
        XCTAssertNotEqual(p, free)
        XCTAssertEqual(p.regions, free.regions)
        let sources: [UUID: SampleSource] = [src: MemorySource(samples: [samples])]
        func render(_ q: Project) -> [[Float]] {
            let out = SampleBuffer(channelCount: 2, capacity: 16000)
            EditListRenderer(maxFrames: 1024).render(EditList(project: q, sources: sources), start: 0, frames: 16000, into: out)
            return out.toArrays(count: 16000)
        }
        let a = render(p), b = render(free)
        XCTAssertEqual(a, b)
        XCTAssertGreaterThan(a[0].map(abs).max() ?? 0, 0.1)
        XCTAssertEqual(a[0][8000], 0, "the gap is silent")
    }

    func testFileKeepsMagneticAndAnchorsAndReadsOldFiles() throws {
        let (p, _) = spine()
        let data = try JSONEncoder().encode(ProjectFile(document: p))
        let back = try JSONDecoder().decode(ProjectFile.self, from: data).document
        XCTAssertEqual(back, p)
        // Without magnetic tracks nothing new is written.
        var plain = Project(sessionRate: 48000, channelCount: 2)
        plain.regions = [region("a", 0, 1000)]
        let text = String(decoding: try JSONEncoder().encode(ProjectFile(document: plain)), as: UTF8.self)
        XCTAssertFalse(text.contains("magnetic"))
        XCTAssertFalse(text.contains("anchor"))
    }
}
