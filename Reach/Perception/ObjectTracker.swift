import Vision

/// Follows a seeded box across frames with Vision's object tracker. Boxes are normalized, origin top-left.
final class ObjectTracker {
    struct Target {
        var box: CGRect
        var confidence: Float
        var isLost: Bool
    }

    /// Below this Vision confidence the object counts as lost (the last good box is kept).
    var lostBelow: Float = 0.3

    private var handler = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    private var target: Target?

    func seed(_ box: CGRect) {
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box.flippedVertically))
        request.trackingLevel = .accurate
        self.request = request
        handler = VNSequenceRequestHandler()  // fresh tracker state
        target = Target(box: box, confidence: 1, isLost: false)
    }

    func stop() {
        request = nil
        target = nil
    }

    /// Tracks one frame. While the fingertip is near the object the box is held still:
    /// the hand covering the object would otherwise drag the tracker onto the hand.
    func process(_ pixelBuffer: CVPixelBuffer, fingertip: CGPoint?) -> Target? {
        guard let request, var target else { return nil }

        let near = target.box.insetBy(dx: -target.box.width / 2, dy: -target.box.height / 2)
        if let fingertip, near.contains(fingertip) {
            target.isLost = false
        } else {
            do {
                try handler.perform([request], on: pixelBuffer, orientation: .up)
                if let result = request.results?.first as? VNDetectedObjectObservation {
                    request.inputObservation = result
                    target.confidence = result.confidence
                    target.isLost = result.confidence < lostBelow
                    if !target.isLost { target.box = result.boundingBox.flippedVertically }
                }
            } catch {
                target.isLost = true
            }
        }
        self.target = target
        return target
    }
}
