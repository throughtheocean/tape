import SwiftUI
import TapeCore

/// Inspector for the selected regions: name, source, position, length, gain and both fades.
/// With several regions selected, gain and fades apply to all of them and show the first region's values.
struct RegionInspector: View {
    @ObservedObject var editor: EditorController
    let regions: [Region]
    let format: TimeFormat

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var first: Region { regions[0] }
    private var ids: Set<UUID> { Set(regions.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(regions.count == 1 ? "Region" : "\(regions.count) Regions")
            if regions.count == 1 {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                row("Source", first.isGap ? "Gap" : editor.project.source(first.sourceId)?.name ?? "Missing")
                row("Position", format.string(first.position))
                row("Length", format.string(first.length))
                if editor.project.track(first.trackId)?.magnetic == false { connection }
            } else {
                let start = regions.map(\.position).min() ?? 0
                let end = regions.map(\.end).max() ?? 0
                row("Span", format.string(end - start))
            }
            field("Gain (dB)", value: Binding(get: { first.gainDB }, set: { editor.setGain($0, ids: ids) }))
        }
        .onAppear { name = first.name }
        .onChange(of: first.id) { _, _ in name = first.name }
        .onChange(of: first.name) { _, new in if !nameFocused { name = new } }
        .onReceive(editor.focusRegionName) { _ in
            name = first.name
            DispatchQueue.main.async { nameFocused = true }
        }

        fadeSection("Fade In", first.fadeIn, .fadeIn)
        fadeSection("Fade Out", first.fadeOut, .fadeOut)
    }

    private var isAnchor: Bool { editor.project.regions.contains { $0.anchor?.regionId == first.id } }

    /// Regions on magnetic tracks this one can connect to, nearest to its start first. None while others connect to it.
    private var anchors: [Region] {
        if isAnchor { return [] }
        let magnetic = Set(editor.project.tracks.filter(\.magnetic).map(\.id))
        func distance(_ r: Region) -> Int64 {
            r.position <= first.position && first.position < r.end ? 0 : min(abs(r.position - first.position), abs(r.end - first.position))
        }
        return editor.project.regions.filter { magnetic.contains($0.trackId) }.sorted { distance($0) < distance($1) }
    }

    private var connection: some View {
        let anchor = first.anchor.flatMap { a in editor.project.regions.first { $0.id == a.regionId } }
        return HStack {
            Text("Connected").foregroundStyle(Color.tapeSecondary)
            Spacer()
            Menu(anchor?.name ?? "Connect to...") {
                ForEach(anchors.prefix(20)) { r in
                    Button("\(editor.project.track(r.trackId)?.name ?? ""): \(r.name) at \(format.string(r.position))") {
                        editor.connect(first.id, to: r.id)
                    }
                }
                if anchor != nil {
                    Divider()
                    Button("Disconnect") { editor.disconnect([first.id]) }
                }
            }
            .frame(width: 150)
            .disabled(anchor == nil && anchors.isEmpty)
            .help(isAnchor ? "Other regions are connected to this one"
                  : anchors.isEmpty ? "Make a track magnetic to connect regions to it" : "Follows the chosen region when it moves")
        }
        .font(.system(size: 12))
    }

    private func commitName() {
        guard regions.count == 1, name != first.name else { return }
        editor.rename(first.id, to: name)
    }

    private func fadeSection(_ title: String, _ fade: Fade, _ end: EditOperations.FadeEnd) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title)
            field("Length (ms)", value: Binding(get: { editor.ms(frames: fade.length) },
                                                set: { editor.setFadeLength(ms: $0, end: end, ids: ids) }))
            HStack {
                Text("Shape").foregroundStyle(Color.tapeSecondary)
                Spacer()
                Picker("", selection: Binding(get: { fade.shape }, set: { shape in
                    editor.setFadeShape(Double(FadeShape.allCases.firstIndex(of: shape) ?? 0), end: end, ids: ids)
                })) {
                    ForEach(FadeShape.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            .font(.system(size: 12))
            if let next = fade.shape.next {
                field("Blend to \(next.displayName) (%)", value: Binding(get: { (fade.blend * 100).rounded() }, set: { value in
                    let index = Double(FadeShape.allCases.firstIndex(of: fade.shape) ?? 0)
                    editor.setFadeShape(index + min(max(value, 0), 99.9) / 100, end: end, ids: ids)
                }))
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.tapeSecondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tapeSecondary)
            Spacer()
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
    }

    private func field(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tapeSecondary)
            Spacer()
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 90)
        }
        .font(.system(size: 12))
    }
}

/// Default fade length (F) and nudge step (, and .).
struct EditSettings: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EDITING")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tapeSecondary)
            HStack {
                Text("Default fade").foregroundStyle(Color.tapeSecondary)
                Spacer()
                Picker("", selection: $settings.defaultFadeMs) {
                    ForEach(AppSettings.defaultFadeChoices, id: \.self) { Text("\(Int($0)) ms").tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
            }
            HStack {
                Text("Nudge").foregroundStyle(Color.tapeSecondary)
                Spacer()
                Picker("", selection: $settings.nudgeMs) {
                    ForEach(AppSettings.nudgeChoices, id: \.self) { Text("\(Int($0)) ms").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
        }
        .font(.system(size: 12))
    }
}
