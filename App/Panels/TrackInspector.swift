import SwiftUI
import TapeCore

/// Inspector for the track whose header is selected: name, color, gain, pan, mute, solo and region count.
struct TrackInspector: View {
    @ObservedObject var editor: EditorController
    let track: Track

    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TRACK")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tapeSecondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(commitName)
                .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            HStack {
                Text("Color").foregroundStyle(Color.tapeSecondary)
                Spacer()
                Picker("", selection: Binding(get: { track.color }, set: { color in
                    editor.updateTrack("Track Color", track.id) { $0.color = color }
                })) {
                    ForEach(0..<Track.paletteCount, id: \.self) { i in
                        Text(Fader.colorNames[i]).tag(i)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: Theme.trackColor(track.color)))
                    .frame(width: 12, height: 12)
            }
            sliderRow("Gain", Fader.text(track.gainDB), value: Binding(
                get: { Fader.position(dB: track.gainDB) },
                set: { v in
                    var dB = Fader.dB(position: v)
                    if abs(dB) < 0.3 { dB = 0 }
                    change { $0.gainDB = dB }
                }), name: "Track Gain")
            sliderRow("Pan", Fader.panText(track.pan), value: Binding(
                get: { (track.pan + 1) / 2 },
                set: { v in
                    var pan = v * 2 - 1
                    if abs(pan) < 0.04 { pan = 0 }
                    pan = (pan * 100).rounded() / 100
                    change { $0.pan = pan }
                }), name: "Track Pan")
            HStack {
                Toggle("Mute", isOn: Binding(get: { track.mute }, set: { on in
                    editor.updateTrack(on ? "Mute" : "Unmute", track.id) { $0.mute = on }
                }))
                Toggle("Solo", isOn: Binding(get: { track.solo }, set: { on in
                    editor.updateTrack(on ? "Solo" : "Unsolo", track.id) { $0.solo = on }
                }))
                Spacer()
            }
            .toggleStyle(.checkbox)
            HStack {
                Text("Regions").foregroundStyle(Color.tapeSecondary)
                Spacer()
                Text("\(editor.project.regions(onTrack: track.id).count)").monospacedDigit()
            }
        }
        .font(.system(size: 12))
        .onAppear { name = track.name }
        .onChange(of: track.id) { _, _ in name = track.name }
        .onChange(of: track.name) { _, new in if !nameFocused { name = new } }
    }

    private func commitName() {
        guard name != track.name else { return }
        editor.renameTrack(track.id, to: name)
        name = editor.project.track(track.id)?.name ?? name
    }

    /// A drag on the slider is one undo step.
    private func change(_ edit: @escaping (inout Track) -> Void) {
        let id = track.id
        if dragging {
            editor.document.updateGesture { EditOperations.updateTrack(&$0, id: id, edit) }
        } else {
            editor.updateTrack("Track", id, edit)
        }
    }

    private func sliderRow(_ label: String, _ readout: String, value: Binding<Double>, name: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tapeSecondary).frame(width: 36, alignment: .leading)
            Slider(value: value, in: 0...1) { editing in
                if editing {
                    editor.document.beginGesture()
                    dragging = true
                } else {
                    dragging = false
                    editor.document.endGesture(name)
                }
            }
            .controlSize(.small)
            Text(readout).monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}
