import Vision

/// Finds the index fingertip in each frame. Points are normalized image coordinates, origin top-left.
final class HandTracker {
    /// Ignore fingertip estimates below this Vision confidence.
    var minConfidence: Float = 0.3
    /// Keep reporting the last fingertip through dropouts shorter than this (seconds).
    var holdTime: TimeInterval = 0.25
    /// Smoothing, see `Tuning`.
    var restCutoff = 2.5
    var speedResponse = 15.0

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()
    private var filterX = OneEuroFilter()
    private var filterY = OneEuroFilter()
    private var fingertip: CGPoint?
    private var lastSeen: TimeInterval = 0

    /// Returns the smoothed fingertip, or nil when no hand has been seen for `holdTime`.
    func process(_ pixelBuffer: CVPixelBuffer, time: TimeInterval) -> CGPoint? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])

        if let hand = request.results?.first,
           let tip = try? hand.recognizedPoint(.indexTip),
           tip.confidence >= minConfidence {
            if fingertip == nil {
                filterX.reset()
                filterY.reset()
            }
            filterX.minCutoff = restCutoff
            filterY.minCutoff = restCutoff
            filterX.beta = speedResponse
            filterY.beta = speedResponse
            fingertip = CGPoint(x: filterX.filter(tip.location.x, time: time),
                                y: filterY.filter(1 - tip.location.y, time: time))  // Vision's origin is bottom-left
            lastSeen = time
        } else if time - lastSeen > holdTime {
            fingertip = nil
        }
        return fingertip
    }
}

/// One Euro filter (Casiez et al. 2012): smooths hard when the signal is still, follows closely when it moves fast.
struct OneEuroFilter {
    var minCutoff = 2.5  // Hz
    var beta = 15.0
    var derivativeCutoff = 1.0  // Hz

    private var value: Double?
    private var derivative = 0.0
    private var lastTime: TimeInterval = 0

    mutating func reset() {
        value = nil
        derivative = 0
    }

    mutating func filter(_ x: Double, time: TimeInterval) -> Double {
        guard let previous = value else {
            value = x
            lastTime = time
            return x
        }
        let dt = max(time - lastTime, 0.001)
        derivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * ((x - previous) / dt - derivative)
        let filtered = previous + Self.alpha(cutoff: minCutoff + beta * abs(derivative), dt: dt) * (x - previous)
        value = filtered
        lastTime = time
        return filtered
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
