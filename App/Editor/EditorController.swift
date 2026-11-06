import AppKit
import Combine
import TapeCore

/// Playhead readout published at display rate, kept apart so other views do not re-render.
@MainActor
final class PlayheadClock: ObservableObject {
    @Published var position: Int64 = 0
}

/// Zoom readout for the transport slider.
@MainActor
final class ZoomState: ObservableObject {
    /// 0 is fit all, 1 is the closest zoom.
    @Published var normalized: Double = 0
}

/// State and actions of one editor window: transport, zoom, scroll and range.
@MainActor
final class EditorController: ObservableObject {
    let document: TapeDocument
    let playback = PlaybackEngine()
    let clock = PlayheadClock()
    let zoom = ZoomState()

    /// Called when anything the timeline draws has changed.
    var needsDisplay: (() -> Void)?
    /// Width of the timeline in points, set by the timeline view.
    var timelineWidth: Double = 1000 {
        didSet { if oldValue != timelineWidth { clampView(); updateZoomReadout() } }
    }

    private(set) var viewStart: Double
    private(set) var samplesPerPoint: Double
    private(set) var amplitudeZoom: Double
    @Published private(set) var range: SampleRange?
    @Published private(set) var loopEnabled: Bool
    @Published private(set) var isPlaying = false
    @Published private(set) var speed = 1
    @Published var errorMessage: String?
    /// Selected region ids.
    @Published var selection: Set<UUID> = [] {
        didSet { if oldValue != selection { needsDisplay?() } }
    }
    private(set) var playhead: Int64
    /// Timeline span of the recording in progress, drawn as a growing block.
    var recordingSpan: SampleRange? {
        didSet { if oldValue != recordingSpan { needsDisplay?() } }
    }
    /// Track the recording in progress goes to.
    var recordingTrack: UUID?

    enum Tool { case select, blade }
    @Published var tool: Tool = .select {
        didSet { needsDisplay?() }
    }
    /// Pointer feedback drawn by the timeline: hovered region (fade handles), hovered trim edge,
    /// blade position, rubber band and a short text next to the pointer while dragging.
    struct PointerOverlay: Equatable {
        var hoverRegion: UUID?
        var hoverEdge: (id: UUID, start: Bool)?
        var bladeFrame: Int64?
        var rubberBand: SampleRange?
        /// Vertical extent of the rubber band in the multitrack view.
        var rubberTop: Double?
        var rubberBottom: Double?
        var hint: String?
        var hintX: Double = 0
        var hintY: Double?

        static func == (a: PointerOverlay, b: PointerOverlay) -> Bool {
            a.hoverRegion == b.hoverRegion && a.hoverEdge?.id == b.hoverEdge?.id && a.hoverEdge?.start == b.hoverEdge?.start
                && a.bladeFrame == b.bladeFrame && a.rubberBand == b.rubberBand && a.rubberTop == b.rubberTop
                && a.rubberBottom == b.rubberBottom && a.hint == b.hint && a.hintX == b.hintX && a.hintY == b.hintY
        }
    }
    var pointer = PointerOverlay() {
        didSet { if oldValue != pointer { needsDisplay?() } }
    }
    /// Fires when a double click asks the inspector to focus the region name.
    let focusRegionName = PassthroughSubject<Void, Never>()

    // MARK: Tracks

    /// Multitrack view (lanes with headers) instead of the single track view.
    @Published var multitrack: Bool {
        didSet {
            guard oldValue != multitrack else { return }
            layoutChanged()
            revealSelectedLane()
        }
    }
    /// The track the single view shows, recordings go to and the inspector's Track section edits.
    @Published var selectedTrackID: UUID
    /// A track header is selected: Delete removes the track and the inspector shows the track.
    @Published var headerFocused = false {
        didSet { if oldValue != headerFocused { needsDisplay?() } }
    }
    @Published var laneHeight: Double {
        didSet { if oldValue != laneHeight { layoutChanged() } }
    }
    @Published var expandSelected: Bool {
        didSet { if oldValue != expandSelected { layoutChanged() } }
    }
    /// Vertical scroll of the lanes in the multitrack view, points.
    var laneScroll: Double = 0
    /// Height of the Metal timeline in points, set by the timeline view.
    var timelineHeight: Double = 600 {
        didSet { if oldValue != timelineHeight { layoutChanged() } }
    }
    /// Bumped whenever lane geometry changes, so cached waveforms rebuild.
    private(set) var layoutVersion = 0
    func bumpLayout() { layoutVersion += 1 }
    /// Meter state per track id, and the master channels.
    var trackMeters: [UUID: MeterBallistics] = [:]
    var masterMeters: [MeterBallistics] = [MeterBallistics(), MeterBallistics()]
    /// Loudness of what is played; integrated restarts when playback starts or on reset.
    var loudness = ChannelLoudness(sampleRate: 48000, channelCount: 2)
    var loudnessWasPlaying = false

