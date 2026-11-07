import AppKit
import SwiftUI
import TapeCore

/// Top row: device, channels, bit depth, container, pre-roll, monitoring, input meter, record button, elapsed.
struct RecordRow: View {
    @ObservedObject var recorder = RecordController.shared
    @ObservedObject var settings = AppSettings.shared
    let editor: EditorController

    static let preRollChoices: [Double] = [0, 2, 5, 10, 15, 20, 30, 45, 60]

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { recorder.device?.uid ?? "" }, set: { uid in
                recorder.select(device: recorder.devices.first { $0.uid == uid })
            })) {
                Text("No Input").tag("")
                ForEach(recorder.devices) { d in Text(d.name).tag(d.uid) }
            }
            .labelsHidden()
            .frame(maxWidth: 190)
            .help("Input device. Tape never changes the system input or output.")

            Picker("", selection: Binding(get: { recorder.channels }, set: { recorder.select(channels: $0) })) {
                ForEach(recorder.device?.channelChoices ?? [[0, 1]], id: \.self) { c in
                    Text(c.count == 2 ? "Ch \(InputDevice.label(c))" : "Ch \(c[0] + 1)").tag(c)
                }
            }
            .labelsHidden()
            .frame(width: 84)
            .disabled(recorder.device == nil || recorder.isRecording)
            .help("Input channels: a pair records stereo, a single channel records mono")

            Picker("", selection: $settings.recordSampleFormat) {
                ForEach(settings.recordContainer.sampleFormats, id: \.self) { f in
                    Text(f == .float32 ? "32f" : "\(f.bits)").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(recorder.isRecording)
            .help("Bit depth")

            Picker("", selection: Binding(get: { settings.recordContainer }, set: { recorder.setContainer($0) })) {
                ForEach(AudioContainer.recordable, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(recorder.isRecording)
            .help("File format")

            Picker("", selection: Binding(get: { settings.preRollSeconds }, set: { recorder.setPreRoll($0) })) {
                ForEach(Self.preRollChoices, id: \.self) { s in
                    Text(s == 0 ? "No pre-roll" : "Pre-roll \(Int(s)) s").tag(s)
                }
            }
            .labelsHidden()
            .frame(width: 118)
            .disabled(recorder.isRecording)
            .help("Seconds of input kept before R is pressed")

            Picker("", selection: Binding(get: { settings.inputMonitoring }, set: { recorder.setMonitoring($0) })) {
                ForEach(InputMonitoring.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 136)
            .disabled(recorder.device == nil || recorder.isRecording)
            .help("Through plays the selected input on the output. Use headphones: with speakers and a microphone it feeds back.")

            if let ms = recorder.monitoringLatencyMs, recorder.device != nil {
                let through = settings.inputMonitoring == .through
                Text(String(format: "%.1f ms", ms) + (through && recorder.monitorDevicesDiffer ? ", may click: different devices" : ""))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(through ? Color.tapePrimary : Color.tapeSecondary)
                    .help("Round trip from input to output: input latency and buffer, output buffer and latency. With input and output on different devices, their clocks drift and the monitor can click now and then; the recording is not affected.")
            }

            if recorder.needsPermission {
                Button("Allow Microphone") { recorder.requestPermission() }
                    .help("Tape needs microphone access to monitor and record the selected input")
            } else {
                InputMeter()
                    .frame(minWidth: 90, maxWidth: 220, minHeight: 18, maxHeight: 18)
                    .help("Input level, peak hold 1.5 s. Click to clear the clip indicator.")
            }

            Button {
                recorder.toggleRecord(editor: editor)
            } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                    .foregroundStyle(recorder.isRecording ? Color.white : Color.red)
                    .frame(width: 18)
            }
            .help(recorder.isRecording ? "Stop Recording (R or Space)" : "Record (R)")

            Text(elapsedText)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(recorder.isRecording ? Color.red : Color.tapeSecondary)
                .frame(width: 64, alignment: .leading)

            if recorder.dropouts > 0 {
                Text("\(recorder.dropouts) dropouts")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.orange)
            }
            if let error = recorder.inputError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(error)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Color.tapeChrome)
    }

    private var elapsedText: String {
        let t = max(recorder.elapsed, 0)
        let m = Int(t) / 60, s = Int(t) % 60, tenths = Int((t * 10).rounded(.down)) % 10
        return String(format: "%d:%02d.%d", m, s, tenths)
    }
}

/// Horizontal peak and RMS bars per channel, read from the record engine at display rate.
struct InputMeter: NSViewRepresentable {
    func makeNSView(context: Context) -> InputMeterView { InputMeterView() }
    func updateNSView(_ nsView: InputMeterView, context: Context) {}
}

@MainActor
final class InputMeterView: NSView {
    private var link: CADisplayLink?
    private var meters: [RecordEngine.ChannelMeter] = []

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        let next = RecordController.shared.engine.currentStatus().meters
        if next != meters {
            meters = next
            needsDisplay = true
        }
    }

    private static func position(_ linear: Float) -> CGFloat {
        guard linear > 0 else { return 0 }
        let db = 20 * log10(Double(linear))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.06).setFill()
        bounds.fill()
        let clipW: CGFloat = 8
        let barW = bounds.width - clipW - 3
        let count = max(meters.count, 1)
        let gap: CGFloat = 2
        let h = (bounds.height - gap * CGFloat(count - 1)) / CGFloat(count)
        let green = NSColor(hex: 0x34C759), yellow = NSColor(hex: 0xF5C542), red = NSColor(hex: 0xFF453A)
        // Marks at -18 and -6 dBFS.
        NSColor(white: 1, alpha: 0.15).setFill()
        for db in [-18.0, -6.0] {
            NSRect(x: barW * CGFloat((db + 60) / 60), y: 0, width: 1, height: bounds.height).fill()
        }
        var clipped = false
        for (i, m) in meters.enumerated() {
            let y = CGFloat(i) * (h + gap)
            let rms = barW * Self.position(m.rms)
            let peak = barW * Self.position(m.peak)
            let color = m.peak >= 0.5 ? (m.peak >= 0.89 ? red : yellow) : green
            color.withAlphaComponent(0.45).setFill()
            NSRect(x: 0, y: y, width: peak, height: h).fill()
            color.setFill()
            NSRect(x: 0, y: y, width: rms, height: h).fill()
            NSColor.white.setFill()
            NSRect(x: max(barW * Self.position(m.hold) - 1, 0), y: y, width: 2, height: h).fill()
            clipped = clipped || m.clipped
        }
        (clipped ? red : NSColor(white: 1, alpha: 0.12)).setFill()
        NSRect(x: bounds.width - clipW, y: 0, width: clipW, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        RecordController.shared.resetClip()
    }
}
