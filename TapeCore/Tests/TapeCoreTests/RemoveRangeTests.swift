import XCTest
@testable import TapeCore

/// Cutting a marked range out of the audio on chosen tracks.
final class RemoveRangeTests: XCTestCase {
    private let src = UUID()

    private func region(_ name: String, _ position: Int64, _ length: Int64, track: UUID = Track.firstID) -> Region {
        Region(name: name, trackId: track, sourceId: src, sourceIn: 1000, sourceOut: 1000 + length, position: position)
    }

    private func layout(_ p: Project, track: UUID = Track.firstID) -> [String] {
        p.regions(onTrack: track).sorted { $0.position < $1.position }
            .map { "\($0.isGap ? "gap" : $0.name)@\($0.position)+\($0.length) in \($0.sourceIn)" }
    }

    private func twoTracks() -> (Project, UUID) {
        var p = Project(sessionRate: 48000, channelCount: 2)
        let t2 = EditOperations.addTrack(&p)
        p.regions = [region("a", 0, 1000), region("b", 1200, 800), region("c", 0, 2000, track: t2)]
        p.sortRegions()
        return (p, t2)
    }

    func testRippleClosesTheCutOnTheChosenTrackOnly() {
        var (p, t2) = twoTracks()
        EditOperations.edit(&p) {
            EditOperations.removeRange(&$0, SampleRange(start: 300, end: 1300), tracks: [Track.firstID], ripple: true)
        }
        XCTAssertEqual(layout(p), ["a@0+300 in 1000", "b@300+700 in 1100"])
        XCTAssertEqual(layout(p, track: t2), ["c@0+2000 in 1000"])
    }

    func testWithoutRippleTheTimeStaysEmpty() {
        var (p, _) = twoTracks()
        EditOperations.edit(&p) {
            EditOperations.removeRange(&$0, SampleRange(start: 300, end: 1300), tracks: [Track.firstID], ripple: false)
        }
        XCTAssertEqual(layout(p), ["a@0+300 in 1000", "b@1300+700 in 1100"])
    }

    func testInsideOneRegionLeavesTwoParts() {
        var (p, _) = twoTracks()
        EditOperations.edit(&p) {
            EditOperations.removeRange(&$0, SampleRange(start: 200, end: 500), tracks: [Track.firstID], ripple: true)
        }
        XCTAssertEqual(layout(p), ["a@0+200 in 1000", "a@200+500 in 1500", "b@900+800 in 1000"])
    }

    func testMagneticTrackKeepsItsSequence() {
        var p = Project(sessionRate: 48000, channelCount: 2)
        p.regions = [region("a", 0, 1000), region("b", 1000, 1000)]
        p.sortRegions()
        EditOperations.edit(&p) { EditOperations.setMagnetic(&$0, track: Track.firstID, on: true) }
        var gap = p
        EditOperations.edit(&gap) {
            EditOperations.removeRange(&$0, SampleRange(start: 500, end: 1500), tracks: [Track.firstID], ripple: false)
        }
        XCTAssertEqual(layout(gap).map { $0.replacingOccurrences(of: " in \(Region.gapOrigin)", with: "") },
                       ["a@0+500 in 1000", "gap@500+1000", "b@1500+500 in 1500"])
        EditOperations.edit(&p) {
            EditOperations.removeRange(&$0, SampleRange(start: 500, end: 1500), tracks: [Track.firstID], ripple: true)
        }
        XCTAssertEqual(layout(p), ["a@0+500 in 1000", "b@500+500 in 1500"])
    }

    func testNothingUnderTheRangeChangesNothing() {
        var (p, _) = twoTracks()
        let before = p
        EditOperations.edit(&p) {
            EditOperations.removeRange(&$0, SampleRange(start: 1000, end: 1200), tracks: [Track.firstID], ripple: true)
        }
        XCTAssertEqual(p, before)
    }
}
