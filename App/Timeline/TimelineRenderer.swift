import AppKit
import MetalKit
import QuartzCore
import TapeCore

struct RectInstance {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
}

struct LineInstance {
    var points: SIMD4<Float>
    var color: SIMD4<Float>
    var params: SIMD4<Float>
}

/// Growable float buffer reused across frames.
final class FloatScratch {
    private var storage = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var capacity = 1

    func pointer(_ count: Int) -> UnsafeMutablePointer<Float> {
        if count > capacity {
            storage.deallocate()
            capacity = count
            storage = .allocate(capacity: count)
        }
        return storage
    }

    deinit { storage.deallocate() }
}

/// Vertical layout of the Metal timeline in points, top down.
enum TimelineLayout {
    static let minimapHeight: CGFloat = 28
    /// The tool strip (snap, horizontal zoom) is an AppKit view laid over this band.
    static let toolStripHeight: CGFloat = 22
    static let trackTop: CGFloat = minimapHeight + toolStripHeight + 9
    static let bottomInset: CGFloat = 10
    static let nameStrip: CGFloat = 18

    static func regionTop(_ height: CGFloat) -> CGFloat { trackTop }
    static func regionBottom(_ height: CGFloat) -> CGFloat { max(trackTop + nameStrip + 20, height - bottomInset) }
}

/// Per frame timing, read by the benchmark.
struct FrameTiming {
    var cpuMs: Double
    var gpuMs: Double?
    var presentedTime: CFTimeInterval?
}

