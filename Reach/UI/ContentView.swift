import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 10) {
            TopBar(model: model)
            GeometryReader { geo in
                let imageRect = ImageSpace.fitRect(in: geo.size)
                ZStack {
                    CameraPreview(session: model.camera.session)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12)))
                        .position(x: imageRect.midX, y: imageRect.midY)
                        .accessibilityHidden(true)
                    DebugOverlay(model: model, imageRect: imageRect)
                    if let note = model.lastError ?? model.trackingNote ?? model.cameraError {
                        NoticePill(text: note)
                            .position(x: imageRect.midX, y: imageRect.minY + 26)
                    }
                    if model.tuning.minimap, let map = model.minimap {
                        MinimapView(map: map)
                            .position(x: imageRect.maxX - 87, y: imageRect.minY + 87)
                    }
                    if model.tuning.deadAirKiller || model.tuning.judgePolish {
                        VStack {
                            Spacer()
                            CaptionView(heard: model.heardCaption, said: model.caption, big: model.tuning.deadAirKiller)
                        }
                        .padding(10)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                    }
                    TouchSurface(imageRect: imageRect,
                                 onPick: model.seed,
                                 onHoldStart: model.beginListening,
                                 onHoldEnd: { Task { await model.endListening() } })
                    if let banner = model.reachBanner {
                        ReachBanner(text: banner)
                            .position(x: imageRect.midX, y: imageRect.midY)
                    }
                }
            }
            .aspectRatio(ImageSpace.aspect, contentMode: .fit)  // the camera card sits right under the top bar
            Spacer(minLength: 0)
            Text(model.state == .idle && !model.isListening ? "Hold anywhere to talk" : " ")
                .font(Theme.rounded(14, .medium))
                .foregroundStyle(.white.opacity(0.5))
                .accessibilityHidden(true)  // the mic button's hint says the same
            ControlBar(model: model, showSettings: $showSettings)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .animation(.spring(duration: 0.3), value: model.reachBanner)
        .sheet(isPresented: $showSettings) { TuningSheet(model: model) }
        .task { await model.start() }
    }
}

/// "Reach", what it's doing, and (judge view) how long Gemini took. Debug numbers below when "Show stats" is on.
struct TopBar: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Reach")
                    .font(Theme.rounded(26, .heavy))
                    .foregroundStyle(.white)
                StatusPill(model: model)
                Spacer()
                if model.torchOn {
                    Image(systemName: "flashlight.on.fill")
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Flashlight on")
                }
                if model.tuning.judgePolish, let ms = model.geminiMs {
                    LatencyChip(milliseconds: ms)
                }
            }
            if model.tuning.reachTimer, !model.reachTimes.isEmpty {
                let times = model.reachTimes
                Text(String(format: "%d %@ · avg %.1f s · best %.1f s", times.count, times.count == 1 ? "grab" : "grabs",
                            times.reduce(0, +) / Double(times.count), times.min()!))
                    .font(Theme.rounded(13, .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if model.tuning.showStats {
                Text(String(format: "%@ · %d fps · %d ms · key %@", model.fingertip == nil ? "no hand" : "hand",
                            Int(model.fps.rounded()), Int(model.latencyMs), AppConfig.geminiAPIKey.isEmpty ? "✗" : "✓"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.top, 4)
    }
}

struct StatusPill: View {
    let model: AppModel

    var body: some View {
        let (text, color) = status
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
        .font(Theme.rounded(14))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.08), in: Capsule())
        .animation(.easeInOut(duration: 0.2), value: text)
    }

    private var status: (String, Color) {
        if model.cameraError != nil { return ("Camera off", Theme.danger) }
        if model.isListening { return ("Listening", Theme.danger) }
        switch model.state {
        case .idle: return ("Ready", Theme.success)
        case .locating: return ("Looking", Theme.accent)
        case .guiding: return ("Guiding", Theme.accent)
        case .lost: return ("Re-finding", Theme.warning)
        case .locked: return ("Got it", Theme.success)
        }
    }
}

/// Stop, the big mic, settings.
struct ControlBar: View {
    let model: AppModel
    @Binding var showSettings: Bool

    var body: some View {
        HStack {
            CircleButton(systemImage: "stop.fill", tint: Theme.danger, enabled: model.state != .idle) { model.stop() }
                .accessibilityLabel("Stop")
            Spacer()
            MicButton(model: model)
            Spacer()
            CircleButton(systemImage: "slider.horizontal.3", tint: .white) { showSettings = true }
                .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
    }
}

struct CircleButton: View {
    let systemImage: String
    let tint: Color
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(.white.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12)))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// Big push-to-talk button: listens while held, with a pulsing ring.
struct MicButton: View {
    let model: AppModel

    var body: some View {
        ZStack {
            if model.isListening {
                Circle()
                    .stroke(Theme.danger, lineWidth: 3)
                    .frame(width: 96, height: 96)
                    .phaseAnimator([false, true]) { ring, expanded in
                        ring.scaleEffect(expanded ? 1.25 : 1).opacity(expanded ? 0 : 0.8)
                    } animation: { _ in .easeOut(duration: 0.9) }
            }
            Circle()
                .fill(model.isListening ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.mic))
                .frame(width: 88, height: 88)
                .shadow(color: (model.isListening ? Theme.danger : Color(red: 0.5, green: 0.4, blue: 1)).opacity(0.5), radius: 16)
            Image(systemName: model.isListening ? "waveform" : "mic.fill")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 112, height: 112)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 200, pressing: { pressing in
            if pressing {
                Haptics.tap()
                model.beginListening()
            } else {
                Task { await model.endListening() }
            }
        }, perform: {})
        .accessibilityElement()
        .accessibilityLabel("Hold to talk")
        .accessibilityHint("Then say find and an object, what's on the table, or what's this.")
        .accessibilityAddTraits(.isButton)
    }
}

