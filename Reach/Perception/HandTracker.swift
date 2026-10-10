import Vision

/// Finds the index fingertip in each frame. Points are normalized image coordinates, origin top-left.
final class HandTracker {
    /// Ignore fingertip estimates below this Vision confidence.
    var minConfidence: Float = 0.3
    /// 0 = raw, toward 1 = smoother but laggier (exponential moving average).
    var smoothing: CGFloat = 0.5
    /// Keep reporting the last fingertip through dropouts shorter than this (seconds).
    var holdTime: TimeInterval = 0.25

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()
    private var smoothed: CGPoint?
    private var lastSeen: TimeInterval = 0

    /// Returns the smoothed fingertip, or nil when no hand has been seen for `holdTime`.
    func process(_ pixelBuffer: CVPixelBuffer, time: TimeInterval) -> CGPoint? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])

        if let hand = request.results?.first,
           let tip = try? hand.recognizedPoint(.indexTip),
           tip.confidence >= minConfidence {
            let raw = CGPoint(x: tip.location.x, y: 1 - tip.location.y)  // Vision's origin is bottom-left
            if let previous = smoothed {
                smoothed = CGPoint(x: previous.x + (raw.x - previous.x) * (1 - smoothing),
                                   y: previous.y + (raw.y - previous.y) * (1 - smoothing))
            } else {
                smoothed = raw
            }
            lastSeen = time
        } else if time - lastSeen > holdTime {
            smoothed = nil
        }
        return smoothed
    }
}
