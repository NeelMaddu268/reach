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
    private let reader = Reader()
    private let hands = HandTracker()
    private let guide = Guide()
    @ObservationIgnored private let frameTuning = OSAllocatedUnfairLock(initialState: Tuning())
    // Frame queue only:
    @ObservationIgnored private var anchor: ObjectAnchor?
    /// A box waiting for ARKit to find the table under it; guided to as a plain 2D box meanwhile.
    @ObservationIgnored private var pendingBox: CGRect?
    @ObservationIgnored private var snapshotRequests: [(Snapshot?) -> Void] = []
    /// Label to announce ("Found keys. 14 inches ahead…") once the next pin has real distances.
    @ObservationIgnored private var pendingAnnouncement: String?
    @ObservationIgnored private var smoothedAbove: Double?
    /// Focus is locked on the target until guidance ends (see CameraService.lockFocus).
    @ObservationIgnored private var focusLocked = false
    @ObservationIgnored private var lastProcessed: TimeInterval = 0
    // Main only:
    @ObservationIgnored private var relocating = false
    @ObservationIgnored private var reading = false

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
    /// Last Claude round trip ("what's this?").
    var readMs: Double?
    /// The last thing Reach said, shown on screen for the judges.
    var caption: String?

    @MainActor
    func start() async {
        audio.onSpeak = { [weak self] text in self?.caption = text }
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
        case .whatsThis: await read()
        case .stop: stop()
        case nil: audio.say(heard.isEmpty ? "I didn't hear anything." : "Say find, then an object.")
        }
    }

    // MARK: What's this?

    /// Describes what the user is holding up: Vision reads the text, Claude says what it is in one sentence.
    @MainActor
    func read() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        audio.say("Let me see.")
        guard cameraError == nil, let snapshot = await snapshot() else { return }
        let start = CACurrentMediaTime()
        do {
            let answer = try await reader.describe(snapshot.jpeg, model: tuning.claudeModel)
            readMs = (CACurrentMediaTime() - start) * 1000
            audio.say(answer)
        } catch {
            readMs = (CACurrentMediaTime() - start) * 1000
            print("Read: \(error.localizedDescription)")
            audio.say("I couldn't read that.")
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
        pin(result.found.box, seenBy: result.camera, announcing: result.found.label)
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
    private func pin(_ box: CGRect, seenBy seen: ARCamera?, announcing label: String? = nil) {
        camera.frameQueue.async {
            self.anchor = seen.flatMap { ObjectAnchor(box: box, seenBy: $0, session: self.camera.session) }
            self.pendingBox = self.anchor == nil ? box : nil
            self.pendingAnnouncement = label
            self.smoothedAbove = nil
            self.focusLocked = false  // refocus on the new target with the next frame
            self.guide.start()
        }
    }

    /// Frame queue only.
    private func clearTarget() {
        anchor = nil
        pendingBox = nil
        pendingAnnouncement = nil
        if focusLocked {
            camera.lockFocus(at: nil)
            focusLocked = false
        }
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
        guard time - lastProcessed >= 1.0 / 65 else { return }  // every frame at up to 60 fps
        let frameInterval = time - lastProcessed
        lastProcessed = time

        let tuning = frameTuning.withLock { $0 }
        hands.restCutoff = tuning.restCutoff
        hands.speedResponse = tuning.speedResponse
        let finger = hands.process(frame.capturedImage, time: time)

        if let box = pendingBox, let pinned = ObjectAnchor(box: box, seenBy: frame.camera, session: camera.session) {
            anchor = pinned
            pendingBox = nil
        }
        let trackingNote = Self.note(for: frame.camera.trackingState)
        let box = anchor?.box(in: frame.camera) ?? pendingBox
        if let box, !focusLocked, guide.state == .guiding || guide.state == .lost {
            camera.lockFocus(at: FrameGeometry(frame: frame).landscapePoint(CGPoint(x: box.midX, y: box.midY)))
            focusLocked = true
        }
        let input = guideInput(frame: frame, finger: finger, box: box, trackingLost: trackingNote != nil)
        let output = guide.update(input, time: time, tuning: tuning)
        audio.setTone(output.tone)
        if output.event == .locked {
            audio.ding()
            camera.lockFocus(at: nil)
            focusLocked = false
        }
        var announcement: String?
        if let label = pendingAnnouncement, let input {
            announcement = Guide.announcement(label, input)
            pendingAnnouncement = nil
        }

        let state = guide.state
        let zone = box.map { $0.insetBy(dx: -$0.width * tuning.lockMargin, dy: -$0.height * tuning.lockMargin) }
        let latency = (CACurrentMediaTime() - time) * 1000

        DispatchQueue.main.async {
            self.state = state
            self.fingertip = finger?.tip
            self.targetBox = box
            self.lockZone = state == .guiding || state == .lost ? zone : nil
            self.trackingNote = trackingNote
            if let announcement {
                self.audio.say(announcement)
            } else if let cue = output.cue {
                self.audio.cue(cue)
            }
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

    /// The object relative to the fingertip in real distances: LiDAR depth places the fingertip in 3D
    /// (or, without a depth reading, it's assumed at the object's height). With no hand in view, distances
    /// are from the user's body (the bottom middle of the frame). Frame queue only.
    private func guideInput(frame: ARFrame, finger: HandTracker.Finger?, box: CGRect?, trackingLost: Bool) -> Guide.Input? {
        guard var pinned = anchor else { return nil }
        let geometry = FrameGeometry(frame: frame)
        guard let axes = geometry.axes(onPlaneAt: pinned.tableY) else { return nil }

        // Learn the object's height from depth at its center, while the hand is nowhere near it.
        if let box, finger.map({ !box.insetBy(dx: -box.width, dy: -box.height).contains($0.tip) }) ?? true,
           let top = geometry.point(at: CGPoint(x: box.midX, y: box.midY), percentile: 0.3) {
            pinned.topY = max(pinned.tableY, pinned.topY + (top.y - pinned.topY) * 0.2)
            anchor = pinned
        }

        var hand: simd_float3?
        var above: Double?
        if let finger {
            if let point = geometry.point(at: finger.tip, depthAt: finger.pad) {
                hand = point
                let reading = Double(point.y - pinned.topY)
                above = smoothedAbove.map { $0 + (reading - $0) * 0.5 } ?? reading
            } else {
                hand = geometry.point(at: finger.tip, onPlaneAt: pinned.topY)
            }
        }
        smoothedAbove = above
        guard let from = hand ?? geometry.point(at: CGPoint(x: 0.5, y: 1), onPlaneAt: pinned.tableY) else { return nil }

        let toObject = pinned.center - from
        let half = pinned.halfExtents(right: axes.right, forward: axes.forward)
        return Guide.Input(right: Double(simd_dot(toObject, axes.right)), forward: Double(simd_dot(toObject, axes.forward)),
                           above: above, halfRight: half.right, halfForward: half.forward,
                           hasHand: finger != nil, trackingLost: trackingLost)
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
