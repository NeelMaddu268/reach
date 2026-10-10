import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                ZStack {
                    CameraPreview(session: model.camera.session)
                        .accessibilityHidden(true)
                    DebugOverlay(model: model, imageRect: ImageSpace.fitRect(in: geo.size))
                }
            }
            .ignoresSafeArea()

            StatusHUD(model: model)
                .padding(.horizontal)
        }
        .background(Color.black)
        .statusBarHidden()
        .task { await model.start() }
    }
}
