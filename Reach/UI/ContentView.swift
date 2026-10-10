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
                        .accessibilityHidden(true)
                    DebugOverlay(model: model, imageRect: imageRect)
                    TargetPicker(imageRect: imageRect, onPick: model.seed)
                }
            }
            .ignoresSafeArea()

            VStack {
                StatusHUD(model: model)
                Spacer()
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        model.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button {
                        showTuning = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Tuning")
                }
                .font(.title2.bold())
            }
            .padding(.horizontal)
        }
        .background(Color.black)
        .statusBarHidden()
        .sheet(isPresented: $showTuning) { TuningSheet(model: model) }
        .task { await model.start() }
    }
}

/// Tap an object to target it with a default-size box, or drag to draw a box around it.
struct TargetPicker: View {
    let imageRect: CGRect
    let onPick: (CGRect) -> Void

    /// Tap box width as a fraction of the frame width (square in pixels).
    static let tapBoxWidth: CGFloat = 0.15

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { drag in
                let start = normalized(drag.startLocation), end = normalized(drag.location)
                var box: CGRect
                if hypot(drag.translation.width, drag.translation.height) < 20 {
                    let width = Self.tapBoxWidth, height = Self.tapBoxWidth * ImageSpace.aspect
                    box = CGRect(x: end.x - width / 2, y: end.y - height / 2, width: width, height: height)
                } else {
                    box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                 width: abs(end.x - start.x), height: abs(end.y - start.y))
                }
                box = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !box.isNull, box.width > 0.02, box.height > 0.01 else { return }
                onPick(box)
            })
            .accessibilityHidden(true)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - imageRect.minX) / imageRect.width, y: (point.y - imageRect.minY) / imageRect.height)
    }
}
