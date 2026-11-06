import AppKit
import QuartzCore
import TapeCore

/// Acceptance measurements, started with `-TapeBenchmark <audio file>` on the command line.
/// Imports the file into a scratch document on the fastest display, scripts scroll and zoom,
/// measures frame pacing and play start latency, writes `/tmp/tape-benchmark.txt` and quits.
/// With `-TapeBenchmarkTracks <n>` the document gets n tracks with a 2 hour region each, the sweep runs in the
/// multitrack view, then the view toggles every frame, then a region moves across lanes on every frame while playing.
@MainActor
final class Benchmark {
    private let audioPath: String
    private weak var app: AppDelegate?
    private var controller: MainWindowController?
    private var link: CADisplayLink?
    private var phaseStart: CFTimeInterval = 0
    private var presented: [CFTimeInterval] = []
    private var cpu: [Double] = []
    private var gpu: [Double] = []
    private var lines: [String] = []
    private var importStart: CFTimeInterval = 0
    private var fitSpp: Double = 1
    private static let animationSeconds = 10.0
    private static let phaseSeconds = 4.0
    private let savedOpenDocuments = AppSettings.shared.openDocuments
    private let trackCount = UserDefaults.standard.integer(forKey: "TapeBenchmarkTracks")
    private enum Phase { case sweep, toggle, dragWhilePlaying }
    private var phase = Phase.sweep

    init(audioPath: String, app: AppDelegate) {
        self.audioPath = audioPath
        self.app = app
    }