@MainActor
final class TimelineRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rectPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    weak var editor: EditorController?

    /// Waveform instances for the main track, rebuilt only when the view or document changes.
    private struct WaveKey: Equatable {
        var revision: Int
        var loadedCount: Int
        var viewStart: Double
        var spp: Double
        var amplitude: Double
        var size: CGSize
    }

    private enum Kind { case rects, lines }
    private struct RegionDraw {
        var kind: Kind
        var start: Int
        var count: Int
    }

    private var waveKey: WaveKey?
    private var waveRects: MTLBuffer?
    private var waveLines: MTLBuffer?
    private var waveDraws: [RegionDraw] = []
    private var miniKey: WaveKey?
    private var miniBuffer: MTLBuffer?
    private var miniCount = 0

    // Scratch reused across frames.
    private var rects: [RectInstance] = []
    private var lines: [LineInstance] = []
    private var mins: [Float] = []
    private var maxs: [Float] = []
    private var waveRectScratch: [RectInstance] = []
    private var waveLineScratch: [LineInstance] = []
    private let columnMins = FloatScratch()
    private let columnMaxs = FloatScratch()
    private var sampleScratch = SampleBuffer(channelCount: 2, capacity: 1)

    /// Set by the benchmark to collect timings.
    var timingSink: (@MainActor @Sendable (FrameTiming) -> Void)?
    private(set) var waveRebuilds = 0

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        func pipeline(_ vertex: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: "colorFragment")
            let a = d.colorAttachments[0]!
            a.pixelFormat = view.colorPixelFormat
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let r = pipeline("rectVertex"), let l = pipeline("lineVertex") else { return nil }
        rectPipeline = r
        linePipeline = l
        super.init()
    }

    func invalidateWaveforms() {
        waveKey = nil
        miniKey = nil
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        guard let editor, let pass = view.currentRenderPassDescriptor else { return }
        let t0 = CACurrentMediaTime()
        let size = view.drawableSize
        let scale = view.window?.backingScaleFactor ?? 2
        guard size.width > 0, size.height > 0 else { return }

        rects.removeAll(keepingCapacity: true)
        lines.removeAll(keepingCapacity: true)
        buildBackground(editor, size: size, scale: scale)
        let regionBodyEnd = rects.count
        rebuildWaveformsIfNeeded(editor, size: size, scale: scale)
        rebuildMinimapIfNeeded(editor, size: size, scale: scale)
        let overlayStart = rects.count
        buildOverlays(editor, size: size, scale: scale)

        guard let drawable = view.currentDrawable, let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = SIMD2<Float>(Float(size.width), Float(size.height))
        let frameRects = rects.isEmpty ? nil : device.makeBuffer(bytes: rects, length: rects.count * MemoryLayout<RectInstance>.stride)
        let frameLines = lines.isEmpty ? nil : device.makeBuffer(bytes: lines, length: lines.count * MemoryLayout<LineInstance>.stride)

        func drawRects(_ buffer: MTLBuffer?, start: Int, count: Int) {
            guard let buffer, count > 0 else { return }
            enc.setRenderPipelineState(rectPipeline)
            enc.setVertexBuffer(buffer, offset: start * MemoryLayout<RectInstance>.stride, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        func drawLines(_ buffer: MTLBuffer?, start: Int, count: Int) {
            guard let buffer, count > 0 else { return }
            enc.setRenderPipelineState(linePipeline)
            enc.setVertexBuffer(buffer, offset: start * MemoryLayout<LineInstance>.stride, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }

        // Background, grid, minimap background and region bodies.
        drawRects(frameRects, start: 0, count: regionBodyEnd)
        // One draw call per region waveform.
        for d in waveDraws {
            switch d.kind {
            case .rects: drawRects(waveRects, start: d.start, count: d.count)
            case .lines: drawLines(waveLines, start: d.start, count: d.count)
            }
        }
        drawRects(miniBuffer, start: 0, count: miniCount)
        // Range, loop, minimap window, playhead.
        drawRects(frameRects, start: overlayStart, count: rects.count - overlayStart)
        drawLines(frameLines, start: 0, count: lines.count)
        enc.endEncoding()

        if let sink = timingSink {
            let cpu = (CACurrentMediaTime() - t0) * 1000
            drawable.addPresentedHandler { d in
                let presented = d.presentedTime
                Task { @MainActor in sink(FrameTiming(cpuMs: cpu, gpuMs: nil, presentedTime: presented)) }
            }
            cmd.addCompletedHandler { c in
                let gpu = (c.gpuEndTime - c.gpuStartTime) * 1000
                Task { @MainActor in sink(FrameTiming(cpuMs: -1, gpuMs: gpu, presentedTime: nil)) }
            }
        }
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: Frame content

    private func px(_ editor: EditorController, frame: Double, scale: CGFloat) -> Float {
        Float(editor.x(forFrame: frame) * scale)
    }

    private func buildBackground(_ editor: EditorController, size: CGSize, scale: CGFloat) {
        let w = Float(size.width), h = Float(size.height), s = Float(scale)
        let accent = Theme.accent
        rects.append(RectInstance(rect: [0, 0, w, h], color: Theme.timeline.rgba))
        rects.append(RectInstance(rect: [0, 0, w, Float(TimelineLayout.minimapHeight) * s], color: Theme.chrome.rgba))
        rects.append(RectInstance(rect: [0, Float(TimelineLayout.minimapHeight) * s, w, s], color: Theme.separator.rgba))

        // Grid at the ruler's major ticks.
        if editor.samplesPerPoint > 0 {
            let settings = AppSettings.shared
            let step = RulerTicks.step(samplesPerPoint: editor.samplesPerPoint, sampleRate: editor.sessionRate,
                                       display: settings.timeDisplay, frameRate: settings.frameRate)
            let first = Int64(max(0, editor.viewStart) / Double(step)) * step
            var f = first
            let top = Float(TimelineLayout.trackTop) * s
            let gridColor = SIMD4<Float>(1, 1, 1, 0.045)
            let endFrame = editor.frame(forX: Double(size.width / scale))
            while Double(f) <= endFrame {
                let x = px(editor, frame: Double(f), scale: scale)
                rects.append(RectInstance(rect: [x.rounded(), top, 1, h - top], color: gridColor))
                f += step
            }
        }

        // Region bodies, name strip and placeholders.
        let doc = editor.document
        let top = Float(TimelineLayout.regionTop(size.height / scale)) * s
        let bottom = Float(TimelineLayout.regionBottom(size.height / scale)) * s
        let strip = Float(TimelineLayout.nameStrip) * s
        let body = accent.withAlphaComponent(0.16).rgba
        let stripColor = accent.withAlphaComponent(0.42).rgba
        let edge = accent.withAlphaComponent(0.75).rgba
        for region in doc.project.regions {
            let x0 = px(editor, frame: Double(region.position), scale: scale)
            let x1 = px(editor, frame: Double(region.end), scale: scale)
            if x1 < 0 || x0 > w { continue }
            let a = max(x0, -2), b = min(x1, w + 2)
            let width = max(b - a, 1)
            rects.append(RectInstance(rect: [a, top, width, bottom - top], color: body))
            rects.append(RectInstance(rect: [a, top, width, strip], color: stripColor))
            rects.append(RectInstance(rect: [a, top, width, 1], color: edge))
            rects.append(RectInstance(rect: [a, bottom - 1, width, 1], color: edge))
            if x0 >= -1 { rects.append(RectInstance(rect: [x0, top, 1, bottom - top], color: edge)) }
            if x1 <= w + 1 { rects.append(RectInstance(rect: [x1 - 1, top, 1, bottom - top], color: edge)) }
            if doc.loaded[region.sourceId] == nil {
                let failed = doc.failures[region.sourceId] != nil
                let mid = top + strip + (bottom - top - strip) / 2
                let color: SIMD4<Float> = failed ? [0.9, 0.25, 0.2, 0.5] : [1, 1, 1, 0.12]
                rects.append(RectInstance(rect: [a, mid - 3 * s, width, 6 * s], color: color))
            }
        }
    }

    private func buildOverlays(_ editor: EditorController, size: CGSize, scale: CGFloat) {
        let w = Float(size.width), h = Float(size.height), s = Float(scale)
        let top = Float(TimelineLayout.trackTop) * s
        let miniH = Float(TimelineLayout.minimapHeight) * s

        if let range = editor.range {
            let x0 = px(editor, frame: Double(range.start), scale: scale)
            let x1 = px(editor, frame: Double(range.end), scale: scale)
            if x1 >= 0, x0 <= w {
                let yellow = Theme.range.rgba
                rects.append(RectInstance(rect: [x0, top, max(x1 - x0, 1), h - top], color: [1, 1, 1, 0.07]))
                rects.append(RectInstance(rect: [x0, top, max(x1 - x0, 1), 2 * s], color: yellow))
                rects.append(RectInstance(rect: [x0, top, 1 * s, h - top], color: yellow))
                rects.append(RectInstance(rect: [x1 - s, top, 1 * s, h - top], color: yellow))
            }
        }
        if editor.loopEnabled {
            let loop = editor.range ?? SampleRange(start: 0, end: editor.documentLength)
            let x0 = px(editor, frame: Double(loop.start), scale: scale)
            let x1 = px(editor, frame: Double(loop.end), scale: scale)
            rects.append(RectInstance(rect: [x0, top - 5 * s, max(x1 - x0, 1), 3 * s], color: Theme.accent.rgba))
        }

        // Minimap window.
        let length = Double(max(editor.documentLength, 1))
        if editor.samplesPerPoint > 0, editor.documentLength > 0 {
            let visible = Double(size.width / scale) * editor.samplesPerPoint
            let x0 = Float(editor.viewStart / length) * w
            let ww = max(Float(visible / length) * w, 4 * s)
            rects.append(RectInstance(rect: [x0, 0, ww, miniH], color: [1, 1, 1, 0.10]))
            let edge = SIMD4<Float>(1, 1, 1, 0.55)
            rects.append(RectInstance(rect: [x0, 0, 2 * s, miniH], color: edge))
            rects.append(RectInstance(rect: [x0 + ww - 2 * s, 0, 2 * s, miniH], color: edge))
            let pm = Float(Double(editor.playhead) / length) * w
            rects.append(RectInstance(rect: [pm, 0, s, miniH], color: Theme.playhead.rgba))
        }

        // Playhead.
        let x = px(editor, frame: Double(editor.playhead), scale: scale)
        if x >= -2, x <= w + 2 {
            rects.append(RectInstance(rect: [x.rounded() - s / 2, miniH + s, max(s, 1), h - miniH], color: Theme.playhead.rgba))
        }
    }

    // MARK: Waveforms

    private func rebuildWaveformsIfNeeded(_ editor: EditorController, size: CGSize, scale: CGFloat) {
        let doc = editor.document
        let key = WaveKey(revision: doc.revision, loadedCount: doc.loaded.count, viewStart: editor.viewStart,
                          spp: editor.samplesPerPoint, amplitude: editor.amplitudeZoom, size: size)
        if key == waveKey { return }
        waveKey = key
        waveRebuilds += 1

        waveRectScratch.removeAll(keepingCapacity: true)
        waveLineScratch.removeAll(keepingCapacity: true)
        defer {
            waveRects = waveRectScratch.isEmpty ? nil
                : device.makeBuffer(bytes: waveRectScratch, length: waveRectScratch.count * MemoryLayout<RectInstance>.stride)
            waveLines = waveLineScratch.isEmpty ? nil
                : device.makeBuffer(bytes: waveLineScratch, length: waveLineScratch.count * MemoryLayout<LineInstance>.stride)
        }
        waveDraws.removeAll(keepingCapacity: true)
        guard editor.samplesPerPoint > 0 else {
            waveRects = nil
            waveLines = nil
            return
        }
        let w = Double(size.width)
        let s = Double(scale)
        let fpp = editor.samplesPerPoint / s
        let top = Double(TimelineLayout.regionTop(size.height / scale) + TimelineLayout.nameStrip) * s + 2 * s
        let bottom = Double(TimelineLayout.regionBottom(size.height / scale)) * s - 2 * s
        let color = Theme.accent.blended(withFraction: 0.45, of: .white)!.withAlphaComponent(0.95).rgba
        let centerLine = Theme.accent.withAlphaComponent(0.35).rgba

        for region in doc.project.regions {
            guard let loaded = doc.loaded[region.sourceId] else { continue }
            let x0 = editor.x(forFrame: Double(region.position)) * s
            let x1 = editor.x(forFrame: Double(region.end)) * s
            if x1 < 0 || x0 > w { continue }
            let p0 = Int(max(0, x0.rounded(.down)))
            let p1 = Int(min(w, x1.rounded(.up)))
            let n = p1 - p0
            guard n > 0 else { continue }
            let channels = loaded.peaks.channelCount
            let laneH = (bottom - top) / Double(channels)
            let srcStart = editor.viewStart + Double(p0) * fpp - Double(region.position) + Double(region.sourceIn)
            let amp = editor.amplitudeZoom

            if fpp >= 1 {
                let start = waveRectScratch.count
                let level = loaded.peaks.levelIndex(framesPerColumn: fpp)
                var raw: Int64 = 0
                if level == nil {
                    raw = Int64(srcStart.rounded(.down))
                    let count = Int((Double(n) * fpp).rounded(.up)) + 2
                    if sampleScratch.capacity < count || sampleScratch.channelCount < channels {
                        sampleScratch = SampleBuffer(channelCount: max(channels, 2), capacity: max(count, 65536))
                    }
                    loaded.source.read(start: raw, count: count, into: sampleScratch, offset: 0)
                }
                let mn = columnMins.pointer(n), mx = columnMaxs.pointer(n)
                for c in 0..<channels {
                    let laneTop = top + laneH * Double(c)
                    let laneBottom = laneTop + laneH
                    let mid = laneTop + laneH / 2
                    let half = laneH / 2 * 0.95 * amp
                    waveRectScratch.append(RectInstance(rect: SIMD4(Float(p0), Float(mid.rounded()), Float(n), 1), color: centerLine))
                    if let level {
                        loaded.peaks.columns(start: srcStart, framesPerColumn: fpp, count: n, channel: c, level: level,
                                             mins: mn, maxs: mx)
                    } else {
                        Self.rawColumns(sampleScratch.channels[c], start: srcStart - Double(raw), framesPerColumn: fpp,
                                        count: n, mins: mn, maxs: mx)
                    }
                    var prevTop = Double.nan, prevBottom = Double.nan
                    var i = 0
                    while i < n {
                        defer { i += 1 }
                        if mn[i] > mx[i] { continue }
                        var yTop = mid - Double(mx[i]) * half
                        var yBottom = mid - Double(mn[i]) * half
                        // Join neighbouring columns so steep slopes stay continuous.
                        if !prevTop.isNaN {
                            yTop = min(yTop, prevBottom)
                            yBottom = max(yBottom, prevTop)
                        }
                        prevTop = yTop
                        prevBottom = yBottom
                        let t = min(max(yTop, laneTop), laneBottom)
                        let b = min(max(yBottom, laneTop), laneBottom)
                        waveRectScratch.append(RectInstance(rect: SIMD4(Float(p0 + i), Float(t), 1, Float(max(b - t, 1))), color: color))
                    }
                }
                waveDraws.append(RegionDraw(kind: .rects, start: start, count: waveRectScratch.count - start))
            } else {
                // Below one sample per pixel: every sample as a dot joined by straight segments.
                let start = waveLineScratch.count
                let firstSample = max(region.sourceIn, Int64(srcStart.rounded(.down)) - 1)
                let lastSample = min(region.sourceOut - 1, Int64((srcStart + Double(n) * fpp).rounded(.up)) + 1)
                guard lastSample >= firstSample else { continue }
                let count = Int(lastSample - firstSample + 1)
                if sampleScratch.capacity < count || sampleScratch.channelCount < channels {
                    sampleScratch = SampleBuffer(channelCount: max(channels, 2), capacity: max(count, 65536))
                }
                loaded.source.read(start: firstSample, count: count, into: sampleScratch, offset: 0)
                let pixelsPerSample = 1 / fpp
                let dots = pixelsPerSample >= 6
                for c in 0..<channels {
                    let laneTop = top + laneH * Double(c)
                    let mid = laneTop + laneH / 2
                    let half = laneH / 2 * 0.95 * amp
                    waveLineScratch.append(LineInstance(points: SIMD4(Float(p0), Float(mid.rounded()), Float(p1), Float(mid.rounded())),
                                                        color: centerLine, params: SIMD4(1, 0, 0, 0)))
                    let data = sampleScratch.channels[c]
                    let segment = SIMD4<Float>(Float(1.5 * s / 2), 0, 0, 0)
                    let dot = SIMD4<Float>(Float(4 * s / 2), 1, 0, 0)
                    var prev = SIMD2<Float>(.nan, .nan)
                    for k in 0..<count {
                        let frame = Double(region.position) + Double(firstSample + Int64(k) - region.sourceIn)
                        let x = editor.x(forFrame: frame) * s
                        let y = min(max(mid - Double(data[k]) * half, laneTop), laneTop + laneH)
                        let p = SIMD2<Float>(Float(x), Float(y))
                        if !prev.x.isNaN {
                            waveLineScratch.append(LineInstance(points: SIMD4(prev.x, prev.y, p.x, p.y), color: color, params: segment))
                        }
                        if dots {
                            waveLineScratch.append(LineInstance(points: SIMD4(p.x, p.y, p.x, p.y), color: color, params: dot))
                        }
                        prev = p
                    }
                }
                waveDraws.append(RegionDraw(kind: .lines, start: start, count: waveLineScratch.count - start))
            }
        }
    }

    /// Min and max per column straight from samples, for 1 to 16 frames per column.
    private static func rawColumns(_ data: UnsafeMutablePointer<Float>, start: Double, framesPerColumn fpp: Double,
                                   count n: Int, mins: UnsafeMutablePointer<Float>, maxs: UnsafeMutablePointer<Float>) {
        var i = 0
        while i < n {
            let a = Int((start + Double(i) * fpp).rounded(.down))
            let b = max(a + 1, Int((start + Double(i + 1) * fpp).rounded(.down)))
            var lo = data[a], hi = data[a]
            var k = a + 1
            while k < b {
                let v = data[k]
                lo = min(lo, v)
                hi = max(hi, v)
                k += 1
            }
            mins[i] = lo
            maxs[i] = hi
            i += 1
        }
    }

    private func rebuildMinimapIfNeeded(_ editor: EditorController, size: CGSize, scale: CGFloat) {
        let doc = editor.document
        let key = WaveKey(revision: doc.revision, loadedCount: doc.loaded.count, viewStart: 0, spp: 0, amplitude: 1,
                          size: CGSize(width: size.width, height: 0))
        if key == miniKey { return }
        miniKey = key
        let length = Double(editor.documentLength)
        guard length > 0 else {
            miniBuffer = nil
            miniCount = 0
            return
        }
        let w = Int(size.width)
        let s = Double(scale)
        let fpp = length / Double(w)
        let h = Double(TimelineLayout.minimapHeight) * s
        let mid = h / 2
        let half = h / 2 * 0.85
        let color = Theme.accent.blended(withFraction: 0.3, of: .white)!.withAlphaComponent(0.7).rgba
        var out: [RectInstance] = []
        if mins.count < w {
            mins = [Float](repeating: 0, count: w)
            maxs = mins
        }
        for region in doc.project.regions {
            guard let loaded = doc.loaded[region.sourceId] else { continue }
            let p0 = Int((Double(region.position) / fpp).rounded(.down))
            let p1 = min(w, Int((Double(region.end) / fpp).rounded(.up)))
            let n = p1 - p0
            guard n > 0 else { continue }
            let srcStart = Double(p0) * fpp - Double(region.position) + Double(region.sourceIn)
            let level = loaded.peaks.levelIndex(framesPerColumn: fpp) ?? 0
            var lo = [Float](repeating: 1, count: n), hi = [Float](repeating: -1, count: n)
            for c in 0..<loaded.peaks.channelCount {
                mins.withUnsafeMutableBufferPointer { mn in
                    maxs.withUnsafeMutableBufferPointer { mx in
                        loaded.peaks.columns(start: srcStart, framesPerColumn: fpp, count: n, channel: c, level: level,
                                             mins: mn.baseAddress!, maxs: mx.baseAddress!)
                        for i in 0..<n where mn[i] <= mx[i] {
                            lo[i] = min(lo[i], mn[i])
                            hi[i] = max(hi[i], mx[i])
                        }
                    }
                }
            }
            for i in 0..<n where lo[i] <= hi[i] {
                let t = mid - Double(hi[i]) * half
                let b = mid - Double(lo[i]) * half
                out.append(RectInstance(rect: [Float(p0 + i), Float(t), 1, Float(max(b - t, 1))], color: color))
            }
        }
        miniCount = out.count
        miniBuffer = out.isEmpty ? nil : device.makeBuffer(bytes: out, length: out.count * MemoryLayout<RectInstance>.stride)
    }
}
