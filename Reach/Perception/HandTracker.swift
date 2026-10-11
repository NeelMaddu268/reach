import Vision

/// Finds the index finger in each frame. Points are normalized image coordinates, origin top-left.
final class HandTracker {
    struct Finger {
        /// The fingertip (smoothed).
        var tip: CGPoint
        /// A point on the finger just behind the tip: safer than the tip edge for reading depth.
        var pad: CGPoint
    }

    /// Ignore finger joints below this Vision confidence. Low on purpose: clutter behind the finger lowers it.
    var minConfidence: Float = 0.2
    /// Keep reporting the last finger through dropouts shorter than this (seconds).
    var holdTime: TimeInterval = 0.6
    /// Smoothing, see `Tuning`.
    var restCutoff = 2.5
    var speedResponse = 15.0
    /// Careful guidance: a jump to somewhere else in the frame starts a new track instead of gliding there.
    var careful = false
    /// When Vision last saw the hand, and when the current track began (frame time).
    private(set) var lastSeen: TimeInterval = 0
    private(set) var trackedSince: TimeInterval = 0

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()
    private var filterX = OneEuroFilter()
    private var filterY = OneEuroFilter()
    private var finger: Finger?

    /// Returns the finger, or nil when no hand has been seen for `holdTime`.
    func process(_ pixelBuffer: CVPixelBuffer, time: TimeInterval) -> Finger? {
        // ARKit frames are landscape; .right reads them upright, so results come out in portrait image space.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try? handler.perform([request])

        if let hand = request.results?.first, let reading = read(hand) {
            // About 9 cm on the table in one reading: another hand, not this one moving (~0.03 per frame at 60 fps).
            let jumped = careful && finger.map { hypot($0.tip.x - reading.tip.x, $0.tip.y - reading.tip.y) > 0.15 } == true
            if finger == nil || jumped {  // a new hand, or a jump to another one, starts a new track
                filterX.reset()
                filterY.reset()
                trackedSince = time
            }
            filterX.minCutoff = restCutoff
            filterY.minCutoff = restCutoff
            filterX.beta = speedResponse
            filterY.beta = speedResponse
            let tip = CGPoint(x: filterX.filter(reading.tip.x, time: time), y: filterY.filter(reading.tip.y, time: time))
            finger = Finger(tip: tip, pad: reading.pad)
            lastSeen = time
        } else if time - lastSeen > holdTime {
            finger = nil
        }
        return finger
    }

    /// The tip if Vision is confident about it; otherwise extend the finger past the last joint it is sure of.
    private func read(_ hand: VNHumanHandPoseObservation) -> Finger? {
        func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = try? hand.recognizedPoint(joint), p.confidence >= minConfidence else { return nil }
            return CGPoint(x: p.location.x, y: 1 - p.location.y)  // Vision's origin is bottom-left
        }
        let tip = point(.indexTip), dip = point(.indexDIP), pip = point(.indexPIP)
        if let tip {
            let pad = dip.map { CGPoint(x: (tip.x + $0.x) / 2, y: (tip.y + $0.y) / 2) } ?? tip
            return Finger(tip: tip, pad: pad)
        }
        if let dip, let pip {  // the last bone is a bit shorter than the middle one
            return Finger(tip: CGPoint(x: dip.x + (dip.x - pip.x) * 0.8, y: dip.y + (dip.y - pip.y) * 0.8), pad: dip)
        }
        return nil
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