    func start() {
        guard let app, let doc = try? TapeDocument.createUntitled() else { return finish() }
        let controller = app.show(doc)
        self.controller = controller
        NSApp.activate(ignoringOtherApps: true)
        if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            controller.window?.setFrame(screen.visibleFrame, display: true)
            log("screen: \(screen.localizedName), max \(screen.maximumFramesPerSecond) Hz, \(Int(screen.frame.width))x\(Int(screen.frame.height)) pt, scale \(screen.backingScaleFactor)")
        }
        importStart = CACurrentMediaTime()
        controller.importAudio(urls: [URL(fileURLWithPath: audioPath)])
        log("file: \(audioPath)")
        waitForLoad()
    }

    private func waitForLoad() {
        guard let doc = controller?.tapeDocument else { return }
        if doc.loaded.isEmpty, doc.failures.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitForLoad() }
            return
        }
        if let failure = doc.failures.values.first {
            log("load failed: \(failure)")
            return finish()
        }
        let ready = CACurrentMediaTime() - importStart
        if let t = doc.peakTimes.values.first { log(String(format: "peak pyramid build: %.2f s", t)) }
        log(String(format: "import to waveform ready: %.2f s", ready))
        if let source = doc.loaded.values.first {
            log("frames: \(source.source.frameCount), channels: \(source.source.channelCount), rate: \(source.source.sampleRate)")
        }
        waitForActive(deadline: CACurrentMediaTime() + 30)
    }

    /// An inactive app's display link is held at 60 Hz, so the run waits until Tape is frontmost.
    private func waitForActive(deadline: CFTimeInterval) {
        if !NSApp.isActive, CACurrentMediaTime() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForActive(deadline: deadline) }
            return
        }
        log("app active during run: \(NSApp.isActive ? "yes" : "no"), window key: \(controller?.window?.isKeyWindow == true ? "yes" : "no")")
        if trackCount > 1 { buildTracks() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startAnimation() }
    }

    /// One 2 hour region per track, each from a different part of the source.
    private func buildTracks() {
        guard let controller, let source = controller.tapeDocument.project.sources.first else { return }
        let rate = source.sampleRate
        let length = Int64(2 * 3600 * rate)
        let step = max(0, (source.frameCount - length) / Int64(trackCount))
        controller.tapeDocument.apply("Benchmark Tracks") { p in
            p.regions = []
            while p.tracks.count < self.trackCount { _ = EditOperations.addTrack(&p, at: p.tracks.count) }
            for (i, t) in p.tracks.enumerated() {
                let start = Int64(i) * step
                p.regions.append(Region(name: "Take \(i + 1)", trackId: t.id, sourceId: source.id, sourceIn: start,
                                        sourceOut: min(source.frameCount, start + length), position: 0))
            }
        }
        controller.editor.multitrack = true
        log(String(format: "multitrack: %d tracks, %.2f h each, view %@", trackCount, Double(length) / rate / 3600,
                   controller.editor.multitrack ? "multi" : "single"))
    }

    private func startAnimation() {
        guard let controller else { return }
        controller.editor.fitAll()
        fitSpp = controller.editor.samplesPerPoint
        controller.timeline.renderer?.timingSink = { [weak self] t in self?.record(t) }
        controller.timeline.tickDurations = []
        let link = controller.timeline.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        phaseStart = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard self.ticks == 0, let link = self.link else { return }
            link.invalidate()
            self.link = nil
            self.log("display link not running (screen locked?): frame pacing skipped")
            self.runWithoutDisplay()
        }
    }

    /// Main thread cost of a view toggle, and the drag while playing on a 120 Hz timer.
    private func runWithoutDisplay() {
        guard trackCount > 1, let controller else { return finish() }
        let editor = controller.editor
        var toggles: [Double] = []
        for _ in 0..<240 {
            let t0 = CACurrentMediaTime()
            editor.multitrack.toggle()
            controller.timeline.needsLayout = true
            controller.timeline.layoutSubtreeIfNeeded()
            if editor.multitrack { controller.timeline.headers.refresh() }
            controller.timeline.labels.update()
            toggles.append((CACurrentMediaTime() - t0) * 1000)
        }
        toggles.sort()
        log(String(format: "toggle Single and Multi, main thread layout, headers and labels ms (no GPU), n=%d: p50 %.3f, p99 %.3f, max %.3f",
                   toggles.count, toggles[toggles.count / 2], toggles[toggles.count * 99 / 100], toggles.last!))
        editor.multitrack = true
        editor.setView(start: 0, samplesPerPoint: 200)
        editor.playback.outputVolume = 0
        editor.locate(0)
        underrunsAtStart = editor.playback.underruns.load()
        editor.togglePlay()
        editor.document.beginGesture()
        phaseStart = CACurrentMediaTime()
        var steps: [Double] = []
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = CACurrentMediaTime() - self.phaseStart
                guard t <= Self.phaseSeconds else {
                    self.timer?.invalidate()
                    self.timer = nil
                    editor.document.endGesture("Move")
                    let underruns = editor.playback.underruns.load() - self.underrunsAtStart
                    let played = editor.playback.position
                    editor.stop()
                    steps.sort()
                    self.log(String(format: "drag across lanes while playing on a 120 Hz timer: %d steps, %d lane changes, step ms p50 %.3f, p99 %.3f, max %.3f",
                                    steps.count, self.laneChanges, steps[steps.count / 2], steps[steps.count * 99 / 100], steps.last!))
                    self.log("playhead advanced to \(played) frames, playback underruns while dragging: \(underruns)")
                    self.finish()
                    return
                }
                let t0 = CACurrentMediaTime()
                self.dragStep(editor, t: t)
                controller.timeline.headers.refresh()
                steps.append((CACurrentMediaTime() - t0) * 1000)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var timer: Timer?

    /// First half: continuous zoom sweep from fit all to 1/16 sample per point and back while
    /// panning, covering every pyramid level and the per sample view. Second half: fast pan.
    private var ticks = 0
    private var tickIntervals: [Double] = []

    @objc private func step(_ link: CADisplayLink) {
        guard let editor = controller?.editor else { return }
        ticks += 1
        tickIntervals.append((link.targetTimestamp - link.timestamp) * 1000)
        let t = CACurrentMediaTime() - phaseStart
        let length = Double(editor.documentLength)
        if phase == .toggle {
            if t > Self.phaseSeconds { return nextPhase(link) }
            editor.multitrack.toggle()
            return
        }
        if phase == .dragWhilePlaying {
            if t > Self.phaseSeconds { return nextPhase(link) }
            dragStep(editor, t: t)
            return
        }
        if t > Self.animationSeconds {
            if trackCount > 1 { return nextPhase(link) }
            link.invalidate()
            self.link = nil
            controller?.timeline.renderer?.timingSink = nil
            reportFrames()
            measureLatency(remaining: 20)
            return
        }
        let half = Self.animationSeconds / 2
        if t < half {
            let u = 0.5 - 0.5 * cos(2 * Double.pi * t / half)
            let spp = exp(Foundation.log(fitSpp) + (Foundation.log(1.0 / 16) - Foundation.log(fitSpp)) * u)
            let center = length * (0.2 + 0.6 * t / half)
            editor.setView(start: center - spp * editor.timelineWidth / 2, samplesPerPoint: spp)
        } else {
            let spp = 2000.0
            let visible = spp * editor.timelineWidth
            let start = (length - visible) * (t - half) / half
            editor.setView(start: start, samplesPerPoint: spp)
        }
    }

    private func nextPhase(_ link: CADisplayLink) {
        guard let editor = controller?.editor else { return }
        switch phase {
        case .sweep:
            log("phase: zoom and pan sweep, multitrack view")
            reportFrames()
            phase = .toggle
            editor.fitAll()
        case .toggle:
            log("phase: Single and Multi toggled on every display frame")
            reportFrames()
            editor.multitrack = true
            phase = .dragWhilePlaying
            editor.setView(start: 0, samplesPerPoint: 200)
            editor.playback.outputVolume = 0
            editor.locate(0)
            underrunsAtStart = editor.playback.underruns.load()
            editor.togglePlay()
            editor.document.beginGesture()
        case .dragWhilePlaying:
            editor.document.endGesture("Move")
            let underruns = editor.playback.underruns.load() - underrunsAtStart
            editor.stop()
            log("phase: region 1 moved across all lanes on every display frame while playing")
            reportFrames()
            log("lane changes: \(laneChanges), playback underruns while dragging: \(underruns)")
            link.invalidate()
            self.link = nil
            controller?.timeline.renderer?.timingSink = nil
            measureLatency(remaining: 10)
            return
        }
        presented = []
        cpu = []
        gpu = []
        ticks = 0
        tickIntervals = []
        controller?.timeline.tickDurations = []
        phaseStart = CACurrentMediaTime()
    }

    private var underrunsAtStart: Int64 = 0
    private var laneChanges = 0
    private var lastLane = 0

    /// Moves the first region down and up through every lane, and a little in time, as a drag would.
    private func dragStep(_ editor: EditorController, t: Double) {
        guard let base = editor.document.gestureBase,
              let id = base.regions.first(where: { $0.trackId == base.tracks[0].id })?.id else { return }
        let n = trackCount
        let cycle = Int(t * 6) % (2 * n - 2)
        let lane = cycle < n ? cycle : 2 * n - 2 - cycle
        let delta = Int64(sin(t * 3) * 48000)
        editor.document.updateGesture {
            _ = EditOperations.move(&$0, ids: [id], by: delta)
            _ = EditOperations.moveToTrack(&$0, ids: [id], byLanes: lane)
        }
        if lane != lastLane { laneChanges += 1 }
        lastLane = lane
    }

    private func record(_ t: FrameTiming) {
        if let p = t.presentedTime, p > 0 { presented.append(p) }
        if t.cpuMs >= 0 { cpu.append(t.cpuMs) }
        if let g = t.gpuMs { gpu.append(g) }
    }

    private func reportFrames() {
        let intervals = zip(presented.dropFirst(), presented).map { ($0 - $1) * 1000 }.sorted()
        func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * p))] }
        let span = (presented.last ?? 0) - (presented.first ?? 0)
        let fps = span > 0 ? Double(presented.count - 1) / span : 0
        let budget = 1000.0 / 120
        let hitches = intervals.filter { $0 > budget * 1.5 }.count
        log(String(format: "frames presented: %d in %.2f s = %.1f fps", presented.count, span, fps))
        log(String(format: "present interval ms: p50 %.2f, p95 %.2f, p99 %.2f, max %.2f; intervals > 12.5 ms: %d",
                   pct(intervals, 0.5), pct(intervals, 0.95), pct(intervals, 0.99), intervals.last ?? 0, hitches))
        let c = cpu.sorted(), g = gpu.sorted()
        log(String(format: "cpu build+encode ms: p50 %.2f, p99 %.2f, max %.2f", pct(c, 0.5), pct(c, 0.99), c.last ?? 0))
        log(String(format: "gpu ms: p50 %.2f, p99 %.2f, max %.2f", pct(g, 0.5), pct(g, 0.99), g.last ?? 0))
        log("waveform rebuilds: \(controller?.timeline.renderer?.waveRebuilds ?? 0)")
        let td = (controller?.timeline.tickDurations ?? []).sorted()
        controller?.timeline.tickDurations = nil
        log(String(format: "timeline tick on main thread ms (playhead, waveform build, encode, ruler, labels): p50 %.2f, p99 %.2f, max %.2f",
                   pct(td, 0.5), pct(td, 0.99), td.last ?? 0))
        let ti = tickIntervals.sorted()
        log(String(format: "display link: %d ticks in %.1f s, frame duration p50 %.2f ms", ticks, Self.animationSeconds, pct(ti, 0.5)))
    }

    private var latencies: [Double] = []

    private func measureLatency(remaining: Int) {
        guard let editor = controller?.editor else { return finish() }
        if remaining == 0 {
            let s = latencies.sorted()
            if !s.isEmpty {
                log(String(format: "play start, engine part (request to first frame handed to output unit) ms, n=%d: min %.1f, median %.1f, max %.1f",
                           s.count, s.first!, s[s.count / 2], s.last!))
                log(String(format: "output device latency reported by the engine: %.1f ms", editor.playback.outputLatencyMs))
            }
            return finish()
        }
        let length = editor.documentLength
        editor.playback.outputVolume = 0
        editor.locate(Int64.random(in: 0..<max(length, 1)))
        editor.togglePlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            editor.playback.updateStartLatency()
            if let ms = editor.playback.lastEngineLatencyMs { self.latencies.append(ms) }
            editor.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.measureLatency(remaining: remaining - 1) }
        }
    }

    private func log(_ line: String) {
        NSLog("TapeBenchmark \(line)")
        lines.append(line)
    }

    private func finish() {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: "/tmp/tape-benchmark.txt", atomically: true, encoding: .utf8)
        if let controller { app?.discard(controller) }
        AppSettings.shared.openDocuments = savedOpenDocuments
        NSApp.terminate(nil)
    }
}
