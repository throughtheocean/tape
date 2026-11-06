import XCTest
@testable import TapeCore

/// M10a: region copies, overlap on one track, drops onto a lane.
final class OverlapAndDropTests: XCTestCase {
    private let s = UUID()

    private func region(_ name: String, _ position: Int64, _ length: Int64, track: UUID = Track.firstID) -> Region {
        Region(name: name, trackId: track, sourceId: s, sourceIn: 1000, sourceOut: 1000 + length, position: position,
               gainDB: -2, fadeIn: Fade(length: 10, shape: .sCurve), fadeOut: Fade(length: 20, shape: .log))
    }

    func testCopyKeepsEveryFieldButIdAndTrack() {
        var p = Project(sessionRate: 48000, channelCount: 2)
        let t2 = EditOperations.addTrack(&p)
        let a = region("a", 100, 500)
        p.regions = [a]
        let copy = UUID()
        XCTAssertEqual(EditOperations.copy(&p, ids: [a.id], newIDs: [a.id: copy]), [copy])
        EditOperations.moveToTrack(&p, ids: [copy], byLanes: 1)
        XCTAssertEqual(p.regions.count, 2)
        var expected = a
        expected.id = copy
        expected.trackId = t2
        XCTAssertEqual(p.regions.first { $0.id == copy }, expected)
        XCTAssertEqual(p.regions.first { $0.id == a.id }, a, "the original stays")
    }

    func testOverwriteTrimsSplitsAndRemovesOnlyOnItsTrack() {
        var p = Project(sessionRate: 48000, channelCount: 2)
        let t2 = EditOperations.addTrack(&p)
        let start = region("start", 0, 100), middle = region("middle", 200, 300), end = region("end", 600, 100)
        let gone = region("gone", 950, 30), other = region("other", 0, 2000, track: t2)
        p.regions = [start, middle, end, gone, other]
        // One block covering 50..<100 (start's tail), 300..<400 (middle's centre), 650..<1000 (end's tail and gone).
        let a = region("a", 50, 50), b = region("b", 300, 100), c = region("c", 650, 350)
        p.regions += [a, b, c]
        p.sortRegions()
        EditOperations.overwrite(&p, by: [a.id, b.id, c.id])

        let one = p.regions.filter { $0.trackId == Track.firstID }.sorted { $0.position < $1.position }
        XCTAssertEqual(one.map(\.name), ["start", "a", "middle", "b", "middle", "end", "c"])
        XCTAssertEqual(one.map(\.timelineRange), [SampleRange(start: 0, end: 50), a.timelineRange, SampleRange(start: 200, end: 300),
                                                 b.timelineRange, SampleRange(start: 400, end: 500), SampleRange(start: 600, end: 650),
                                                 c.timelineRange])
        let pieces = one.filter { $0.name == "middle" }
        XCTAssertEqual(pieces[0].id, middle.id)
        XCTAssertNotEqual(pieces[1].id, middle.id)
        XCTAssertEqual(pieces[1].sourceIn, middle.sourceIn + 200, "the right piece plays on where it was")
        XCTAssertEqual(pieces[0].fadeIn, middle.fadeIn)
        XCTAssertEqual(pieces[0].fadeOut, .none, "a cut edge has no fade")
        XCTAssertEqual(pieces[1].fadeIn, .none)
        XCTAssertEqual(pieces[1].fadeOut, middle.fadeOut)
        XCTAssertEqual(p.regions.first { $0.id == other.id }, other, "other tracks always sum")
    }

    /// A region dropped over a lane: plain drop trims what is under it, an Option drop keeps both.
    func testDropOverLaneTrimsOrKeeps() {
        var p = Project(sessionRate: 48000, channelCount: 2)
        let t2 = EditOperations.addTrack(&p)
        let under = region("under", 0, 1000, track: t2)
        p.regions = [under]
        let targets = EditOperations.snapTargets(p, excluding: [], extra: [5000])
        let start = EditOperations.snappedStart(1006, lengths: [400], targets: targets, tolerance: 8)
        XCTAssertEqual(start, 1000, "the dropped region's start snaps to the edge on the lane")
        let early = EditOperations.snappedStart(4604, lengths: [400], targets: targets, tolerance: 8)
        XCTAssertEqual(early, 4600, "its end snaps to the playhead")

        var kept = p
        let ids = EditOperations.place(&kept, [region("drop", 0, 400)], track: t2, at: 700, overwrite: false)
        XCTAssertEqual(kept.regions.first { $0.id == ids[0] }?.trackId, t2)
        XCTAssertEqual(kept.regions.first { $0.id == ids[0] }?.position, 700)
        XCTAssertEqual(kept.regions.first { $0.id == under.id }, under, "Option drop keeps both; they sum")

        var trimmed = p
        EditOperations.place(&trimmed, [region("x", 0, 400), region("y", 0, 100)], track: t2, at: 700, overwrite: true)
        XCTAssertEqual(trimmed.regions.map(\.timelineRange),
                       [SampleRange(start: 0, end: 700), SampleRange(start: 700, end: 1100), SampleRange(start: 1100, end: 1200)])
        XCTAssertEqual(trimmed.regions.first { $0.id == under.id }?.length, 700)
    }

    /// Overlapping regions on one track sum in the renderer (Option drag keeps both).
    func testOverlapOnOneTrackSums() {
        let (id, src) = (UUID(), MemorySource(samples: [[Float](repeating: 0.25, count: 100)]))
        let t = TrackMix(id: Track.firstID)
        let a = Region(name: "a", sourceId: id, sourceIn: 0, sourceOut: 100, position: 0)
        let b = Region(name: "b", sourceId: id, sourceIn: 0, sourceOut: 100, position: 50)
        let list = EditList(regions: [a, b], sources: [id: src], channelCount: 1, tracks: [t])
        let out = SampleBuffer(channelCount: 1, capacity: 150)
        EditListRenderer().render(list, start: 0, frames: 150, into: out)
        XCTAssertEqual(out.channels[0][25], 0.25)
        XCTAssertEqual(out.channels[0][75], 0.5)
        XCTAssertEqual(out.channels[0][125], 0.25)
    }
}