    static let minSamplesPerPoint = 1.0 / 32
    private var subscriptions: Set<AnyCancellable> = []
    private var configuredFormat: (Double, Int)?
    private var lastLatencyLogged = false

    init(document: TapeDocument) {
        self.document = document
        let v = document.view
        viewStart = v.viewStart
        samplesPerPoint = v.samplesPerPoint ?? 0
        amplitudeZoom = v.amplitudeZoom
        range = v.range
        loopEnabled = v.loopEnabled
        playhead = v.playhead
        clock.position = playhead
        multitrack = v.multitrack
        selectedTrackID = v.selectedTrack.flatMap { document.project.track($0)?.id } ?? document.project.tracks[0].id
        laneHeight = Self.laneHeights.contains(v.laneHeight) ? v.laneHeight : 80
        expandSelected = v.expandSelected
        laneScroll = v.laneScroll

        document.$revision
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.documentChanged() }
            }
            .store(in: &subscriptions)
    }

    var documentLength: Int64 { document.project.length }
    var sessionRate: Double { document.sessionRate }

    // MARK: Document sync

    private func documentChanged() {
        if document.project.track(selectedTrackID) == nil {
            selectedTrackID = document.project.tracks[0].id
            headerFocused = false
        }
        layoutVersion += 1
        configureEngineIfNeeded()
        playback.setEditList(document.editList())
        updateLoop()
        if samplesPerPoint <= 0, documentLength > 0 { fitAll() }
        clampView()
        updateZoomReadout()
        needsDisplay?()
    }

    private func configureEngineIfNeeded() {
        guard let rate = document.project.sessionRate else { return }
        let format = (rate, document.project.channelCount)
        if let configuredFormat, configuredFormat == format { return }
        do {
            try playback.configure(sessionRate: rate, channelCount: format.1)
            playback.locate(playhead)
            configuredFormat = format
        } catch {
            errorMessage = "Audio output could not start: \(error.localizedDescription)"
        }
    }

    func saveView() {
        var v = document.view
        v.playhead = playhead
        v.range = range
        v.loopEnabled = loopEnabled
        v.viewStart = viewStart
        v.samplesPerPoint = samplesPerPoint > 0 ? samplesPerPoint : nil
        v.amplitudeZoom = amplitudeZoom
        v.multitrack = multitrack
        v.selectedTrack = selectedTrackID
        v.laneHeight = laneHeight
        v.expandSelected = expandSelected
        v.laneScroll = laneScroll
        guard v != document.view else { return }
        document.view = v
        document.scheduleSave()
    }

    // MARK: Display link

    /// Called once per display frame by the timeline.
    func tick() {
        guard isPlaying else { return }
        if !lastLatencyLogged {
            playback.updateStartLatency()
            if let ms = playback.lastStartLatencyMs {
                lastLatencyLogged = true
                NSLog("Tape play start latency: \(String(format: "%.1f", ms)) ms")
            }
        }
        var p = playback.position
        let loop = currentLoop()
        if speed > 0, loop == nil, p >= documentLength {
            p = documentLength
            stopPlayback(at: p)
        } else if speed < 0, loop == nil, p <= 0 {
            p = 0
            stopPlayback(at: p)
        }
        setPlayhead(p, follow: true)
    }

    private func setPlayhead(_ p: Int64, follow: Bool) {
        playhead = p
        if clock.position != p { clock.position = p }
        if follow { followPlayhead() }
        needsDisplay?()
    }

    /// Pages the view when the playhead leaves it during playback.
    private func followPlayhead() {
        guard samplesPerPoint > 0 else { return }
        let visible = timelineWidth * samplesPerPoint
        let p = Double(playhead)
        if p > viewStart + visible {
            viewStart = p
            clampView()
        } else if p < viewStart {
            viewStart = max(0, p - visible * 0.9)
        }
    }

    // MARK: Transport

    var lastStartLatencyMs: Double? { playback.lastStartLatencyMs }

    func togglePlay() {
        let recorder = RecordController.shared
        if recorder.isRecording {
            recorder.stopRecording()
            return
        }
        if isPlaying {
            stopPlayback(at: playback.position)
        } else {
            var from = playhead
            if currentLoop() == nil, from >= documentLength { from = 0 }
            startPlayback(from: from, speed: 1)
        }
    }

    func shuttleForward() {
        if isPlaying, speed > 0 {
            startPlayback(from: playback.position, speed: min(speed * 2, 8))
        } else {
            let from = playhead >= documentLength && currentLoop() == nil ? 0 : (isPlaying ? playback.position : playhead)
            startPlayback(from: from, speed: 1)
        }
    }

    func shuttleBackward() {
        if isPlaying, speed < 0 {
            startPlayback(from: playback.position, speed: max(speed * 2, -8))
        } else {
            let from = isPlaying ? playback.position : playhead
            startPlayback(from: from, speed: -1)
        }
    }

    func stop() {
        guard isPlaying else { return }
        stopPlayback(at: playback.position)
    }

    /// Loops `span` for a process preview; the caller has set the preview edit list or insert.
    func previewPlay(_ span: SampleRange) {
        guard !span.isEmpty else { return }
        playback.setLoop(span)
        let from = (span.start..<span.end).contains(playhead) && isPlaying ? playback.position : span.start
        startPlayback(from: from, speed: 1)
    }

    /// Back to the document's edit list and loop after a preview.
    func endPreview() {
        if isPlaying { stopPlayback(at: playback.position) }
        playback.setEditList(document.editList())
        updateLoop()
    }

    private func startPlayback(from: Int64, speed: Int) {
        guard document.project.sessionRate != nil else { return }
        configureEngineIfNeeded()
        lastLatencyLogged = false
        playback.play(from: from, speed: speed)
        isPlaying = true
        self.speed = speed
        setPlayhead(from, follow: false)
    }

    private func stopPlayback(at position: Int64) {
        playback.pause()
        isPlaying = false
        speed = 1
        let p = min(max(position, 0), max(documentLength, 0))
        playback.locate(p)
        setPlayhead(p, follow: false)
        saveView()
    }

    /// Moves the playhead; playback continues from there if running.
    func locate(_ frame: Int64) {
        let p = min(max(frame, 0), max(documentLength, 0))
        if isPlaying {
            playback.play(from: p, speed: speed)
        } else {
            playback.locate(p)
        }
        setPlayhead(p, follow: false)
        if !isPlaying { saveView() }
    }

    func goToStart() {
        locate(0)
        revealPlayhead()
    }

    func goToEnd() {
        locate(documentLength)
        revealPlayhead()
    }

    private func revealPlayhead() {
        let visible = timelineWidth * samplesPerPoint
        let p = Double(playhead)
        if p < viewStart || p > viewStart + visible {
            viewStart = p - visible / 2
            clampView()
            viewChanged()
        }
    }

    // MARK: Range and loop

    func setRangeIn() {
        let edge = snapped(playhead)
        let end = range.map { $0.end > edge ? $0.end : documentLength } ?? documentLength
        range = SampleRange(start: edge, end: max(end, edge))
        rangeChanged()
    }

    func setRangeOut() {
        let edge = snapped(playhead)
        let start = range.map { $0.start < edge ? $0.start : 0 } ?? 0
        range = SampleRange(start: min(start, edge), end: edge)
        rangeChanged()
    }

    /// Nearest zero crossing within 4 points (at most 10 ms) when snapping is on.
    func snapped(_ frame: Int64) -> Int64 {
        guard AppSettings.shared.snapToZeroCrossing, documentLength > 0, samplesPerPoint > 0 else { return frame }
        let radius = Int(min(max(4 * samplesPerPoint, 1), sessionRate * 0.01))
        let snapped = ZeroCrossing.nearest(in: document.editList(), around: frame, radius: radius)
        return min(max(snapped, 0), documentLength)
    }

    func clearRange() {
        guard range != nil else { return }
        range = nil
        rangeChanged()
    }

    func toggleLoop() {
        loopEnabled.toggle()
        updateLoop()
        saveView()
    }

    /// Sets the range directly, for Shift click and Shift drag marking.
    func setRange(_ r: SampleRange?) {
        range = r
        rangeChanged()
    }

    private func rangeChanged() {
        if let r = range, r.isEmpty { range = nil }
        updateLoop()
        saveView()
        needsDisplay?()
    }

    private func currentLoop() -> SampleRange? {
        guard loopEnabled else { return nil }
        if let range, !range.isEmpty { return range }
        return documentLength > 0 ? SampleRange(start: 0, end: documentLength) : nil
    }

    private func updateLoop() {
        playback.setLoop(currentLoop())
    }

    // MARK: Zoom and scroll

    var maxSamplesPerPoint: Double {
        let length = max(Double(documentLength), sessionRate * 10)
        return length / max(timelineWidth, 100) * 1.25
    }

    func fitAll() {
        guard documentLength > 0 else { return }
        samplesPerPoint = max(Self.minSamplesPerPoint, Double(documentLength) / max(timelineWidth - 20, 50))
        viewStart = 0
        viewChanged()
    }

    /// Zooms by `factor` (>1 zooms out) keeping the frame under `anchorX` in place.
    func zoom(by factor: Double, anchorX: Double) {
        guard samplesPerPoint > 0 else { return }
        let anchorFrame = viewStart + anchorX * samplesPerPoint
        samplesPerPoint = min(max(samplesPerPoint * factor, Self.minSamplesPerPoint), maxSamplesPerPoint)
        viewStart = anchorFrame - anchorX * samplesPerPoint
        viewChanged()
    }

    func zoomAroundPlayhead(by factor: Double) {
        let x = (Double(playhead) - viewStart) / max(samplesPerPoint, 1e-9)
        zoom(by: factor, anchorX: (0...timelineWidth).contains(x) ? x : timelineWidth / 2)
    }

    func scroll(byPoints dx: Double) {
        viewStart += dx * samplesPerPoint
        viewChanged()
    }

    func setView(start: Double, samplesPerPoint spp: Double) {
        samplesPerPoint = min(max(spp, Self.minSamplesPerPoint), maxSamplesPerPoint)
        viewStart = start
        viewChanged()
    }

    static let maxAmplitudeZoom = 32.0

    func zoomAmplitude(by factor: Double) {
        amplitudeZoom = min(max(amplitudeZoom * factor, 1), Self.maxAmplitudeZoom)
        viewChanged()
    }

    /// Amplitude zoom as 0 (1x) to 1 (32x), logarithmic.
    var amplitudeNormalized: Double { log(amplitudeZoom) / log(Self.maxAmplitudeZoom) }

    func setAmplitudeNormalized(_ value: Double) {
        zoomAmplitude(by: exp(min(max(value, 0), 1) * log(Self.maxAmplitudeZoom)) / amplitudeZoom)
    }

    /// Slider position 0 (fit) to 1 (closest), logarithmic.
    func setZoomNormalized(_ value: Double) {
        let lo = log(Self.minSamplesPerPoint), hi = log(maxSamplesPerPoint)
        let spp = exp(hi + (lo - hi) * min(max(value, 0), 1))
        let centerX = timelineWidth / 2
        let x = (Double(playhead) - viewStart) / max(samplesPerPoint, 1e-9)
        let anchor = (0...timelineWidth).contains(x) ? x : centerX
        zoom(by: spp / max(samplesPerPoint, 1e-12), anchorX: anchor)
    }

    private func updateZoomReadout() {
        guard samplesPerPoint > 0 else { return }
        let lo = log(Self.minSamplesPerPoint), hi = log(maxSamplesPerPoint)
        let n = (log(samplesPerPoint) - hi) / (lo - hi)
        let v = min(max(n, 0), 1)
        if abs(zoom.normalized - v) > 0.0005 { zoom.normalized = v }
    }

    private func clampView() {
        guard samplesPerPoint > 0 else { return }
        samplesPerPoint = min(samplesPerPoint, maxSamplesPerPoint)
        let visible = timelineWidth * samplesPerPoint
        let maxStart = max(0, Double(documentLength) - visible * 0.5)
        viewStart = min(max(viewStart, 0), maxStart)
    }

    private func viewChanged() {
        clampView()
        updateZoomReadout()
        needsDisplay?()
        saveView()
    }

    // MARK: Geometry

    func x(forFrame frame: Double) -> Double { (frame - viewStart) / samplesPerPoint }
    func frame(forX x: Double) -> Double { viewStart + x * samplesPerPoint }
}
