import AppKit
import AVFoundation
import Combine
import TapeCore

/// App wide input: device and format selection, pre-roll monitoring and recording into the
/// document of the window that pressed R.
@MainActor
final class RecordController: ObservableObject {
    static let shared = RecordController()

    let engine = RecordEngine()
    private let settings = AppSettings.shared

    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var isRecording = false
    /// Seconds since R was pressed.
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var dropouts: Int64 = 0
    @Published private(set) var inputError: String?
    @Published private(set) var sampleRate: Double = 0

    private var target: EditorController?
    private var placement: Int64 = 0
    private var recordTrack = Track.firstID
    private var fileName = ""
    private var statusTimer: Timer?

    private init() {
        refreshDevices()
        AudioDevices.observeDeviceList { Task { @MainActor in RecordController.shared.devicesChanged() } }
    }

    // MARK: Selection

    var device: InputDevice? {
        guard let uid = settings.recordDeviceUID, !uid.isEmpty else { return nil }
        return devices.first { $0.uid == uid }
    }

    var channels: [Int] {
        guard let device else { return settings.recordChannels }
        let choice = settings.recordChannels
        return device.channelChoices.contains(choice) ? choice : device.channelChoices[0]
    }

    /// First call picks the system default input when nothing was chosen before.
    func start() {
        if settings.recordDeviceUID == nil, let id = AudioDevices.defaultInputDevice,
           let d = devices.first(where: { $0.id == id }) {
            settings.recordDeviceUID = d.uid
        }
        restartInput()
    }

    func select(device: InputDevice?) {
        guard !isRecording else { return }
        settings.recordDeviceUID = device?.uid ?? ""
        restartInput()
    }

    func select(channels: [Int]) {
        guard !isRecording else { return }
        settings.recordChannels = channels
        restartInput()
    }

    func setPreRoll(_ seconds: Double) {
        guard !isRecording else { return }
        settings.preRollSeconds = min(max(seconds, 0), 60)
        restartInput()
    }

    func setContainer(_ container: AudioContainer) {
        settings.recordContainer = container
        if !container.sampleFormats.contains(settings.recordSampleFormat) {
            settings.recordSampleFormat = container.sampleFormats.last!
        }
    }

    private func refreshDevices() {
        devices = AudioDevices.inputDevices()
    }

    private func devicesChanged() {
        let before = device
        refreshDevices()
        if device != before, !isRecording { restartInput() }
    }

    private func restartInput() {
        engine.stopInput()
        inputError = nil
        needsPermission = false
        sampleRate = 0
        guard let device else {
            stopStatusTimer()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Never ask at launch: while the system prompt is pending, Core Audio blocks every new
            // audio stream of the process, including playback. The user asks from the record row.
            needsPermission = true
            stopStatusTimer()
            return
        default:
            showDenied()
            return
        }
        do {
            try engine.startInput(device: device, channels: channels, preRollSeconds: settings.preRollSeconds)
            sampleRate = engine.currentStatus().sampleRate
            startStatusTimer()
        } catch {
            inputError = "\(device.name) could not start: \(error.localizedDescription)"
        }
    }

    @Published private(set) var needsPermission = false

    /// Called from the record row; the window is frontmost, so the system prompt shows.
    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                let recorder = RecordController.shared
                recorder.needsPermission = false
                if granted { recorder.restartInput() } else { recorder.showDenied() }
            }
        }
    }

    private func showDenied() {
        inputError = "Microphone access is off. Allow Tape in System Settings, Privacy and Security, Microphone."
    }

    // MARK: Recording

    func toggleRecord(editor: EditorController) {
        if isRecording { stopRecording() } else { startRecording(editor: editor) }
    }

    func startRecording(editor: EditorController) {
        guard !isRecording else { return }
        if needsPermission {
            requestPermission()
            return
        }
        guard device != nil, engine.currentStatus().isMonitoring else {
            NSSound.beep()
            if inputError == nil { inputError = "Choose an input device to record." }
            return
        }
        if editor.isPlaying { editor.stop() }
        let doc = editor.document
        let p = editor.playhead
        // Multitrack records onto the selected track (the first when none is selected); placement looks at that track only.
        let track = editor.selectedTrackID
        let onTrack = doc.project.regions(onTrack: track)
        if let r = onTrack.first(where: { $0.position <= p && p < $0.end }) {
            placement = settings.recordSnapAfterRegion ? r.end : (onTrack.map(\.end).max() ?? 0)
        } else {
            placement = p
        }
        recordTrack = track
        let stamp = DateFormatter.recordingStamp.string(from: Date())
        let format = AudioFileFormat(container: settings.recordContainer, sampleFormat: settings.recordSampleFormat,
                                     sampleRate: sampleRate, channelCount: channels.count)
        fileName = "Recording \(stamp).\(format.fileExtension)"
        let url = doc.package.sourcesURL.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: doc.package.sourcesURL, withIntermediateDirectories: true)
            try engine.startRecording(to: url, container: format.container, sampleFormat: format.sampleFormat)
        } catch {
            inputError = "Recording could not start: \(error.localizedDescription)"
            return
        }
        target = editor
        editor.recordingTrack = recordTrack
        isRecording = true
        elapsed = 0
        dropouts = 0
        updateStatus()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let result = engine.stopRecording()
        let editor = target
        target = nil
        editor?.recordingSpan = nil
        editor?.recordingTrack = nil
        guard let result, let editor else { return }
        let track = editor.project.track(recordTrack) != nil ? recordTrack : editor.selectedTrackID
        let start = editor.document.addRecording(fileName: fileName, result: result, at: placement, track: track)
        editor.locate(start)
        if result.dropouts > 0 {
            inputError = "\(result.dropouts) dropouts during the last recording."
        }
    }

    // MARK: Status

    private func startStatusTimer() {
        guard statusTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { _ in
            Task { @MainActor in RecordController.shared.updateStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func updateStatus() {
        let status = engine.currentStatus()
        if let error = status.error, error != inputError { inputError = error }
        guard isRecording else { return }
        if !status.isRecording {
            stopRecording()
            return
        }
        let rate = max(status.sampleRate, 1)
        let live = Double(status.recordedFrames - status.preRollFrames) / rate
        if abs(live - elapsed) >= 0.05 { elapsed = live }
        if status.dropouts != dropouts { dropouts = status.dropouts }
        if let editor = target {
            let session = editor.document.project.sessionRate ?? rate
            let frames = Int64((Double(status.recordedFrames) * session / rate).rounded())
            editor.recordingSpan = SampleRange(start: placement, end: placement + frames)
        }
    }

    func resetClip() { engine.resetClip() }

    func editorClosing(_ editor: EditorController) {
        if isRecording, target === editor { stopRecording() }
    }

    func shutdown() {
        if isRecording { stopRecording() }
        engine.stopInput()
    }
}

extension DateFormatter {
    static let recordingStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
