import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var showTuning = false

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                let imageRect = ImageSpace.fitRect(in: geo.size)
                ZStack {
                    CameraPreview(session: model.camera.session)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                        .accessibilityHidden(true)
                    DebugOverlay(model: model, imageRect: imageRect)
                    TouchSurface(imageRect: imageRect,
                                 onPick: model.seed,
                                 onHoldStart: model.beginListening,
                                 onHoldEnd: { Task { await model.endListening() } })
                }
            }
            .ignoresSafeArea()

            VStack {
                StatusHUD(model: model)
                Spacer()
                if model.state == .idle && !model.isListening {
                    Text("Hold anywhere to talk: “what’s on the table?”, “find my keys”, “what’s this?”")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)  // the talk button's hint says the same
                }
                TalkButton(model: model)
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        model.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button {
                        showTuning = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Tuning")
                }
                .font(.headline)
            }
            .padding(.horizontal)
        }
        .background(Color.black)
        .statusBarHidden()
        .sheet(isPresented: $showTuning) { TuningSheet(model: model) }
        .task { await model.start() }
    }
}

/// Big push-to-talk button: listens while held.
struct TalkButton: View {
    let model: AppModel

    var body: some View {
        Label(model.isListening ? "Listening…" : "Hold to talk", systemImage: "mic.fill")
            .font(.title2.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(model.isListening ? Color.red : Color.blue, in: RoundedRectangle(cornerRadius: 16))
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
            .accessibilityHint("Then say find and an object, or what's this.")
            .accessibilityAddTraits(.isButton)
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
