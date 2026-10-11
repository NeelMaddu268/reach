import SwiftUI

/// Live sliders for the guidance feel. The camera stays usable above the sheet at half height.
struct TuningSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Fingertip smoothing") {
                    TuningSlider(title: "Steadiness at rest", note: "lower = steadier dot, more lag",
                                 value: $model.tuning.restCutoff, range: 0.3...6)
                    TuningSlider(title: "Follow when moving", note: "higher = less lag on fast moves",
                                 value: $model.tuning.speedResponse, range: 0...40)
                }
                Section("Left / right") {
                    TuningSlider(title: "Full pan at (m)", note: "object this far to the side, in meters",
                                 value: $model.tuning.panRange, range: 0.05...0.4)
                    TuningSlider(title: "Pan curve", note: "< 1 makes small offsets louder on one side",
                                 value: $model.tuning.panCurve, range: 0.3...1.5)
                }
                Section("Sonar pitch (Hz)") {
                    TuningSlider(title: "Far", note: "pitch when the hand is far away",
                                 value: $model.tuning.pitchFar, range: 150...600)
                    TuningSlider(title: "Near", note: "pitch right at the object",
                                 value: $model.tuning.pitchNear, range: 500...2000)
                }
                Section("Lock") {
                    TuningSlider(title: "Margin", note: "grow (or, negative, shrink) the box by this fraction on each side",
                                 value: $model.tuning.lockMargin, range: -0.4...0.6)
                    TuningSlider(title: "Hold time (s)", note: "fingertip must stay inside this long",
                                 value: $model.tuning.lockDwell, range: 0.1...1)
                }
                Section("Features") {
                    Toggle("Ask about held items (Gemini)", isOn: $model.tuning.askAboutItems)
                    TextField("Allergies, comma-separated", text: $model.tuning.allergies)
                        .textInputAutocapitalization(.never)
                }
                Section("Voice") {
                    Toggle("Speak when needed", isOn: $model.tuning.spokenCues)
                }
                Section("Models") {
                    Picker("Find (Gemini)", selection: $model.tuning.geminiModel) {
                        ForEach(Gemini.models, id: \.self) { Text($0) }
                    }
                    Picker("What's this (Claude)", selection: $model.tuning.claudeModel) {
                        ForEach(Reader.models, id: \.self) { Text($0) }
                    }
                }
                Section {
                    Button("Reset to defaults") { model.tuning = Tuning() }
                }
            }
            .navigationTitle("Tuning")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}

private struct TuningSlider: View {
    let title: String
    let note: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
