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
        // LiDAR depth: how far the fingertip really is from the object, including its height above it.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
    }

    func start() throws {
        guard ARWorldTrackingConfiguration.isSupported else { throw CameraError.unsupported }
        session.delegate = self
        session.delegateQueue = frameQueue
        session.run(configuration)
        sharpenCamera()
    }

    /// Keeps the image sharp for hand tracking: focus stays in near range (no hunting when the hand comes in),
    /// and the shutter time is capped so a moving hand doesn't smear. Costs some grain in dim light.
    private func sharpenCamera() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              (try? device.lockForConfiguration()) != nil else { return }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
        let cap = CMTime(value: 1, timescale: 100)
        let format = device.activeFormat
        if format.minExposureDuration <= cap, cap <= format.maxExposureDuration { device.activeMaxExposureDuration = cap }
        device.unlockForConfiguration()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.onError?(error) }
    }
}
