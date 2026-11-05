import XCTest
@testable import TapeCore

final class FadeTests: XCTestCase {
    func testTablesAreMonotonicFromZeroToOne() {
        for shape in FadeShape.allCases {
            let t = Array(FadeCurves.table(shape))
            XCTAssertEqual(t.count, 4096)
            XCTAssertEqual(t.first, 0, "\(shape)")
            XCTAssertEqual(t.last, 1, "\(shape)")
            for i in 1..<t.count where t[i] < t[i - 1] {
                XCTFail("\(shape) not monotonic at \(i)")
                break
            }
        }
    }

    func testSCurveIsSymmetricAboutHalf() {
        let t = Array(FadeCurves.table(.sCurve))
        for i in 0..<t.count {
            XCTAssertEqual(t[i] + t[t.count - 1 - i], 1, accuracy: 1e-6)
        }
        XCTAssertEqual(FadeCurves.value(Fade(length: 1, shape: .sCurve), at: 0.5), 0.5, accuracy: 1e-6)
    }

    func testBlendInterpolatesTowardsNeighbour() {
        let a = FadeCurves.value(Fade(length: 1, shape: .linear, blend: 0), at: 0.3)
        let b = FadeCurves.value(Fade(length: 1, shape: .sCurve, blend: 0), at: 0.3)
        let mid = FadeCurves.value(Fade(length: 1, shape: .linear, blend: 0.5), at: 0.3)
        XCTAssertEqual(mid, (a + b) / 2, accuracy: 1e-6)
    }
}

final class EditListRenderTests: XCTestCase {
    func testOverlappingRegionsWithFadesMatchHandComputedBuffer() {
        let frames = 3000
        let srcA = MemorySource(samples: [
            (0..<frames).map { Float(sin(Double($0) * 0.01)) * 0.8 },
            (0..<frames).map { Float(cos(Double($0) * 0.013)) * 0.5 },
        ])
        let srcB = MemorySource(samples: [(0..<frames).map { Float(($0 % 100)) / 100 - 0.5 }])
        let idA = UUID(), idB = UUID()
        let a = Region(name: "A", sourceId: idA, sourceIn: 100, sourceOut: 1300, position: 0, gainDB: -6,
                       fadeIn: Fade(length: 100, shape: .linear), fadeOut: Fade(length: 400, shape: .sCurve))
        let b = Region(name: "B", sourceId: idB, sourceIn: 0, sourceOut: 1000, position: 800, gainDB: 3,
                       fadeIn: Fade(length: 400, shape: .sCurve), fadeOut: Fade(length: 250, shape: .linear))
        let list = EditList(regions: [b, a], sources: [idA: srcA, idB: srcB], channelCount: 2)

        let renderer = EditListRenderer(maxFrames: 333) // forces chunk boundaries inside fades
        let out = SampleBuffer(channelCount: 2, capacity: 2000)
        renderer.render(list, start: 0, frames: 2000, into: out)

        func gain(_ r: Region, _ t: Int) -> Double {
            let k = t - Int(r.position)
            guard k >= 0, k < Int(r.length) else { return 0 }
            var g = pow(10, r.gainDB / 20)
            if k < Int(r.fadeIn.length) { g *= FadeCurves.analytic(r.fadeIn.shape, Double(k) / Double(r.fadeIn.length)) }
            let fo = Int(r.fadeOut.length)
            if k >= Int(r.length) - fo { g *= FadeCurves.analytic(r.fadeOut.shape, Double(Int(r.length) - k) / Double(fo)) }
            return g
        }
        for t in 0..<2000 {
            for c in 0..<2 {
                var e = 0.0
                let ka = t - Int(a.position)
                if ka >= 0, ka < Int(a.length) { e += Double(srcA.samples[c][Int(a.sourceIn) + ka]) * gain(a, t) }
                let kb = t - Int(b.position)
                if kb >= 0, kb < Int(b.length) { e += Double(srcB.samples[0][Int(b.sourceIn) + kb]) * gain(b, t) } // mono to both
                XCTAssertEqual(Double(out.channels[c][t]), e, accuracy: 1e-6, "frame \(t) ch \(c)")
            }
        }
    }

    func testFadesLongerThanRegionAreScaled() {
        let r = Region(name: "r", sourceId: UUID(), sourceIn: 0, sourceOut: 100, position: 0,
                       fadeIn: Fade(length: 150), fadeOut: Fade(length: 50))
        let (fi, fo) = EditListRenderer.effectiveFadeLengths(r)
        XCTAssertEqual(fi + fo, 100)
        XCTAssertEqual(fi, 75)
    }
}
