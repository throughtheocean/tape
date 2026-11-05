import SwiftUI
import TapeCore

/// Parameters, Preview and Apply for one process.
struct ProcessSheet: View {
    @ObservedObject var session: ProcessSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.kind.title).font(.headline)
                Text(session.targetSummary).font(.system(size: 11)).foregroundStyle(Color.tapeSecondary)
            }
            parameters
                .font(.system(size: 12))
                .disabled(session.isApplying)
            HStack {
                if session.kind.canPreview {
                    Toggle("Preview", isOn: Binding(get: { session.previewing }, set: { session.setPreview($0) }))
                        .toggleStyle(.checkbox)
                        .disabled(session.isApplying)
                        .help("Plays the processed audio in a loop; parameter changes are heard live")
                }
                Text(session.status).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.tapeSecondary)
                Spacer()
                Button("Cancel") {
                    if session.isApplying {
                        session.cancel()
                    } else {
                        session.cancel()
                        close()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    session.apply { ok in if ok { close() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isApplying)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder private var parameters: some View {
        let p = $session.parameters
        switch session.kind {
        case .normalize:
            Picker("", selection: p.loudnessMode) {
                Text("Loudness (LUFS)").tag(true)
                Text("Peak (dBFS)").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if session.parameters.loudnessMode {
                field("Target (LUFS)", p.lufsTarget, -70...0)
                field("True peak ceiling (dBTP)", p.truePeakCeiling, -20...0)
                Text("Integrated loudness per ITU-R BS.1770-4. The gain stops where the true peak would pass the ceiling.")
                    .font(.system(size: 11)).foregroundStyle(Color.tapeSecondary)
            } else {
                field("Target peak (dBFS)", p.peakTarget, -60...0)
            }
        case .gain:
            field("Gain (dB)", p.gainDB, -60...40)
        case .removeDC:
            Text("Subtracts each channel's average.").foregroundStyle(Color.tapeSecondary)
        case .trimSilence:
            field("Threshold (dBFS)", p.silenceThreshold, -120...0)
            field("Hold (ms)", p.silenceHoldMs, 0...5000)
            Text("Trims the region ends to the audio above the threshold, keeping the hold time.")
                .font(.system(size: 11)).foregroundStyle(Color.tapeSecondary)
        case .reverse:
            Text("Plays the audio backwards.").foregroundStyle(Color.tapeSecondary)
        case .compressor:
            field("Threshold (dB)", p.compThreshold, -40...20)
            field("Headroom (dB)", p.compHeadroom, 0.1...40)
            field("Attack (ms)", p.compAttackMs, 0.1...200)
            field("Release (ms)", p.compReleaseMs, 10...3000)
            field("Master gain (dB)", p.compMasterGain, -40...40)
        case .limiter:
            field("Attack (ms)", p.limAttackMs, 1...30)
            field("Decay (ms)", p.limDecayMs, 1...60)
            field("Pre-gain (dB)", p.limPreGain, -40...40)
        case .resample:
            Picker("Sample rate", selection: p.resampleRate) {
                ForEach([44100.0, 48000, 88200, 96000, 176400, 192000], id: \.self) { Text(String(format: "%g kHz", $0 / 1000)).tag($0) }
            }
            Text("Converts the whole source with AVAudioConverter at the highest quality. The session rate stays as it is.")
                .font(.system(size: 11)).foregroundStyle(Color.tapeSecondary)
        }
    }

    /// Slider plus number field; both clamp to `range`.
    private func field(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        let clamped = Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) })
        return HStack {
            Text(label).foregroundStyle(Color.tapeSecondary).frame(width: 160, alignment: .leading)
            Slider(value: clamped, in: range)
            TextField("", value: clamped, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
        }
    }
}
