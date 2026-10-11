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
                Section("Ping pitch (Hz)") {
                    TuningSlider(title: "Far", note: "pitch when the hand is far away",
                                 value: $model.tuning.pingLow, range: 200...700)
                    TuningSlider(title: "Near", note: "pitch right at the object",
                                 value: $model.tuning.pingHigh, range: 500...1500)
                }
                Section("Lock") {
                    TuningSlider(title: "Margin", note: "grow (or, negative, shrink) the box by this fraction on each side",
                                 value: $model.tuning.lockMargin, range: -0.4...0.6)
                    TuningSlider(title: "Hold time (s)", note: "fingertip must stay inside this long",
                                 value: $model.tuning.lockDwell, range: 0.1...1)
                }
                Section("Features") {
                    Toggle("Dead-air killer (chirp, big captions, “Still looking”)", isOn: $model.tuning.deadAirKiller)
                    Toggle("Network failure path (never silent)", isOn: $model.tuning.networkFallback)
                    Toggle("Judge view polish", isOn: $model.tuning.judgePolish)
                    Toggle("Siri shortcuts (“Hey Siri, Reach find”)", isOn: $model.tuning.siriShortcuts)
                    Toggle("Ask about held items (Gemini)", isOn: $model.tuning.askAboutItems)
                    Toggle("Money reader", isOn: $model.tuning.moneyReader)
                    Toggle("Medication check", isOn: $model.tuning.medicationCheck)
                    Toggle("Watch mode (“tell me if anything changes”)", isOn: $model.tuning.watchMode)
                    TextField("Allergies, comma-separated", text: $model.tuning.allergies)
                        .textInputAutocapitalization(.never)
                    Toggle("Reach timer", isOn: $model.tuning.reachTimer)
                    Toggle("Minimap", isOn: $model.tuning.minimap)
                    Toggle("Obstacle warning (after a scan)", isOn: $model.tuning.obstacleWarning)
                    Toggle("“Where did I leave…?”", isOn: $model.tuning.whereDidILeave)
                    Toggle("“This is my …” (my objects)", isOn: $model.tuning.myObjects)
                    Toggle("Auto flashlight", isOn: $model.tuning.autoTorch)
                    Toggle("Español (Spanish)", isOn: $model.tuning.spanish)
                }
                Section("Voice") {
                    Toggle("Spoken coaching", isOn: $model.tuning.spokenCues)
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
