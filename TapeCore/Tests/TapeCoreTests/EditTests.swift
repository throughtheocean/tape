import XCTest
@testable import TapeCore

final class EditTests: XCTestCase {
    private let src = UUID()

    private func project(_ spans: [(Int64, Int64)]) -> Project {
        var p = Project(sessionRate: 48000, channelCount: 1)
        p.regions = spans.enumerated().map { i, s in
            Region(name: "R\(i)", sourceId: src, sourceIn: 1000 * Int64(i), sourceOut: 1000 * Int64(i) + s.1, position: s.0,
                   fadeIn: Fade(length: 50, shape: .sCurve), fadeOut: Fade(length: 70, shape: .log))
        }
        return p
    }

    func testBladeSplitsAndKeepsAudioAligned() {
        var p = project([(0, 1000), (1000, 500)])
        let created = EditOperations.blade(&p, at: [400, 1200])
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(p.regions.count, 4)
        let r = p.regions
        XCTAssertEqual([r[0].position, r[0].length, r[0].sourceIn], [0, 400, 0])
        XCTAssertEqual([r[1].position, r[1].length, r[1].sourceIn], [400, 600, 400])
        XCTAssertEqual([r[2].position, r[2].length, r[2].sourceIn], [1000, 200, 1000])
        XCTAssertEqual([r[3].position, r[3].length, r[3].sourceIn], [1200, 300, 1200])
        XCTAssertEqual(r[0].fadeIn.length, 50)
        XCTAssertEqual(r[0].fadeOut.length, 0)
        XCTAssertEqual(r[1].fadeIn.length, 0)
        XCTAssertEqual(r[1].fadeOut.length, 70)
    }

    func testBladeAtEdgesDoesNothing() {
        var p = project([(0, 1000)])
        XCTAssertTrue(EditOperations.blade(&p, at: [0, 1000]).isEmpty)
        XCTAssertEqual(p.regions.count, 1)
    }

    func testBladeRenderMatchesUncut() {
        let samples = (0..<3000).map { Float(sin(Double($0) * 0.05)) }
        var p = Project(sessionRate: 48000, channelCount: 1)
        p.regions = [Region(name: "A", sourceId: src, sourceIn: 0, sourceOut: 3000, position: 0)]
        let sources: [UUID: SampleSource] = [src: MemorySource(samples: [samples])]
        let before = render(p, sources, 3000)
        EditOperations.blade(&p, at: [1234, 2001])
        XCTAssertEqual(render(p, sources, 3000), before)
    }

    func testRippleDeleteClosesGap() {
        var p = project([(0, 100), (100, 200), (300, 100), (500, 50)])
        let id = p.regions[1].id
        EditOperations.delete(&p, ids: [id], ripple: true)
        XCTAssertEqual(p.regions.map(\.position), [0, 100, 300])
    }

    func testDeleteLeavesGap() {
        var p = project([(0, 100), (100, 200), (300, 100)])
        EditOperations.delete(&p, ids: [p.regions[1].id], ripple: false)
        XCTAssertEqual(p.regions.map(\.position), [0, 300])
    }

    func testRippleDeleteDoesNotCloseSpanStillCovered() {
        // Region 1 overlaps region 2; deleting 1 only closes the part nothing else covers.
        var p = project([(0, 100), (100, 300), (300, 200), (600, 10)])
        EditOperations.delete(&p, ids: [p.regions[1].id], ripple: true)
        XCTAssertEqual(p.regions.map(\.position), [0, 100, 400])
    }

    func testDuplicatePlacesCopyAfterSelectionAndPushesLater() {
        var p = project([(0, 100), (100, 50), (150, 10)])
        let ids: Set<UUID> = [p.regions[0].id, p.regions[1].id]
        let copies = EditOperations.duplicate(&p, ids: ids)
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(p.regions.map(\.position), [0, 100, 150, 250, 300])
        XCTAssertEqual(p.regions[2].sourceIn, p.regions[0].sourceIn)
        XCTAssertEqual(p.regions[4].name, "R2")
    }

    func testMoveIsLimitedAtZero() {
        var p = project([(100, 100), (300, 100)])
        let applied = EditOperations.move(&p, ids: Set(p.regions.map(\.id)), by: -500)
        XCTAssertEqual(applied, -100)
        XCTAssertEqual(p.regions.map(\.position), [0, 200])
    }

