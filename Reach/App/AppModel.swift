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
    @ObservationIgnored private let voice = VoiceInput()
    private let locator = ObjectLocator()
    private let hands = HandTracker()
    private let tracker = ObjectTracker()
    private let guide = Guide()
    @ObservationIgnored private let frameTuning = OSAllocatedUnfairLock(initialState: Tuning())
    @ObservationIgnored private var lastFrameTime: TimeInterval = 0  // frame queue only
    @ObservationIgnored private var latestFrame: CVPixelBuffer?     // frame queue only
    @ObservationIgnored private var relocating = false

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
    /// What we're guiding to, from "find X" (nil for a tapped target).
    var targetLabel: String?
    var isListening = false
    var lastHeard = ""
    var fps = 0.0
    /// Capture → guidance done, for the latest frame.
    var latencyMs = 0.0
    /// Last Gemini round trip.
    var locateMs: Double?

    @MainActor
    func start() async {
        audio.start()
        camera.onFrame = { [weak self] buffer, time in self?.process(buffer, time: time) }
        do {
            try await camera.start()
        } catch {
            cameraError = error.localizedDescription
        }
        _ = await voice.requestPermissions()  // ask now, not mid-demo
    }

    // MARK: Voice

    @MainActor
    func beginListening() {
        guard !isListening else { return }
        isListening = true
        audio.setMuted(true)
        voice.start()
    }

    @MainActor
    func endListening() async {
        guard isListening else { return }
        let heard = await voice.stop()
        isListening = false
        audio.setMuted(false)
        lastHeard = heard
        switch Command(heard) {
        case .find(let query): await find(query)
        case .whatsThis: audio.say("Reading isn't ready yet.")
        case .stop: stop()
        case nil: audio.say(heard.isEmpty ? "I didn't hear anything." : "Say find, then an object.")
        }
    }

    // MARK: Targets

    /// Find `query` with Gemini, then guide the hand to it.
    @MainActor
    func find(_ query: String) async {
        targetLabel = query
        audio.say("Looking for \(query).")
        camera.frameQueue.async {
            self.tracker.stop()
            self.guide.beginLocating()
        }
        let found: ObjectLocator.Found?
        do {
            found = try await locate(query)
        } catch {
            print("Locate: \(error.localizedDescription)")
            if targetLabel == query { stop() }
            audio.say("I couldn't reach Gemini.")
            return
        }
        guard targetLabel == query else { return }  // stopped or replaced while we waited
        if let found {
            targetLabel = found.label
            seed(found.box)
            audio.say("Found \(found.label).")
        } else {
            stop()
            audio.say("I don't see \(query).")
        }
    }

    /// Guide the hand to `box` (normalized, origin top-left), e.g. tapped on screen or from Gemini.
    func seed(_ box: CGRect) {
        camera.setExposureLocked(true)
        camera.frameQueue.async {
            self.tracker.seed(box)
            self.guide.start()
        }
    }

    func stop() {
        targetLabel = nil
        camera.setExposureLocked(false)
        camera.frameQueue.async {
            self.tracker.stop()
            self.guide.stop()
            self.audio.setTone(.silent)
        }
    }

    /// The tracker lost the object: ask Gemini again and re-seed. Guidance keeps using the last box meanwhile.
    @MainActor
    private func relocate() async {
        guard let label = targetLabel, !relocating else { return }
        relocating = true
        defer { relocating = false }
        guard let found = try? await locate(label), targetLabel == label, state == .lost || state == .guiding else { return }
        seed(found.box)
    }

    @MainActor
    private func locate(_ query: String) async throws -> ObjectLocator.Found? {
        let jpeg = await withCheckedContinuation { continuation in
            camera.frameQueue.async { continuation.resume(returning: self.latestFrame.flatMap { FrameEncoder.jpeg($0) }) }
        }
        guard let jpeg else { return nil }
        let start = CACurrentMediaTime()
        defer { locateMs = (CACurrentMediaTime() - start) * 1000 }
        return try await locator.locate(query, in: jpeg)
    }

    // MARK: Frames

    private func process(_ buffer: CVPixelBuffer, time: TimeInterval) {
        latestFrame = buffer
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
            switch output.event {
            case .locked:
                self.audio.say(Self.gotIt(self.targetLabel))
                self.camera.setExposureLocked(false)
            case .lost:
                Task { await self.relocate() }
            case .found, nil:
                break
            }
            self.latencyMs = latency
            if frameInterval > 0, frameInterval < 1 {
                self.fps = self.fps == 0 ? 1 / frameInterval : self.fps * 0.9 + 0.1 / frameInterval
            }
        }
    }

    /// "Got them." for keys and glasses, "Got it." otherwise.
    private static func gotIt(_ label: String?) -> String {
        guard let label, label.hasSuffix("s"), !label.hasSuffix("ss") else { return "Got it." }
        return "Got them."
    }
}
