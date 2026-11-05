import SwiftUI
import TapeCore

/// Right hand inspector. With nothing selected it shows the document summary.
struct InspectorPanel: View {
    @ObservedObject var editor: EditorController
    @ObservedObject var document: TapeDocument
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Document") {
                    row("Name", document.displayName)
                    row("Session rate", document.project.sessionRate.map { String(format: "%g Hz", $0) } ?? "None")
                    row("Channels", "\(document.project.channelCount)")
                    row("Length", format.string(document.project.length))
                    row("Regions", "\(document.project.regions.count)")
                }
                if !document.project.sources.isEmpty {
                    section("Sources") {
                        ForEach(document.project.sources) { source in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).lineLimit(1).truncationMode(.middle)
                                Text(sourceStatus(source))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Color.tapeSecondary)
                            }
                        }
                    }
                }
                if let range = editor.range {
                    section("Range") {
                        row("In", format.string(range.start))
                        row("Out", format.string(range.end))
                        row("Length", format.string(range.length))
                    }
                }
                section("Shortcuts") {
                    shortcut("Space", "Play / Pause")
                    shortcut("J  K  L", "Shuttle back, stop, forward")
                    shortcut("I  O", "Range in, out")
                    shortcut("Option X", "Clear range")
                    shortcut("Command L", "Loop playback")
                    shortcut("Shift Z", "Fit all")
                    shortcut("Home  End", "Start, end")
                    shortcut("Command I", "Import audio")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.tapeChrome)
    }

    private var format: TimeFormat {
        TimeFormat(display: settings.timeDisplay, frameRate: settings.frameRate, sampleRate: document.sessionRate)
    }

    private func sourceStatus(_ source: SourceRef) -> String {
        var parts = [String(format: "%g kHz", source.sampleRate / 1000), "\(source.channelCount) ch"]
        if document.loading.contains(source.id) {
            parts.append("building waveform")
        } else if let failure = document.failures[source.id] {
            parts.append("offline: \(failure)")
        } else if let t = document.peakTimes[source.id] {
            parts.append(String(format: "peaks %.2f s", t))
        }
        return parts.joined(separator: ", ")
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tapeSecondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tapeSecondary)
            Spacer()
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12))
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 11, weight: .medium).monospacedDigit()).frame(width: 82, alignment: .leading)
            Text(action).font(.system(size: 11)).foregroundStyle(Color.tapeSecondary)
        }
    }
}
