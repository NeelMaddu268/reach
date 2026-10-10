import AVFoundation

/// Back wide camera at 1280×720, 30 fps. Frames arrive as portrait (720×1280) BGRA pixel buffers
/// on a serial queue, so the top of the image is the top of the phone (away from the body on a chest mount).
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CameraError: LocalizedError {
        case denied, unavailable
        var errorDescription: String? {
            self == .denied ? "Camera access is off. Turn it on in Settings › Reach." : "No camera available."
        }
    }

    let session = AVCaptureSession()
    /// Called on the frame queue with each frame and its capture time (host clock, seconds).
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?

    private let sessionQueue = DispatchQueue(label: "reach.camera.session")
    private let frameQueue = DispatchQueue(label: "reach.camera.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.denied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configure()
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)

        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .hd1280x720
            guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraError.unavailable }
            session.addInput(input)

            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            session.addOutput(output)
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90  // portrait buffers
            }
        }

        // The frame rate resets when the preset or input changes, so set it after committing.
        let supports30 = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        if supports30 {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Capture timestamps are on the host clock, same as CACurrentMediaTime().
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
}
