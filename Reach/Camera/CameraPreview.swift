import ARKit
import SwiftUI

/// The camera feed. Size this view to `ImageSpace.fitRect(in:)`: ARKit fills its view, so a view with the
/// frame's aspect shows the whole frame, lined up with the overlay.
struct CameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.backgroundColor = .black  // until the first camera frame
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}
}
