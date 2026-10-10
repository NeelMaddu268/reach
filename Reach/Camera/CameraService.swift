import ARKit

/// ARKit world tracking on the back camera. Besides frames, ARKit reports how the phone moves, so an object
/// found once can be pinned to the table (`ObjectAnchor`) and stay put in the image however the phone moves.
final class CameraService: NSObject, ARSessionDelegate {
    enum CameraError: LocalizedError {
        case unsupported
        var errorDescription: String? { "This device can't run ARKit world tracking." }
    }

    let session = ARSession()
    /// Serial queue that delivers frames; per-frame state can be changed safely by dispatching here.
    let frameQueue = DispatchQueue(label: "reach.camera.frames", qos: .userInteractive)
    /// Called on the frame queue for each frame. Don't keep the frame.
    var onFrame: ((ARFrame) -> Void)?
    /// Called on the main queue if the session fails (e.g. camera access denied).
    var onError: ((Error) -> Void)?

    private let configuration = ARWorldTrackingConfiguration()

    override init() {
        super.init()
        configuration.planeDetection = [.horizontal]
        // 4:3 shows more of the table's width than 16:9; 30 fps halves the per-second work.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats.filter {
            $0.framesPerSecond == 30 && $0.imageResolution.width <= 1920
        }
        if let format = formats.first(where: { $0.imageResolution.width * 3 == $0.imageResolution.height * 4 }) ?? formats.first {
            configuration.videoFormat = format
        }
        let resolution = configuration.videoFormat.imageResolution  // landscape
        ImageSpace.aspect = resolution.height / resolution.width
    }

    func start() throws {
        guard ARWorldTrackingConfiguration.isSupported else { throw CameraError.unsupported }
        session.delegate = self
        session.delegateQueue = frameQueue
        session.run(configuration)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.onError?(error) }
    }
}
