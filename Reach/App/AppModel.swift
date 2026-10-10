import ARKit
import Observation
import os
import QuartzCore

/// Owns the camera and the per-frame pipeline. Perception and guidance run on the camera's frame queue;
/// published state is only written on the main queue.
@Observable
final class AppModel {
    /// A frame for Gemini, with the camera pose it was taken from (to pin what Gemini finds).
    struct Snapshot {
        var jpeg: Data
        var camera: ARCamera
    }

    let camera = CameraService()
    let audio = AudioGuide()
    @ObservationIgnored private let voice = VoiceInput()
    private let locator = ObjectLocator()
    private let hands = HandTracker()
    private let guide = Guide()
    @ObservationIgnored private let frameTuning = OSAllocatedUnfairLock(initialState: Tuning())
    // Frame queue only:
    @ObservationIgnored private var anchor: ObjectAnchor?
    /// A box waiting for ARKit to find the table under it; guided to as a plain 2D box meanwhile.
    @ObservationIgnored private var pendingBox: CGRect?
    @ObservationIgnored private var snapshotRequests: [(Snapshot?) -> Void] = []
    @ObservationIgnored private var lastProcessed: TimeInterval = 0
    // Main only:
    @ObservationIgnored private var relocating = false

    /// Live-adjustable feel, handed to the frame queue on every change.
    var tuning = Tuning() {
        didSet {
            let tuning = tuning
            frameTuning.withLock { $0 = tuning }
        }
    }

    var cameraError: String?
    /// Why ARKit tracking is degraded, if it is.
    var trackingNote: String?
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
        camera.onFrame = { [weak self] frame in self?.process(frame) }
        camera.onError = { [weak self] error in self?.cameraError = error.localizedDescription }
        do {
            try camera.start()
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
            self.clearTarget()
            self.guide.beginLocating()
        }
        let result: (found: ObjectLocator.Found, camera: ARCamera)?
        do {
            result = try await locate(query)
        } catch {
            print("Locate: \(error.localizedDescription)")
            if targetLabel == query { stop() }
            audio.say("I couldn't reach Gemini.")
            return
        }
        guard targetLabel == query else { return }  // stopped or replaced while we waited
        guard let result else {
            stop()
            audio.say("I don't see \(query).")
            return
        }
        targetLabel = result.found.label
        pin(result.found.box, seenBy: result.camera)
        let box = result.found.box
        let offset = Guide.offset(from: fingertip ?? CGPoint(x: 0.5, y: 1), to: box)
        audio.say("Found \(result.found.label), \(Guide.describe(dx: offset.dx, dy: offset.dy)).")
    }

    /// Guide the hand to a box tapped or drawn on screen (normalized, origin top-left).
    func seed(_ box: CGRect) {
        targetLabel = nil
        pin(box, seenBy: nil)
    }

    func stop() {
        targetLabel = nil
        camera.frameQueue.async {
            self.clearTarget()
            self.guide.stop()
            self.audio.setTone(.silent)
        }
    }

    /// Pins `box` to the table using the pose of the camera that saw it (nil = the next frame's camera).
    private func pin(_ box: CGRect, seenBy seen: ARCamera?) {
        camera.frameQueue.async {
            self.anchor = seen.flatMap { ObjectAnchor(box: box, seenBy: $0, session: self.camera.session) }
            self.pendingBox = self.anchor == nil ? box : nil
            self.guide.start()
        }
    }

    /// Frame queue only.
    private func clearTarget() {
        anchor = nil
        pendingBox = nil
    }

    /// Tracking came back after being lost: ask Gemini again in case the world moved under the pin.
    @MainActor
    private func relocate() async {
        guard let label = targetLabel, !relocating else { return }
        relocating = true
        defer { relocating = false }
        guard let result = try? await locate(label), targetLabel == label, state == .lost || state == .guiding else { return }
        pin(result.found.box, seenBy: result.camera)
    }

    @MainActor
    private func locate(_ query: String) async throws -> (found: ObjectLocator.Found, camera: ARCamera)? {
        guard cameraError == nil, let snapshot = await snapshot() else { return nil }
        let start = CACurrentMediaTime()
        defer { locateMs = (CACurrentMediaTime() - start) * 1000 }
        guard let found = try await locator.locate(query, in: snapshot.jpeg, model: tuning.geminiModel) else { return nil }
        return (found, snapshot.camera)
    }

    /// The next frame as a JPEG, with its camera pose.
    @MainActor
    private func snapshot() async -> Snapshot? {
        await withCheckedContinuation { continuation in
            camera.frameQueue.async {
                self.snapshotRequests.append { continuation.resume(returning: $0) }
            }
        }
    }

    // MARK: Frames

    private func process(_ frame: ARFrame) {
        let time = frame.timestamp
        if !snapshotRequests.isEmpty {
            let snapshot = FrameEncoder.jpeg(frame.capturedImage).map { Snapshot(jpeg: $0, camera: frame.camera) }
            snapshotRequests.forEach { $0(snapshot) }
            snapshotRequests.removeAll()
        }
        guard time - lastProcessed >= 1.0 / 32 else { return }  // at most ~30 Hz, even if ARKit runs at 60
        let frameInterval = time - lastProcessed
        lastProcessed = time

        let tuning = frameTuning.withLock { $0 }
        hands.restCutoff = tuning.restCutoff
        hands.speedResponse = tuning.speedResponse
        let tip = hands.process(frame.capturedImage, time: time)

        if let box = pendingBox, let pinned = ObjectAnchor(box: box, seenBy: frame.camera, session: camera.session) {
            anchor = pinned
            pendingBox = nil
        }
        let trackingNote = Self.note(for: frame.camera.trackingState)
        let box = anchor?.box(in: frame.camera) ?? pendingBox
        let target = box.map { Guide.Target(box: $0, isLost: trackingNote != nil) }
        let output = guide.update(fingertip: tip, target: target, time: time, tuning: tuning)
        audio.setTone(output.tone)
        if output.event == .locked { audio.ding() }

        let state = guide.state
        let latency = (CACurrentMediaTime() - time) * 1000

        DispatchQueue.main.async {
            self.state = state
            self.fingertip = tip
            self.targetBox = target?.box
            self.lockZone = output.lockZone
            self.trackingNote = trackingNote
            if let cue = output.cue { self.audio.cue(cue) }
            switch output.event {
            case .locked: self.audio.say(Self.gotIt(self.targetLabel))
            case .found: Task { await self.relocate() }
            case .lost, nil: break
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

    private static func note(for tracking: ARCamera.TrackingState) -> String? {
        switch tracking {
        case .normal: nil
        case .notAvailable: "tracking unavailable"
        case .limited(.initializing): "starting: move the phone a little"
        case .limited(.excessiveMotion): "moving too fast"
        case .limited(.insufficientFeatures): "not enough detail in view"
        case .limited(.relocalizing): "relocalizing"
        case .limited: "tracking limited"
        }
    }
}
