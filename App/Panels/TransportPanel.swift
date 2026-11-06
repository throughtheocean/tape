import SwiftUI
import TapeCore

/// Play, loop, timecode, session rate and zoom.
struct TransportPanel: View {
    @ObservedObject var editor: EditorController
    @ObservedObject var document: TapeDocument
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 14) {
            Button(action: editor.togglePlay) {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help("Play / Pause (Space)")

            Toggle(isOn: Binding(get: { editor.loopEnabled }, set: { _ in editor.toggleLoop() })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Loop Playback (Command L)")

            TimecodeReadout(clock: editor.clock, editor: editor)

            if editor.isPlaying, editor.speed != 1 {
                Text(editor.speed > 0 ? "\(editor.speed)x" : "-\(abs(editor.speed))x")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: Theme.accent))
            }

            Spacer(minLength: 8)

            Picker("", selection: $editor.multitrack) {
                Text("Single").tag(false)
                Text("Multi").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Single or multitrack view (Shift Command M)")

            Picker("", selection: Binding(get: { editor.selectedTrackID },
                                          set: { editor.selectTrack($0, header: false); editor.revealSelectedLane() })) {
                ForEach(document.project.tracks) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 120)
            .disabled(document.project.tracks.count < 2)
            .help("Track shown in the single view")

            Spacer(minLength: 8)

            Text(rateText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.tapeSecondary)
                .help("Session rate")

            ZoomSlider(zoom: editor.zoom, editor: editor)
                .frame(width: 140)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tapeChrome)
    }

    private var rateText: String {
        guard let rate = document.project.sessionRate else { return "No audio" }
        let khz = rate / 1000
        let rateString = khz == khz.rounded() ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
        let ch = document.project.channelCount
        return "\(rateString)  \(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch) ch")"
    }
}

private struct TimecodeReadout: View {
    @ObservedObject var clock: PlayheadClock
    let editor: EditorController
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Menu {
            Picker("Display", selection: $settings.timeDisplay) {
                ForEach(TimeDisplay.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Frame Rate", selection: $settings.frameRate) {
                ForEach(AppSettings.frameRates, id: \.self) { r in
                    Text(r == r.rounded() ? String(format: "%.0f fps", r) : String(format: "%.3g fps", r)).tag(r)
                }
            }
        } label: {
            Text(TimeFormat(display: settings.timeDisplay, frameRate: settings.frameRate, sampleRate: editor.sessionRate)
                .string(clock.position))
                .font(.system(size: 22, weight: .light).monospacedDigit())
                .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Click to change the time display")
    }
}

private struct ZoomSlider: View {
    @ObservedObject var zoom: ZoomState
    let editor: EditorController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(Color.tapeSecondary)
            Slider(value: Binding(get: { zoom.normalized }, set: { editor.setZoomNormalized($0) }), in: 0...1)
                .controlSize(.small)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(Color.tapeSecondary)
        }
        .help("Zoom (Command scroll, pinch, Shift Z to fit)")
    }
}
