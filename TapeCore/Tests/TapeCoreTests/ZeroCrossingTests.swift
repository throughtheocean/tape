import XCTest
@testable import TapeCore

final class ZeroCrossingTests: XCTestCase {
    /// Sine with a period of 100 frames and a phase offset, so crossings sit between frames.
    private func sineList(offset: Double = 0.3, channels: Int = 1) -> EditList {
        let samples = (0..<4000).map { Float(sin(2 * Double.pi * (Double($0) + offset) / 100)) }
        let id = UUID()
        let region = Region(name: "S", sourceId: id, sourceIn: 0, sourceOut: 4000, position: 0)
        return EditList(regions: [region], sources: [id: MemorySource(samples: Array(repeating: samples, count: channels))],
                        channelCount: channels)
    }

    func testSnapsToNearestCrossing() {
        let list = sineList()
        // Crossings at -0.3 + 50k, i.e. between frames 49 and 50 (50 is closer), 99 and 100, ...
        XCTAssertEqual(ZeroCrossing.nearest(in: list, around: 1040, radius: 20), 1050)
        XCTAssertEqual(ZeroCrossing.nearest(in: list, around: 1060, radius: 20), 1050)
        XCTAssertEqual(ZeroCrossing.nearest(in: list, around: 1080, radius: 30), 1100)
    }

    func testPicksTheSampleClosestToZero() {
        let list = sineList(offset: 0.8)
        // Crossing between 1049 and 1050 at 1049.2, so 1049 is closer to zero.
        XCTAssertEqual(ZeroCrossing.nearest(in: list, around: 1045, radius: 10), 1049)
    }

    func testNoCrossingWithinRadiusKeepsFrame() {
        let list = sineList()
        XCTAssertEqual(ZeroCrossing.nearest(in: list, around: 1025, radius: 10), 1025)
    }

    func testSilenceCountsAsZero() {
        let list = sineList()
        XCTAssertEqual(ZeroCrossing.nearest(in: list, around: 5000, radius: 10), 5000)
    }

    func testStereoUsesTheSum() {
        let list = sineList(channels: 2)
        XCTAssertEqual(ZeroCrossing.nearest(in: list, around: 1040, radius: 20), 1050)
    }
}
