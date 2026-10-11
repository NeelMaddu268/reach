import SwiftUI

/// Settings: demo features first, then the guidance feel. At half height the camera stays usable above it.
struct TuningSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    feature("Spoken coaching", "figure.walk.motion", $model.tuning.spokenCues)
                    feature("Ask about held items", "text.viewfinder", $model.tuning.askAboutItems)
                    LabeledContent {
                        TextField("peanuts", text: $model.tuning.allergies)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                    } label: {
                        Label("Allergies", systemImage: "exclamationmark.shield")
                    }
                    feature("Money reader", "dollarsign.circle", $model.tuning.moneyReader)
                    feature("Medication check", "pills", $model.tuning.medicationCheck)
                    feature("This is my …", "person.crop.square", $model.tuning.myObjects)
                    feature("Where did I leave …", "clock.arrow.circlepath", $model.tuning.whereDidILeave)
                    feature("Follow moved objects", "arrow.up.and.down.and.arrow.left.and.right", $model.tuning.followMovedObjects)
                    feature("Obstacle warning", "exclamationmark.triangle", $model.tuning.obstacleWarning)
                    feature("Watch mode", "eye", $model.tuning.watchMode)
                    feature("Siri shortcuts", "mic.badge.plus", $model.tuning.siriShortcuts)
                    feature("Español", "globe", $model.tuning.spanish)
                } header: {
                    Text("Features")
                } footer: {
                    Text("Allergies: comma-separated. A label that mentions one is announced with a warning first.")
                }

                Section("Judge view") {
                    feature("Dead-air killer", "bubble.left.and.text.bubble.right", $model.tuning.deadAirKiller)
                    feature("Animated results + Gemini timing", "sparkles", $model.tuning.judgePolish)
                    feature("Reach timer", "stopwatch", $model.tuning.reachTimer)
                    feature("Minimap", "map", $model.tuning.minimap)
                    feature("Never silent offline", "wifi.exclamationmark", $model.tuning.networkFallback)
                    feature("Auto flashlight", "flashlight.on.fill", $model.tuning.autoTorch)
                    feature("Show stats", "gauge.with.dots.needle.33percent", $model.tuning.showStats)
                }

                Section("Guidance feel") {
                    TuningSlider(title: "Steadiness at rest", note: "Lower: steadier fingertip, a bit more lag.",
                                 value: $model.tuning.restCutoff, range: 0.3...6)
                    TuningSlider(title: "Follow when moving", note: "Higher: less lag on fast moves.",
                                 value: $model.tuning.speedResponse, range: 0...40)
                    TuningSlider(title: "Full left/right at (m)", note: "How far to the side the object is for a ping fully in one ear.",
                                 value: $model.tuning.panRange, range: 0.05...0.4)
                    TuningSlider(title: "Pan curve", note: "Below 1 makes small offsets easier to hear.",
                                 value: $model.tuning.panCurve, range: 0.3...1.5)
                    TuningSlider(title: "Ping pitch, far (Hz)", note: nil, value: $model.tuning.pingLow, range: 200...700)
                    TuningSlider(title: "Ping pitch, near (Hz)", note: nil, value: $model.tuning.pingHigh, range: 500...1500)
                    TuningSlider(title: "Lock margin", note: "Grow (or, negative, shrink) the object's outline for locking.",
                                 value: $model.tuning.lockMargin, range: -0.4...0.6)
                    TuningSlider(title: "Hold to lock (s)", note: "How long the finger stays on the object before the chime.",
                                 value: $model.tuning.lockDwell, range: 0.1...1)
                }

                Section("Models") {
                    Picker("Find & read (Gemini)", selection: $model.tuning.geminiModel) {
                        ForEach(Gemini.models, id: \.self) { Text($0) }
                    }
                    Picker("Reader when questions are off (Claude)", selection: $model.tuning.claudeModel) {
                        ForEach(Reader.models, id: \.self) { Text($0) }
                    }
                }

                Section {
                    Button("Reset to defaults", role: .destructive) { model.tuning = Tuning() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .preferredColorScheme(.dark)
    }

    private func feature(_ title: String, _ icon: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: icon)
        }
        .tint(Theme.accent)
    }
}

private struct TuningSlider: View {
    let title: String
    let note: String?
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .tint(Theme.accent)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
