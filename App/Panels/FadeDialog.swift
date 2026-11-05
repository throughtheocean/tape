import SwiftUI
import TapeCore

/// Option Cmd F: fade length and shape per end for the selected regions.
struct FadeDialog: View {
    let sessionRate: Double
    let regionCount: Int
    let done: ((Fade, Fade)?) -> Void

    @State private var inMs: Double
    @State private var inShape: FadeShape
    @State private var inBlend: Double
    @State private var outMs: Double
    @State private var outShape: FadeShape
    @State private var outBlend: Double

    init(sessionRate: Double, fadeIn: Fade, fadeOut: Fade, regionCount: Int, done: @escaping ((Fade, Fade)?) -> Void) {
        self.sessionRate = sessionRate
        self.regionCount = regionCount
        self.done = done
        _inMs = State(initialValue: Double(fadeIn.length) / sessionRate * 1000)
        _inShape = State(initialValue: fadeIn.shape)
        _inBlend = State(initialValue: fadeIn.blend)
        _outMs = State(initialValue: Double(fadeOut.length) / sessionRate * 1000)
        _outShape = State(initialValue: fadeOut.shape)
        _outBlend = State(initialValue: fadeOut.blend)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(regionCount == 1 ? "Fades" : "Fades for \(regionCount) regions").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    Text("Fade in").foregroundStyle(Color.tapeSecondary)
                    Text("Fade out").foregroundStyle(Color.tapeSecondary)
                }
                GridRow {
                    Text("Length (ms)")
                    TextField("", value: $inMs, format: .number.precision(.fractionLength(0...2))).frame(width: 110)
                    TextField("", value: $outMs, format: .number.precision(.fractionLength(0...2))).frame(width: 110)
                }
                GridRow {
                    Text("Shape")
                    shapePicker($inShape)
                    shapePicker($outShape)
                }
                GridRow {
                    Text("Blend to next")
                    blendSlider($inBlend, shape: inShape)
                    blendSlider($outBlend, shape: outShape)
                }
            }
            .font(.system(size: 12))
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    done((fade(inMs, inShape, inBlend), fade(outMs, outShape, outBlend)))
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func shapePicker(_ binding: Binding<FadeShape>) -> some View {
        Picker("", selection: binding) {
            ForEach(FadeShape.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .frame(width: 110)
    }

    private func blendSlider(_ binding: Binding<Double>, shape: FadeShape) -> some View {
        Slider(value: binding, in: 0...1)
            .frame(width: 110)
            .disabled(shape.next == nil)
            .help(shape.next.map { "0 is \(shape.displayName), 1 is \($0.displayName)" } ?? "Exponential is the last shape")
    }

    private func fade(_ ms: Double, _ shape: FadeShape, _ blend: Double) -> Fade {
        Fade(length: Int64((max(ms, 0) / 1000 * sessionRate).rounded()), shape: shape, blend: shape.next == nil ? 0 : blend)
    }
}
