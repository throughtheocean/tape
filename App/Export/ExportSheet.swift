import HardwarePresets
import SwiftUI
import TapeCore

/// Format, scope, naming and hardware preset for an export, with progress and cancel.
struct ExportSheet: View {
    @ObservedObject var session: ExportSession
    let export: () -> Void
    let close: () -> Void
    @State private var showPresets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.onlyRegion == nil ? "Export" : "Export Region").font(.headline)
            presetRow
            Group {
                row("Format") {
                    Picker("", selection: containerBinding) {
                        ForEach(AudioContainer.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                if session.settings.container == .aac {
                    row("Bit rate") {
                        Picker("", selection: $session.settings.bitRate) {
                            ForEach(ExportSettings.aacBitRates, id: \.self) { Text("\($0 / 1000) kbit per second").tag($0) }
                        }
                        .labelsHidden()
                    }
                } else {
                    row("Bit depth") {
                        Picker("", selection: $session.settings.sampleFormat) {
                            ForEach(session.settings.container.sampleFormats, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                row("Sample rate") {
                    Picker("", selection: $session.settings.sampleRate) {
                        ForEach(ExportSettings.rates, id: \.self) { rate in
                            Text(String(format: "%g kHz", rate / 1000) + (rate == session.editor.sessionRate ? " (session)" : "")).tag(rate)
                        }
                    }
                    .labelsHidden()
                }
                row("Channels") {
                    Picker("", selection: $session.settings.layout) {
                        ForEach(ChannelLayout.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            .disabled(session.isLocked || session.isExporting)
            row("") {
                Toggle("TPDF dither when writing 16 bit", isOn: $session.settings.dither)
                    .toggleStyle(.checkbox)
                    .disabled(session.settings.sampleFormat != .int16 || session.settings.container == .aac || session.isExporting)
            }
            Divider()
            row("Scope") {
                Picker("", selection: $session.scope) {
                    ForEach(session.availableScopes) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .disabled(session.onlyRegion != nil || session.isExporting)
            }
            if session.scope == .eachRegion {
                row("File names") {
                    TextField("", text: $session.pattern)
                        .disabled(session.isPatternLocked || session.isExporting)
                        .help("Tokens: {name} document, {region} region name, {index} or {index:02} position, {date} as YYMMDD")
                }
            }
            Text(session.summary)
                .font(.system(size: 11))
                .foregroundStyle(Color.tapeSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let problem = session.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if session.isExporting {
                ProgressView(value: session.progress)
            }
            HStack {
                Text(session.status).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.tapeSecondary)
                Spacer()
                Button("Cancel") {
                    if session.isExporting { session.cancel() } else { close() }
                }
                .keyboardShortcut(.cancelAction)
                Button(session.scope.writesFolder ? "Export to Folder..." : "Export...") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.problem != nil || session.isExporting)
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(width: 460)
    }

    private var containerBinding: Binding<AudioContainer> {
        Binding(get: { session.settings.container }, set: { container in
            var s = session.settings
            s = ExportSettings(container: container, sampleFormat: s.sampleFormat, sampleRate: s.sampleRate, layout: s.layout,
                               bitRate: s.bitRate, dither: s.dither)
            session.settings = s
        })
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Preset") {
                Button {
                    showPresets.toggle()
                } label: {
                    HStack {
                        Text(session.preset?.name ?? "None")
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                }
                .disabled(session.isExporting)
                .popover(isPresented: $showPresets, arrowEdge: .bottom) { presetList }
            }
            if let preset = session.preset {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10)).padding(.top, 2)
                    Text(preset.reason + " Format, rate, bit depth and channels are locked; choose None to change them.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.tapeSecondary)
            }
        }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            presetButton(nil)
            ForEach(ExportPreset.Category.allCases, id: \.self) { category in
                let presets = ExportPreset.builtIn.filter { $0.category == category }
                if !presets.isEmpty {
                    Text(category.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.tapeSecondary)
                        .padding(.top, 8)
                    ForEach(presets) { presetButton($0) }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func presetButton(_ preset: ExportPreset?) -> some View {
        Button {
            session.applyPreset(preset)
            showPresets = false
        } label: {
            HStack {
                Image(systemName: "checkmark")
                    .opacity(session.preset?.id == preset?.id ? 1 : 0)
                    .frame(width: 12)
                Text(preset?.name ?? "None")
                Spacer()
                if let f = preset?.format {
                    Text(String(format: "%g kHz, %@, %@", f.sampleRate / 1000, f.bitDepth.rawValue, f.channels.rawValue.lowercased()))
                        .foregroundStyle(Color.tapeSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.vertical, 2)
    }

    private func row(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tapeSecondary).frame(width: 90, alignment: .leading)
            content()
        }
    }
}
