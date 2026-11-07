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
        var layout = 0
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
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        encode(pass: pass, size: view.drawableSize, scale: view.window?.backingScaleFactor ?? 2, drawable: drawable)
    }

    /// Renders one frame into an offscreen image, for self tests while no display is available.
    func snapshot(size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.059, green: 0.059, blue: 0.063, alpha: 1)
        encode(pass: pass, size: size, scale: scale, drawable: nil)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func encode(pass: MTLRenderPassDescriptor, size: CGSize, scale: CGFloat, drawable: CAMetalDrawable?) {
        guard let editor else { return }
        let t0 = CACurrentMediaTime()
        guard size.width > 0, size.height > 0 else { return }

        rects.removeAll(keepingCapacity: true)
        lines.removeAll(keepingCapacity: true)
        let lanes = editor.lanes()
        buildBackground(editor, lanes: lanes, size: size, scale: scale)
        let backgroundEnd = rects.count
        buildLanes(editor, lanes: lanes, size: size, scale: scale)
        let regionBodyEnd = rects.count
        rebuildWaveformsIfNeeded(editor, lanes: lanes, size: size, scale: scale)
        rebuildMinimapIfNeeded(editor, size: size, scale: scale)
        let laneOverlayStart = rects.count
        buildLaneOverlays(editor, lanes: lanes, size: size, scale: scale)
        let overlayStart = rects.count
        buildOverlays(editor, size: size, scale: scale)

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
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

        // Background, grid and minimap background.
        drawRects(frameRects, start: 0, count: backgroundEnd)
        drawRects(miniBuffer, start: 0, count: miniCount)
        // Lanes, clipped to the lane area so scrolled lanes do not cover the minimap.
        let viewport = editor.laneViewport
        let clipTop = max(0, Int((viewport.top * Double(scale)).rounded()))
        let clipBottom = min(Int(size.height), Int((viewport.bottom * Double(scale)).rounded()))
        enc.setScissorRect(MTLScissorRect(x: 0, y: clipTop, width: Int(size.width), height: max(0, clipBottom - clipTop)))
        drawRects(frameRects, start: backgroundEnd, count: regionBodyEnd - backgroundEnd)
        // One draw call per region waveform.
        for d in waveDraws {
            switch d.kind {
            case .rects: drawRects(waveRects, start: d.start, count: d.count)
            case .lines: drawLines(waveLines, start: d.start, count: d.count)
            }
        }
        drawRects(frameRects, start: laneOverlayStart, count: overlayStart - laneOverlayStart)
        drawLines(frameLines, start: 0, count: lines.count)
        enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(size.width), height: Int(size.height)))
        // Range, loop, minimap window, playhead.
        drawRects(frameRects, start: overlayStart, count: rects.count - overlayStart)
        enc.endEncoding()

        guard let drawable else {
            cmd.commit()
            cmd.waitUntilCompleted()
            return
        }
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

    private func buildBackground(_ editor: EditorController, lanes: [Lane], size: CGSize, scale: CGFloat) {
        let w = Float(size.width), h = Float(size.height), s = Float(scale)
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

    }

    /// Lane backgrounds (multitrack), region bodies, name strips and placeholders.
    private func buildLanes(_ editor: EditorController, lanes: [Lane], size: CGSize, scale: CGFloat) {
        let w = Float(size.width), s = Float(scale)
        let doc = editor.document
        let selection = editor.selection
        let viewport = editor.laneViewport
        if editor.multitrack {
            for lane in lanes where lane.bottom > viewport.top && lane.top < viewport.bottom {
                let top = Float(lane.top) * s, height = Float(lane.height) * s
                if lane.track.id == editor.selectedTrackID {
                    rects.append(RectInstance(rect: [0, top, w, height], color: [1, 1, 1, editor.headerFocused ? 0.05 : 0.03]))
                } else if lane.index % 2 == 1 {
                    rects.append(RectInstance(rect: [0, top, w, height], color: [1, 1, 1, 0.012]))
                }
                rects.append(RectInstance(rect: [0, top + height - s, w, s], color: Theme.separator.rgba))
            }
        }
        for lane in lanes where lane.bottom > viewport.top && lane.top < viewport.bottom {
            let accent = Theme.trackColor(lane.track.color)
            let top = Float(lane.bodyTop) * s
            let bottom = Float(lane.bodyBottom) * s
            let strip = Float(lane.strip) * s
            let body0 = accent.withAlphaComponent(0.16).rgba, body1 = accent.withAlphaComponent(0.28).rgba
            let strip0 = accent.withAlphaComponent(0.42).rgba
            let strip1 = accent.blended(withFraction: 0.25, of: .white)!.withAlphaComponent(0.85).rgba
            let edge0 = accent.withAlphaComponent(0.75).rgba
            for region in doc.project.regions where region.trackId == lane.track.id {
                let x0 = px(editor, frame: Double(region.position), scale: scale)
                let x1 = px(editor, frame: Double(region.end), scale: scale)
                if x1 < 0 || x0 > w { continue }
                let a = max(x0, -2), b = min(x1, w + 2)
                let width = max(b - a, 1)
                let selected = selection.contains(region.id)
                if region.isGap {
                    // A gap: an empty frame, no waveform.
                    let edge: SIMD4<Float> = selected ? [1, 1, 1, 0.9] : [1, 1, 1, 0.22]
                    rects.append(RectInstance(rect: [a, top, width, bottom - top], color: [1, 1, 1, selected ? 0.06 : 0.025]))
                    rects.append(RectInstance(rect: [a, top, width, 1], color: edge))
                    rects.append(RectInstance(rect: [a, bottom - 1, width, 1], color: edge))
                    if x0 >= -1 { rects.append(RectInstance(rect: [x0, top, 1, bottom - top], color: edge)) }
                    if x1 <= w + 1 { rects.append(RectInstance(rect: [x1 - 1, top, 1, bottom - top], color: edge)) }
                    continue
                }
                let edge = selected ? SIMD4<Float>(1, 1, 1, 0.9) : edge0
                rects.append(RectInstance(rect: [a, top, width, bottom - top], color: selected ? body1 : body0))
                rects.append(RectInstance(rect: [a, top, width, strip], color: selected ? strip1 : strip0))
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
    }

    /// Pre-roll heads, the recording block, fades, rubber band, blade line and trim edge, inside the lanes.
    private func buildLaneOverlays(_ editor: EditorController, lanes: [Lane], size: CGSize, scale: CGFloat) {
        let w = Float(size.width), s = Float(scale)
        let project = editor.document.project
        let byTrack = Dictionary(lanes.map { ($0.track.id, $0) }, uniquingKeysWith: { a, _ in a })
        func span(_ trackId: UUID) -> (Float, Float)? {
            guard let lane = byTrack[trackId] else { return nil }
            return (Float(lane.bodyTop) * s, Float(lane.bodyBottom) * s)
        }

        // Pre-roll heads of recordings, dimmed up to the moment R was pressed.
        if let rate = project.sessionRate {
            for region in project.regions {
                guard let (top, bottom) = span(region.trackId), let ref = project.source(region.sourceId) else { continue }
                let head = min(ref.sessionPreRoll(sessionRate: rate) - region.sourceIn, region.length)
                guard head > 0 else { continue }
                let x0 = px(editor, frame: Double(region.position), scale: scale)
                let x1 = px(editor, frame: Double(region.position + head), scale: scale)
                if x1 < 0 || x0 > w { continue }
                rects.append(RectInstance(rect: [x0, top, max(x1 - x0, 1), bottom - top], color: [0, 0, 0, 0.5]))
                rects.append(RectInstance(rect: [x1 - s / 2, top, s, bottom - top], color: [1, 0.27, 0.23, 0.9]))
            }
        }
        if let rec = editor.recordingSpan, let (top, bottom) = span(editor.recordingTrack ?? editor.selectedTrackID) {
            let x0 = px(editor, frame: Double(rec.start), scale: scale)
            let x1 = px(editor, frame: Double(rec.end), scale: scale)
            if x1 >= 0, x0 <= w {
                rects.append(RectInstance(rect: [x0, top, max(x1 - x0, 1), bottom - top], color: [1, 0.27, 0.23, 0.22]))
                rects.append(RectInstance(rect: [x0, top, max(x1 - x0, 1), 2 * s], color: [1, 0.27, 0.23, 1]))
            }
        }

        buildFades(editor, lanes: byTrack, size: size, scale: scale)
        buildConnections(editor, lanes: byTrack, size: size, scale: scale)

        if let band = editor.pointer.rubberBand {
            let viewport = editor.laneViewport
            let top = Float(editor.pointer.rubberTop ?? viewport.top) * s
            let bottom = Float(editor.pointer.rubberBottom ?? viewport.bottom) * s
            let x0 = px(editor, frame: Double(band.start), scale: scale)
            let x1 = px(editor, frame: Double(band.end), scale: scale)
            rects.append(RectInstance(rect: [x0, top, max(x1 - x0, 1), bottom - top], color: [1, 1, 1, 0.08]))
            for r in [SIMD4<Float>(x0, top, x1 - x0, s), SIMD4<Float>(x0, bottom - s, x1 - x0, s),
                      SIMD4<Float>(x0, top, s, bottom - top), SIMD4<Float>(x1 - s, top, s, bottom - top)] {
                rects.append(RectInstance(rect: r, color: [1, 1, 1, 0.6]))
            }
        }
        if let frame = editor.pointer.bladeFrame, let id = editor.pointer.hoverRegion,
           let region = project.regions.first(where: { $0.id == id }), let (top, bottom) = span(region.trackId) {
            let x = px(editor, frame: Double(frame), scale: scale).rounded()
            rects.append(RectInstance(rect: [x - s / 2, top, s, bottom - top], color: [1, 0.85, 0.3, 0.95]))
        }
        if let edge = editor.pointer.hoverEdge, let r = project.regions.first(where: { $0.id == edge.id }),
           let (top, bottom) = span(r.trackId) {
            let x = px(editor, frame: Double(edge.start ? r.position : r.end), scale: scale)
            let x0 = edge.start ? x : x - 3 * s
            rects.append(RectInstance(rect: [x0, top, 3 * s, bottom - top], color: [1, 0.85, 0.3, 0.9]))
        }
    }

    /// Connector lines from connected regions to their anchors, the insertion point of a drag on a magnetic track
    /// and the region an Option Command drag would connect to. Connectors need both lanes, so multitrack only.
    private func buildConnections(_ editor: EditorController, lanes: [UUID: Lane], size: CGSize, scale: CGFloat) {
        let w = Float(size.width), s = Float(scale)
        let project = editor.document.project
        if editor.multitrack {
            let anchors = Set(project.regions.compactMap(\.anchor?.regionId))
            var byID: [UUID: Region] = [:]
            for r in project.regions where anchors.contains(r.id) { byID[r.id] = r }
            for r in project.regions {
                guard let anchor = r.anchor, let a = byID[anchor.regionId], let lane = lanes[r.trackId],
                      let anchorLane = lanes[a.trackId] else { continue }
                let x = px(editor, frame: Double(r.position), scale: scale).rounded()
                if x < -2 || x > w + 2 { continue }
                let color = Theme.trackColor(lane.track.color).withAlphaComponent(0.9).rgba
                // Lanes sit next to each other, so the line reaches into both regions to stay visible.
                let up = anchorLane.top < lane.top
                let reach: Float = up ? 10 * s : -10 * s
                let from = Float(up ? lane.bodyTop : lane.bodyBottom) * s + reach
                let to = Float(up ? anchorLane.bodyBottom : anchorLane.bodyTop) * s - reach
                rects.append(RectInstance(rect: [x, min(from, to), 1.5 * s, abs(to - from)], color: color))
                rects.append(RectInstance(rect: [x - 2 * s, to - 2.75 * s, 5.5 * s, 5.5 * s], color: color))
            }
        }
        if let insertion = editor.pointer.insertion, let lane = lanes[insertion.track] {
            let x = px(editor, frame: Double(insertion.frame), scale: scale).rounded()
            let top = Float(lane.bodyTop) * s, bottom = Float(lane.bodyBottom) * s
            let color = Theme.accent.blended(withFraction: 0.5, of: .white)!.rgba
            rects.append(RectInstance(rect: [x - 1.5 * s, top - 4 * s, 3 * s, bottom - top + 8 * s], color: color))
        }
        if let id = editor.pointer.connectTarget, let r = project.regions.first(where: { $0.id == id }), let lane = lanes[r.trackId] {
            let x0 = px(editor, frame: Double(r.position), scale: scale), x1 = px(editor, frame: Double(r.end), scale: scale)
            let top = Float(lane.bodyTop) * s, bottom = Float(lane.bodyBottom) * s
            let c = Theme.accent.rgba
            for rect in [SIMD4<Float>(x0, top, x1 - x0, 2 * s), SIMD4<Float>(x0, bottom - 2 * s, x1 - x0, 2 * s),
                         SIMD4<Float>(x0, top, 2 * s, bottom - top), SIMD4<Float>(x1 - 2 * s, top, 2 * s, bottom - top)] {
                rects.append(RectInstance(rect: rect, color: c))
            }
        }
    }

    /// Range, loop bar, minimap window and playhead, over everything.
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
        if editor.loopEnabled, let loop = editor.loopSpan {
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

    // MARK: Fades

    /// Fade overlays: the attenuated part above the curve shaded, the curve as a line,
    /// and on the hovered region the corner and midpoint handles.
    private func buildFades(_ editor: EditorController, lanes: [UUID: Lane], size: CGSize, scale: CGFloat) {
        let w = Float(size.width), s = Float(scale)
        let shade = SIMD4<Float>(0, 0, 0, 0.42)
        let curve = SIMD4<Float>(1, 1, 1, 0.85)
        let lineParams = SIMD4<Float>(0.75 * s, 0, 0, 0)
        let step: Float = 2 * s

        for region in editor.project.regions {
            guard let lane = lanes[region.trackId] else { continue }
            let top = Float(lane.waveTop) * s
            let bottom = Float(lane.bodyBottom) * s
            let x0 = px(editor, frame: Double(region.position), scale: scale)
            let x1 = px(editor, frame: Double(region.end), scale: scale)
            if x1 < 0 || x0 > w { continue }
            for (fade, isIn) in [(region.fadeIn, true), (region.fadeOut, false)] where fade.length > 0 {
                let a = isIn ? x0 : px(editor, frame: Double(region.end - fade.length), scale: scale)
                let b = isIn ? px(editor, frame: Double(region.position + fade.length), scale: scale) : x1
                let span = b - a
                guard span > 0.5, b >= 0, a <= w else { continue }
                func y(_ x: Float) -> Float {
                    let t = Double(min(max((x - a) / span, 0), 1))
                    let g = FadeCurves.value(fade, at: isIn ? t : 1 - t)
                    return top + (1 - g) * (bottom - top)
                }
                var x = max(a, -step)
                let end = min(b, w + step)
                var prev = SIMD2<Float>(x, y(x))
                while x < end {
                    let nx = min(x + step, b)
                    let ny = y(nx)
                    let colTop = top, colBottom = min(prev.y, ny)
                    if colBottom > colTop { rects.append(RectInstance(rect: [x, colTop, nx - x, colBottom - colTop], color: shade)) }
                    lines.append(LineInstance(points: [prev.x, prev.y, nx, ny], color: curve, params: lineParams))
                    prev = SIMD2(nx, ny)
                    x = nx
                }
            }
        }

        // Handles on the hovered region, or on the region being dragged.
        guard let id = editor.pointer.hoverRegion, let region = editor.project.regions.first(where: { $0.id == id }),
              let lane = lanes[region.trackId] else { return }
        let handles = FadeHandles(region, editor: editor, lane: lane)
        let size = Float(TimelineLayout.handleSize) * s
        for corner in [handles.inCorner, handles.outCorner] {
            let cx = Float(corner.x) * s, cy = Float(corner.y) * s
            rects.append(RectInstance(rect: [cx - size / 2 - s, cy - size / 2 - s, size + 2 * s, size + 2 * s], color: [0, 0, 0, 0.7]))
            rects.append(RectInstance(rect: [cx - size / 2, cy - size / 2, size, size], color: [1, 1, 1, 0.95]))
        }
        for mid in [handles.inMid, handles.outMid].compactMap({ $0 }) {
            let p = SIMD2<Float>(Float(mid.x) * s, Float(mid.y) * s)
            lines.append(LineInstance(points: [p.x, p.y, p.x, p.y], color: [0, 0, 0, 0.7], params: [4.5 * s, 1, 0, 0]))
            lines.append(LineInstance(points: [p.x, p.y, p.x, p.y], color: [1, 1, 1, 0.95], params: [3.5 * s, 1, 0, 0]))
        }
    }

    // MARK: Waveforms

    private func rebuildWaveformsIfNeeded(_ editor: EditorController, lanes: [Lane], size: CGSize, scale: CGFloat) {
        let doc = editor.document
        let key = WaveKey(revision: doc.revision, loadedCount: doc.loaded.count, viewStart: editor.viewStart,
                          spp: editor.samplesPerPoint, amplitude: editor.amplitudeZoom, size: size, layout: editor.layoutVersion)
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
        let viewport = editor.laneViewport
        var colors: [UUID: (SIMD4<Float>, SIMD4<Float>)] = [:]
        var spans: [UUID: (Double, Double)] = [:]
        for lane in lanes where lane.bottom > viewport.top && lane.top < viewport.bottom {
            let accent = Theme.trackColor(lane.track.color)
            colors[lane.track.id] = (accent.blended(withFraction: 0.45, of: .white)!.withAlphaComponent(0.95).rgba,
                                     accent.withAlphaComponent(0.35).rgba)
            spans[lane.track.id] = (lane.waveTop * s + 2 * s, lane.bodyBottom * s - 2 * s)
        }

        for region in doc.project.regions {
            guard let (top, bottom) = spans[region.trackId], let (color, centerLine) = colors[region.trackId],
                  bottom - top > 2, let loaded = doc.loaded[region.sourceId] else { continue }
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
