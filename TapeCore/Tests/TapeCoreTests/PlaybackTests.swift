import XCTest
@testable import TapeCore

/// Transport output pulled through the real engine and producer in offline manual rendering.
final class PlaybackTests: XCTestCase {
    private let frames = 200_000
    private var signal: [[Float]] = []
    private var list = EditList.empty
    private var engine: PlaybackEngine!

    override func setUpWithError() throws {
        // Unique, non-repeating values so any misplaced frame shows up.
        signal = [
            (0..<frames).map { Float(sin(Double($0) * 0.0123)) * 0.5 + Float($0 % 977) / 9770 },
            (0..<frames).map { Float(cos(Double($0) * 0.0071)) * 0.4 - Float($0 % 613) / 6130 },
        ]
        let id = UUID()
        let region = Region(name: "r", sourceId: id, sourceIn: 0, sourceOut: Int64(frames), position: 0, gainDB: -3,
                            fadeIn: Fade(length: 4800, shape: .sCurve), fadeOut: Fade(length: 4800, shape: .exp))
        list = EditList(regions: [region], sources: [id: MemorySource(samples: signal)], channelCount: 2)
        engine = PlaybackEngine()
        try engine.configure(sessionRate: 48000, channelCount: 2, manualRendering: true)
        engine.setEditList(list)
    }

    override func tearDown() {
        engine.shutdown()
        engine = nil
    }

    /// What the edit list renderer produces for `start ..< start + count`.
    private func reference(_ start: Int64, _ count: Int) -> [[Float]] {
        let out = SampleBuffer(channelCount: 2, capacity: count)
        EditListRenderer().render(list, start: start, frames: count, into: out)
        return out.toArrays(count: count)
    }

    private func assertEqual(_ a: [Float], _ b: [Float], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, label, file: file, line: line)
        for i in 0..<min(a.count, b.count) where abs(a[i] - b[i]) > 1e-6 {
            XCTFail("\(label): frame \(i) got \(a[i]) want \(b[i])", file: file, line: line)
            return
        }
    }

    func testForwardPlaybackEqualsRenderer() throws {
        engine.play(from: 1000, speed: 1)
        let out = try engine.renderManual(frames: 20000)
        let ref = reference(1000, 20000)
        assertEqual(out[0], ref[0], "left")
        assertEqual(out[1], ref[1], "right")
    }

    func testFadesAreIdenticalInPlaybackAndRender() throws {
        engine.play(from: Int64(frames) - 6000, speed: 1)
        let out = try engine.renderManual(frames: 6000)
        let ref = reference(Int64(frames) - 6000, 6000)
        assertEqual(out[0], ref[0], "fade out")
        engine.play(from: 0, speed: 1)
        let head = try engine.renderManual(frames: 6000)
        assertEqual(head[1], reference(0, 6000)[1], "fade in")
    }

    func testReversePlaysBackwards() throws {
        engine.play(from: 50000, speed: -1)
        let out = try engine.renderManual(frames: 10000)
        let ref = reference(40000, 10000)
        assertEqual(out[0], Array(ref[0].reversed()), "reverse")
    }

    func testDoubleSpeedAveragesPairs() throws {
        engine.play(from: 10000, speed: 2)
        let out = try engine.renderManual(frames: 4096)
        let ref = reference(10000, 8192)
        let left = ref[0]
        var expected = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 { expected[i] = (left[2 * i] + left[2 * i + 1]) / 2 }
        assertEqual(out[0], expected, "2x")
    }

    func testLoopWrapsSampleAccurately() throws {
        let loop = SampleRange(start: 30000, end: 33000)
        engine.setLoop(loop)
        engine.play(from: 32500, speed: 1)
        let out = try engine.renderManual(frames: 3500 + 1000)
        let expected = reference(32500, 500)[0] + reference(30000, 3000)[0] + reference(30000, 1000)[0]
        assertEqual(out[0], expected, "loop")
    }

    func testStopsAtDocumentEnd() throws {
        engine.play(from: Int64(frames) - 700, speed: 1)
        let out = try engine.renderManual(frames: 2048)
        let ref = reference(Int64(frames) - 700, 700)
        assertEqual(Array(out[0].prefix(700)), ref[0], "tail")
        XCTAssertTrue(out[0].suffix(1000).allSatisfy { $0 == 0 }, "silence after the end")
    }

    func testPauseSilencesImmediately() throws {
        engine.play(from: 5000, speed: 1)
        _ = try engine.renderManual(frames: 2048)
        engine.pause()
        let out = try engine.renderManual(frames: 1024)
        XCTAssertTrue(out[0].allSatisfy { $0 == 0 })
    }
}
