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
                let selected = document.project.regions.filter { editor.selection.contains($0.id) }
                if selected.isEmpty, editor.multitrack, editor.headerFocused {
                    TrackInspector(editor: editor, track: editor.selectedTrack)
                } else if selected.isEmpty {
                    documentSections
                } else {
                    RegionInspector(editor: editor, regions: selected, format: format)
                    if let range = editor.range { rangeSection(range) }
                }
                EditSettings()
                section("Shortcuts") {
                    if selected.isEmpty { generalShortcuts } else { regionShortcuts }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.tapeChrome)
    }

    @ViewBuilder private var regionShortcuts: some View {
        shortcut("Command B", "Split at playhead or range edges")
        shortcut("Drag name", "Move region")
        shortcut("Drag wave", "Mark audio")
        shortcut("Delete", "Cut out marked audio, else delete; ripple left")
        shortcut("Fwd Delete", "The same, leave gap")
        shortcut("Command D", "Duplicate after selection")
        shortcut("F", "Default fades")
        shortcut("Opt Cmd F", "Fade dialog")
        shortcut(",  .", "Nudge left, right")
        shortcut("Command click", "Add or remove from selection")
        shortcut("Shift drag", "Fade handle: all selected")
        shortcut("Option drag", "Fade midpoint: shape")
        shortcut("Command drag", "No zero crossing snap")
        shortcut("Command Z", "Undo")
    }

    @ViewBuilder private var generalShortcuts: some View {
        shortcut("Space", "Play / Pause")
        shortcut("J  K  L", "Shuttle back, stop, forward")
        shortcut("I  O", "Range in, out")
        shortcut("Shift drag", "Mark a range")
        shortcut("Option X", "Clear range")
        shortcut("Command L", "Loop playback")
        shortcut("Command A", "Select all regions")
        shortcut("B  A", "Blade tool, select tool")
        shortcut("Shift Z", "Fit all")
        shortcut("Option scroll", "Zoom horizontally")
        shortcut("Option Shift scroll", "Waveform height")
        shortcut("N", "Snap to zero crossing")
        shortcut("Home  End", "Start, end")
        shortcut("Command I", "Import audio")
        shortcut("Shift Cmd M", "Single or multitrack view")
        shortcut("Command T", "Add track")
        shortcut("R", "Record, R or Space stops")
    }

    private func rangeSection(_ range: SampleRange) -> some View {
        section("Range") {
            row("In", format.string(range.start))
            row("Out", format.string(range.end))
            row("Length", format.string(range.length))
        }
    }

    @ViewBuilder private var documentSections: some View {
                section("Document") {
                    row("Name", document.displayName)
                    row("Session rate", document.project.sessionRate.map { String(format: "%g Hz", $0) } ?? "None")
                    row("Channels", "\(document.project.mixChannelCount)")
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
                RecordSummary()
                if let range = editor.range { rangeSection(range) }
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

    func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
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

    func shortcut(_ key: String, _ action: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 11, weight: .medium).monospacedDigit()).frame(width: 82, alignment: .leading)
            Text(action).font(.system(size: 11)).foregroundStyle(Color.tapeSecondary)
        }
    }
}

/// Record settings summary for the inspector when nothing is selected.
struct RecordSummary: View {
    @ObservedObject var recorder = RecordController.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECORD")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tapeSecondary)
            row("Input", recorder.device?.name ?? "None")
            row("Channels", recorder.channels.count == 2 ? "\(InputDevice.label(recorder.channels)) stereo" : "\(recorder.channels[0] + 1) mono")
            row("Format", "\(settings.recordContainer.displayName) \(settings.recordSampleFormat.displayName)")
            row("Rate", recorder.sampleRate > 0 ? String(format: "%g kHz (device)", recorder.sampleRate / 1000) : "Device rate")
            row("Pre-roll", settings.preRollSeconds == 0 ? "Off" : "\(Int(settings.preRollSeconds)) s")
            Toggle("Place after the region under the playhead", isOn: $settings.recordSnapAfterRegion)
                .font(.system(size: 11))
                .controlSize(.small)
                .help("Otherwise a recording started inside a region goes to the end of the document")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tapeSecondary)
            Spacer()
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
    }
}
