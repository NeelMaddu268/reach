import CoreVideo
import Observation
import os
import QuartzCore

/// Owns the camera and the per-frame pipeline. Perception and guidance run on the camera's frame queue;
/// published state is only written on the main queue.
@Observable
final class AppModel {
    let camera = CameraService()
    let audio = AudioGuide()
    private let hands = HandTracker()
    private let tracker = ObjectTracker()
    private let guide = Guide()
    @ObservationIgnored private let frameTuning = OSAllocatedUnfairLock(initialState: Tuning())
    @ObservationIgnored private var lastFrameTime: TimeInterval = 0  // frame queue only

    /// Live-adjustable feel, handed to the frame queue on every change.
    var tuning = Tuning() {
        didSet {
            let tuning = tuning
            frameTuning.withLock { $0 = tuning }
        }
    }

    var cameraError: String?
    var state = Guide.State.idle
    /// Index fingertip, normalized image coordinates (origin top-left).
    var fingertip: CGPoint?
    var targetBox: CGRect?
    var lockZone: CGRect?
    var fps = 0.0
    /// Capture → guidance done, for the latest frame.
    var latencyMs = 0.0

    @MainActor
    func start() async {
        audio.start()
        camera.onFrame = { [weak self] buffer, time in self?.process(buffer, time: time) }
        do {
            try await camera.start()
        } catch {
            cameraError = error.localizedDescription
        }
    }

    /// Guide the hand to `box` (normalized, origin top-left).
    func seed(_ box: CGRect) {
        camera.setExposureLocked(true)
        camera.frameQueue.async {
            self.tracker.seed(box)
            self.guide.start()
        }
    }

    func stop() {
        camera.setExposureLocked(false)
        camera.frameQueue.async {
            self.tracker.stop()
            self.guide.stop()
            self.audio.setTone(.silent)
        }
    }

    private func process(_ buffer: CVPixelBuffer, time: TimeInterval) {
        let tuning = frameTuning.withLock { $0 }
        hands.restCutoff = tuning.restCutoff
        hands.speedResponse = tuning.speedResponse

        let tip = hands.process(buffer, time: time)
        let target = tracker.process(buffer, fingertip: tip)
        let output = guide.update(fingertip: tip, target: target, time: time, tuning: tuning)
        audio.setTone(output.tone)
        if output.event == .locked {
            audio.ding()
            tracker.stop()
        }

        let state = guide.state
        let frameInterval = time - lastFrameTime
        lastFrameTime = time
        let latency = (CACurrentMediaTime() - time) * 1000

        DispatchQueue.main.async {
            self.state = state
            self.fingertip = tip
            if state != .locked {  // keep showing the box we locked onto
                self.targetBox = target?.box
                self.lockZone = output.lockZone
            }
            if output.event == .locked {
                self.audio.say("Got it.")
                self.camera.setExposureLocked(false)
            }
            self.latencyMs = latency
            if frameInterval > 0, frameInterval < 1 {
                self.fps = self.fps == 0 ? 1 / frameInterval : self.fps * 0.9 + 0.1 / frameInterval
            }
        }
    }
}
