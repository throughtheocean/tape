import AppKit
import SwiftUI
import TapeCore

/// A file name pattern edited as tokens and free text, like Logic's bounce naming. Tokens come from the palette
/// (drag or click); typed text stays text. A typed `{region}` becomes a token when editing ends.
struct NamePatternField: NSViewRepresentable {
    @Binding var pattern: String

    static func label(_ token: String) -> String {
        let inner = token.dropFirst().dropLast()
        let parts = inner.split(separator: ":", maxSplits: 1)
        switch parts.first {
        case "name": return "Project"
        case "region": return "Region"
        case "track": return "Track"
        case "date": return "Date"
        case "index":
            let width = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return width > 1 ? "Number " + String(repeating: "0", count: width - 1) + "1" : "Number"
        default: return token
        }
    }

    static func objects(_ pattern: String) -> [String] {
        Exporter.pieces(of: pattern).map {
            switch $0 {
            case let .text(s): return s
            case let .token(s): return s
            }
        }
    }

    static func join(_ value: Any?) -> String {
        if let array = value as? [Any] { return array.map { "\($0)" }.joined() }
        return value.map { "\($0)" } ?? ""
    }

    static func isToken(_ object: Any) -> Bool {
        guard let s = object as? String else { return false }
        return Exporter.pieces(of: s) == [.token(s)]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        // Only Return or leaving the field ends a piece of text, so commas and spaces can be typed.
        field.tokenizingCharacterSet = CharacterSet(charactersIn: "\u{1F}")
        field.font = .systemFont(ofSize: 12)
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.objectValue = Self.objects(pattern)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = context.environment.isEnabled
        if Self.join(field.objectValue) != pattern { field.objectValue = Self.objects(pattern) }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: NamePatternField

        init(_ parent: NamePatternField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTokenField else { return }
            parent.pattern = NamePatternField.join(field.objectValue)
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTokenField else { return }
            let pattern = NamePatternField.join(field.objectValue)
            field.objectValue = NamePatternField.objects(pattern)
            parent.pattern = pattern
        }

        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject object: Any) -> String? {
            NamePatternField.isToken(object) ? NamePatternField.label("\(object)") : "\(object)"
        }

        func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject object: Any) -> NSTokenField.TokenStyle {
            NamePatternField.isToken(object) ? .rounded : .none
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject object: Any) -> String? { "\(object)" }

        func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? { editingString }

        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            let pieces: [String] = tokens.flatMap { NamePatternField.objects("\($0)") }
            return pieces
        }

        func tokenField(_ tokenField: NSTokenField, readFrom pboard: NSPasteboard) -> [Any]? {
            pboard.string(forType: .string).map { NamePatternField.objects($0) }
        }

        func tokenField(_ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pboard: NSPasteboard) -> Bool {
            pboard.clearContents()
            return pboard.setString(objects.map { "\($0)" }.joined(), forType: .string)
        }

        func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject object: Any) -> Bool { false }
    }
}

/// The tokens a pattern can use, as chips: drag one into the name field, or click to add it at the end.
struct NameTokenPalette: View {
    let tokens: [String]
    @Binding var pattern: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tokens, id: \.self) { token in
                Text(NamePatternField.label(token))
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.3)))
                    .contentShape(Capsule())
                    .onDrag { NSItemProvider(object: token as NSString) }
                    .onTapGesture { pattern += token }
                    .accessibilityAddTraits(.isButton)
                    .help("Drag into the name, or click to add it at the end")
            }
            Spacer(minLength: 0)
        }
    }
}