/// "Reached in 4.8 s", for a few seconds after each grab.
struct ReachBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(Theme.rounded(28, .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Theme.success.opacity(0.92), in: Capsule())
            .shadow(color: Theme.success.opacity(0.5), radius: 20)
            .allowsHitTesting(false)
            .accessibilityHidden(true)  // "Got them" is spoken
            .transition(.scale.combined(with: .opacity))
    }
}

/// A short warning at the top of the camera view ("starting: move the phone a little").
struct NoticePill: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.rounded(13))
            .lineLimit(3)
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.warning, in: Capsule())
            .allowsHitTesting(false)
    }
}

/// The whole screen: hold anywhere to talk, tap an object to target it, or drag to draw a box around it.
struct TouchSurface: View {
    let imageRect: CGRect
    let onPick: (CGRect) -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void

    /// Tap box width as a fraction of the frame width (square in pixels).
    static let tapBoxWidth: CGFloat = 0.15
    static let holdDelay: TimeInterval = 0.35

    @State private var pressed = false
    @State private var pressID = 0
    @State private var moved = false
    @State private var holding = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !pressed {
                        pressed = true
                        pressID += 1
                        let id = pressID
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay) {
                            guard pressed, pressID == id, !moved else { return }
                            holding = true
                            Haptics.tap()
                            onHoldStart()
                        }
                    }
                    if hypot(drag.translation.width, drag.translation.height) > 20 { moved = true }
                }
                .onEnded { drag in
                    defer {
                        pressed = false
                        moved = false
                        holding = false
                    }
                    if holding {
                        onHoldEnd()
                    } else {
                        pick(drag)
                    }
                })
            .accessibilityHidden(true)
    }

    private func pick(_ drag: DragGesture.Value) {
        let start = normalized(drag.startLocation), end = normalized(drag.location)
        var box: CGRect
        if !moved {
            let width = Self.tapBoxWidth, height = Self.tapBoxWidth * ImageSpace.aspect
            box = CGRect(x: end.x - width / 2, y: end.y - height / 2, width: width, height: height)
        } else {
            box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
        box = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0.02, box.height > 0.01 else { return }
        onPick(box)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - imageRect.minX) / imageRect.width, y: (point.y - imageRect.minY) / imageRect.height)
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