    func testTrimStartKeepsAudioInPlaceAndRespectsSource() {
        var p = project([(500, 400)])
        let id = p.regions[0].id
        EditOperations.trimStart(&p, id: id, to: 600)
        XCTAssertEqual([p.regions[0].position, p.regions[0].sourceIn, p.regions[0].end], [600, 100, 900])
        EditOperations.trimStart(&p, id: id, to: 0)
        // sourceIn cannot go below 0: earliest start is 500.
        XCTAssertEqual([p.regions[0].position, p.regions[0].sourceIn], [500, 0])
        EditOperations.trimStart(&p, id: id, to: 2000)
        XCTAssertEqual(p.regions[0].length, EditOperations.minimumLength)
    }

    func testTrimEndRespectsSourceLength() {
        var p = project([(0, 400)])
        let id = p.regions[0].id
        EditOperations.trimEnd(&p, id: id, to: 300, sourceLength: 1000)
        XCTAssertEqual(p.regions[0].end, 300)
        EditOperations.trimEnd(&p, id: id, to: 5000, sourceLength: 1000)
        XCTAssertEqual(p.regions[0].sourceOut, 1000)
    }

    func testFadesAreClampedToTheRegion() {
        var p = project([(0, 400)])
        let ids: Set<UUID> = [p.regions[0].id]
        EditOperations.setFadeLength(&p, ids: ids, end: .fadeIn, length: 1000)
        XCTAssertEqual(p.regions[0].fadeIn.length, 330)
        EditOperations.applyDefaultFades(&p, ids: ids, length: 480)
        XCTAssertEqual(p.regions[0].fadeIn.length, 200)
        XCTAssertEqual(p.regions[0].fadeOut.length, 200)
    }

    func testContinuousShapeRoundTrips() {
        for v in stride(from: 0.0, through: 3.0, by: 0.25) {
            let (shape, blend) = EditOperations.shape(continuous: v)
            XCTAssertEqual(EditOperations.continuous(Fade(length: 1, shape: shape, blend: blend)), v, accuracy: 1e-9)
        }
    }

    func testSnapPicksNearestWithinTolerance() {
        XCTAssertEqual(EditOperations.nearest(105, in: [0, 100, 112], tolerance: 8), 100)
        XCTAssertNil(EditOperations.nearest(150, in: [0, 100, 112], tolerance: 8))
    }

    /// Fades render identically in playback (the engine in manual mode) and in a manual render.
    func testEditedFadesRenderIdenticallyInPlaybackAndRender() throws {
        let samples = (0..<20000).map { Float(sin(Double($0) * 0.031)) * 0.7 }
        var p = Project(sessionRate: 48000, channelCount: 1)
        p.regions = [Region(name: "A", sourceId: src, sourceIn: 0, sourceOut: 20000, position: 0)]
        EditOperations.blade(&p, at: [9000])
        EditOperations.setFadeLength(&p, ids: Set(p.regions.map(\.id)), end: .fadeIn, length: 3000)
        EditOperations.setFadeShape(&p, ids: Set(p.regions.map(\.id)), end: .fadeIn, continuous: 1.4)
        EditOperations.setFadeLength(&p, ids: Set(p.regions.map(\.id)), end: .fadeOut, length: 2500)
        EditOperations.setFadeShape(&p, ids: Set(p.regions.map(\.id)), end: .fadeOut, continuous: 2.7)
        let sources: [UUID: SampleSource] = [src: MemorySource(samples: [samples])]
        let list = EditList(regions: p.regions, sources: sources, channelCount: 1)
        let expected = render(p, sources, 20000)

        let engine = PlaybackEngine()
        try engine.configure(sessionRate: 48000, channelCount: 1, manualRendering: true)
        engine.setEditList(list)
        engine.play(from: 0, speed: 1)
        var got: [Float] = []
        while got.count < 20000 {
            got += try engine.renderManual(frames: 1024)[0]
        }
        engine.shutdown()
        for i in 0..<20000 where abs(got[i] - expected[i]) > 1e-6 {
            XCTFail("frame \(i): \(got[i]) vs \(expected[i])")
            return
        }
    }

    private func render(_ p: Project, _ sources: [UUID: SampleSource], _ frames: Int) -> [Float] {
        let out = SampleBuffer(channelCount: 1, capacity: frames)
        EditListRenderer(maxFrames: 1024).render(EditList(regions: p.regions, sources: sources, channelCount: 1), start: 0,
                                                  frames: frames, into: out)
        return out.toArrays(count: frames)[0]
    }
}
