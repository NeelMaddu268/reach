import CoreVideo
import Observation
import QuartzCore

/// Owns the camera and the per-frame pipeline. Perception runs on the camera's frame queue;
/// published state is only written on the main queue.
@Observable
final class AppModel {
    let camera = CameraService()
    private let hands = HandTracker()
    @ObservationIgnored private var lastFrameTime: TimeInterval = 0  // frame queue only

    var cameraError: String?
    /// Index fingertip, normalized image coordinates (origin top-left).
    var fingertip: CGPoint?
    var fps: Double = 0
    /// Capture → perception done, for the latest frame.
    var latencyMs: Double = 0

    @MainActor
    func start() async {
        camera.onFrame = { [weak self] buffer, time in self?.process(buffer, time: time) }
        do {
            try await camera.start()
        } catch {
            cameraError = error.localizedDescription
        }
    }

    private func process(_ buffer: CVPixelBuffer, time: TimeInterval) {
        let tip = hands.process(buffer, time: time)
        let frameInterval = time - lastFrameTime
        lastFrameTime = time
        let latency = (CACurrentMediaTime() - time) * 1000

        DispatchQueue.main.async {
            self.fingertip = tip
            self.latencyMs = latency
            if frameInterval > 0, frameInterval < 1 {
                self.fps = self.fps == 0 ? 1 / frameInterval : self.fps * 0.9 + 0.1 / frameInterval
            }
        }
    }
}
