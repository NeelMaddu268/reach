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
    @ObservationIgnored private let frameTuning = OSAllocatedUnfairLock(initialState: Tuning.load())
    // Frame queue only:
    @ObservationIgnored private var anchor: ObjectAnchor?
    /// A box waiting for ARKit to find the table under it; guided to as a plain 2D box meanwhile.
    @ObservationIgnored private var pendingBox: CGRect?
    @ObservationIgnored private var snapshotRequests: [(Snapshot?) -> Void] = []
    /// Label to announce ("Found keys, out and to the right.") once the next pin has real positions.
    @ObservationIgnored private var pendingAnnouncement: String?
    @ObservationIgnored private var pendingAnnouncementSince: TimeInterval = 0
    @ObservationIgnored private var smoothedAbove: Double?
    /// Focus is locked on the target until guidance ends (see CameraService.lockFocus).
    @ObservationIgnored private var focusLocked = false
    @ObservationIgnored private var lastProcessed: TimeInterval = 0
    /// Everything the last table scan found, pinned to the table, left to right.
    @ObservationIgnored private var scene: [(label: String, anchor: ObjectAnchor)] = []
    /// Touch-to-explore: the scanned object under the fingertip, and when the finger was last on one.
    @ObservationIgnored private var touching: Int?
    @ObservationIgnored private var lastTouchTime: TimeInterval = 0
    /// When the current guidance started (host clock), for the reach timer.
    @ObservationIgnored private var guidingSince: TimeInterval = 0
    // Main only:
    @ObservationIgnored private var relocating = false
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var scanning = false
    /// The last held item asked about, kept for one follow-up question.
    @ObservationIgnored private var lastItem: Reader.Item?

    /// Live-adjustable feel, handed to the frame queue on every change.
    var tuning = Tuning.load() {
        didSet {
            let tuning = tuning
            frameTuning.withLock { $0 = tuning }
            tuning.save()
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
    /// Scanned objects as seen in the current frame, for the judge view.
    var sceneBoxes: [LabeledBox] = []
    /// The scanned object the fingertip is on.
    var touchedLabel: String?
    /// Seconds from guidance start to lock, for each reach this session.
    var reachTimes: [Double] = []
    /// "Reached in 4.8 s", shown big for a few seconds after a lock.
    var reachBanner: String?
    var minimap: Minimap?

    struct LabeledBox {
        var label: String
        var box: CGRect
    }

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
        audio.say(Self.onboarding)
    }

    static let onboarding = "Hold to talk, then say find and an object."

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
        case .whatsThis:
            if tuning.askAboutItems { await ask(nil) } else { await read() }
        case .ask(let question):
            if tuning.askAboutItems { await ask(question) } else { audio.say("Say find, then an object.") }
        case .scan: await scan()
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

    /// A question about the held item (nil = "what's this?"), answered by Gemini from what's printed on it.
    /// The item is kept for one follow-up ("how many do I take?"); "what's this?" always starts a new one.
    @MainActor
    func ask(_ question: String?) async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        audio.say("Let me see.")
        guard cameraError == nil, let snapshot = await snapshot() else { return }
        let previous = question == nil ? nil : lastItem.flatMap { CACurrentMediaTime() - $0.time < 120 ? $0 : nil }
        lastItem = nil
        let start = CACurrentMediaTime()
        do {
            let result = try await reader.ask(question, jpeg: snapshot.jpeg, previous: previous,
                                              allergies: tuning.allergyList, model: tuning.geminiModel)
            readMs = (CACurrentMediaTime() - start) * 1000
            if previous == nil { lastItem = result.item }
            audio.say(result.spoken)
        } catch {
            readMs = (CACurrentMediaTime() - start) * 1000
            print("Ask: \(error.localizedDescription)")
            audio.say("I couldn't read that.")
        }
    }

    // MARK: What's on the table?

    /// Gemini lists every object on the table; each is pinned in 3D and named left to right. Afterwards,
    /// touching an object names it, and "find" goes straight to a scanned object without asking Gemini again.
    @MainActor
    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        audio.say("Looking at the table.")
        guard cameraError == nil, let snapshot = await snapshot() else { return }
        let start = CACurrentMediaTime()
        let found: [ObjectLocator.Found]
        do {
            found = try await locator.scan(snapshot.jpeg, model: tuning.geminiModel)
            locateMs = (CACurrentMediaTime() - start) * 1000
        } catch {
            locateMs = (CACurrentMediaTime() - start) * 1000
            print("Scan: \(error.localizedDescription)")
            audio.say("I couldn't reach Gemini.")
            return
        }
        let objects = found.sorted { $0.box.midX < $1.box.midX }
        camera.frameQueue.async {
            self.scene = objects.compactMap { object in
                ObjectAnchor(box: object.box, seenBy: snapshot.camera, session: self.camera.session).map { (object.label, $0) }
            }
            self.touching = nil
        }
        audio.say(Self.summary(objects.map(\.label)))
        audio.prefetch(objects.map { Self.touchName($0.label) })  // so touch-to-explore names play instantly
    }

    /// "I see 4 things, left to right: keys, blue mug, phone and pill bottle."
    private static func summary(_ labels: [String]) -> String {
        switch labels.count {
        case 0: return "I don't see anything on the table."
        case 1: return "I see \(labels[0])."
        default: return "I see \(labels.count) things, left to right: \(labels.dropLast().joined(separator: ", ")) and \(labels.last!)."
        }
    }

    /// What's said when the fingertip lands on a scanned object: "Blue mug."
    private static func touchName(_ label: String) -> String {
        label.prefix(1).uppercased() + label.dropFirst() + "."
    }

    /// "keys" finds "car keys", "mug" finds "blue mug", "glasses" finds "reading glasses".
    private static func matches(_ label: String, _ query: String) -> Bool {
        let label = label.lowercased(), query = query.lowercased()
        if label.contains(query) || query.contains(label) { return true }
        let head = { (text: String) -> String in
            let word = String(text.split(separator: " ").last ?? "")
            return word.hasSuffix("s") ? String(word.dropLast()) : word
        }
        return head(label) == head(query)
    }

    @MainActor
    private func scannedObject(matching query: String) async -> (label: String, anchor: ObjectAnchor)? {
        await withCheckedContinuation { continuation in
            camera.frameQueue.async {
                continuation.resume(returning: self.scene.first { Self.matches($0.label, query) })
            }
        }
    }

    // MARK: Targets

    /// Find `query` with Gemini, then guide the hand to it.
    @MainActor
    func find(_ query: String) async {
        targetLabel = query
        if let scanned = await scannedObject(matching: query) {  // already pinned by a scan: no Gemini round trip
            targetLabel = scanned.label
            camera.frameQueue.async { self.startGuiding(to: scanned.anchor, pendingBox: nil, announcing: scanned.label) }
            return
        }
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
            let pinned = seen.flatMap { ObjectAnchor(box: box, seenBy: $0, session: self.camera.session) }
            self.startGuiding(to: pinned, pendingBox: pinned == nil ? box : nil, announcing: label)
        }
    }

    /// Starts guiding to a pinned object (or a box still waiting to be pinned). Frame queue only.
    private func startGuiding(to pinned: ObjectAnchor?, pendingBox: CGRect?, announcing label: String?) {
        anchor = pinned
        self.pendingBox = pendingBox
        pendingAnnouncement = label
        pendingAnnouncementSince = CACurrentMediaTime()  // same clock as frame timestamps
        smoothedAbove = nil
        focusLocked = false  // refocus on the new target with the next frame
        guidingSince = CACurrentMediaTime()
        guide.start()
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
        // Every frame (up to 60 fps) while guiding; 15 fps otherwise, to keep the phone cool through a long demo.
        let guiding = guide.state == .guiding || guide.state == .lost
        guard time - lastProcessed >= (guiding ? 1.0 / 65 : 1.0 / 15) else { return }
        let frameInterval = time - lastProcessed
        lastProcessed = time

        let tuning = frameTuning.withLock { $0 }
        hands.restCutoff = tuning.restCutoff
        hands.speedResponse = tuning.speedResponse
        let finger = hands.process(frame.capturedImage, time: time)
        let geometry = FrameGeometry(frame: frame)
        let fingerPoint = finger.flatMap { geometry.point(at: $0.tip, depthAt: $0.pad) }  // LiDAR, when it has a reading

        if let box = pendingBox, let pinned = ObjectAnchor(box: box, seenBy: frame.camera, session: camera.session) {
            anchor = pinned
            pendingBox = nil
        }
        let trackingNote = Self.note(for: frame.camera.trackingState)
        let box = anchor?.box(in: frame.camera) ?? pendingBox
        if let box, !focusLocked, guide.state == .guiding || guide.state == .lost {
            camera.lockFocus(at: geometry.landscapePoint(CGPoint(x: box.midX, y: box.midY)))
            focusLocked = true
        }
        let input = guideInput(geometry: geometry, finger: finger, fingerPoint: fingerPoint, box: box,
                               trackingLost: trackingNote != nil)
        let output = guide.update(input, time: time, tuning: tuning)
        audio.setTone(output.tone)
        if output.event == .locked {
            audio.ding()
            camera.lockFocus(at: nil)
            focusLocked = false
        }
        var announcement: String?
        if let label = pendingAnnouncement {
            if let input {
                announcement = Guide.announcement(label, input)
                pendingAnnouncement = nil
            } else if time - pendingAnnouncementSince > 1.5 {  // ARKit hasn't pinned it yet: don't stay silent
                announcement = "Found \(label)."
                pendingAnnouncement = nil
            }
        }

        // Touch-to-explore, when not guiding somewhere.
        var touchedName: String?
        if !scene.isEmpty, guide.state == .idle || guide.state == .locked, let finger {
            touchedName = touchedObject(finger, at: fingerPoint, geometry: geometry, time: time)
        } else {
            touching = nil
        }
        let sceneBoxes = scene.compactMap { object in object.anchor.box(in: frame.camera).map { LabeledBox(label: object.label, box: $0) } }
        let touchedLabel = touching.map { scene[$0].label }

        let reachTime = output.event == .locked ? time - guidingSince : nil
        let minimap = tuning.minimap ? makeMinimap(geometry: geometry, finger: finger, fingerPoint: fingerPoint, tone: output.tone) : nil

        let state = guide.state
        let zone = box.map { $0.insetBy(dx: -$0.width * tuning.lockMargin, dy: -$0.height * tuning.lockMargin) }
        let latency = (CACurrentMediaTime() - time) * 1000

        DispatchQueue.main.async {
            self.state = state
            self.fingertip = finger?.tip
            self.targetBox = box
            self.lockZone = state == .guiding || state == .lost ? zone : nil
            self.trackingNote = trackingNote
            self.sceneBoxes = sceneBoxes
            self.minimap = minimap
            self.touchedLabel = touchedLabel
            if let touchedName, !self.isListening {
                self.audio.say(touchedName)
            }
            if let announcement {
                self.audio.say(announcement)
            } else if let cue = output.cue, !self.isListening {  // don't talk over the user
                self.audio.cue(cue)
            }
            switch output.event {
            case .locked:
                self.audio.say(Self.gotIt(self.targetLabel))
                if let reachTime { self.recordReach(reachTime) }
            case .found: Task { await self.relocate() }
            case .lost, nil: break
            }
            self.latencyMs = latency
            if frameInterval > 0, frameInterval < 1 {
                self.fps = self.fps == 0 ? 1 / frameInterval : self.fps * 0.9 + 0.1 / frameInterval
            }
        }
    }

    /// Pinned objects and the hand, top-down in meters from the user's body. Frame queue only.
    private func makeMinimap(geometry: FrameGeometry, finger: HandTracker.Finger?, fingerPoint: simd_float3?,
                         tone: AudioGuide.Tone) -> Minimap? {
        guard let tableY = anchor?.tableY ?? scene.first?.anchor.tableY,
              let axes = geometry.axes(onPlaneAt: tableY),
              let body = geometry.point(at: CGPoint(x: 0.5, y: 1), onPlaneAt: tableY) else { return nil }
        func place(_ p: simd_float3) -> CGPoint {
            CGPoint(x: CGFloat(simd_dot(p - body, axes.right)), y: CGFloat(simd_dot(p - body, axes.forward)))
        }
        var marks = scene.map { Minimap.Mark(label: $0.label, at: place($0.anchor.center), isTarget: false) }
        if let anchor, guide.state != .idle {
            marks.append(Minimap.Mark(label: "", at: place(anchor.center), isTarget: true))
        }
        let hand = fingerPoint ?? finger.flatMap { geometry.point(at: $0.tip, onPlaneAt: tableY) }
        return Minimap(marks: marks, hand: hand.map(place), tone: tone)
    }

    @MainActor
    private func recordReach(_ seconds: Double) {
        guard tuning.reachTimer else { return }
        reachTimes.append(seconds)
        let banner = String(format: "Reached in %.1f s", seconds)
        reachBanner = banner
        Task {
            try? await Task.sleep(for: .seconds(4))
            if reachBanner == banner { reachBanner = nil }
        }
    }

    /// The object relative to the fingertip in real distances: LiDAR depth places the fingertip in 3D
    /// (or, without a depth reading, it's assumed at the object's height). With no hand in view, distances
    /// are from the user's body (the bottom middle of the frame). Frame queue only.
    private func guideInput(geometry: FrameGeometry, finger: HandTracker.Finger?, fingerPoint: simd_float3?,
                            box: CGRect?, trackingLost: Bool) -> Guide.Input? {
        guard var pinned = anchor else { return nil }
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
            if let point = fingerPoint {
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

    /// The name of the scanned object the fingertip just landed on, once per arrival. With LiDAR, "on" means
    /// within the object's footprint and touching its top; without, inside its box on screen. Frame queue only.
    private func touchedObject(_ finger: HandTracker.Finger, at point: simd_float3?, geometry: FrameGeometry,
                               time: TimeInterval) -> String? {
        var hit: Int?
        if let point, let axes = geometry.axes(onPlaneAt: scene[0].anchor.tableY) {
            var nearest = Float.infinity
            for (index, object) in scene.enumerated() {
                let offset = object.anchor.center - point
                let half = object.anchor.halfExtents(right: axes.right, forward: axes.forward)
                let on = abs(Double(simd_dot(offset, axes.right))) <= half.right + 0.01
                    && abs(Double(simd_dot(offset, axes.forward))) <= half.forward + 0.01
                    && point.y - object.anchor.topY < 0.05
                let distance = simd_length(simd_float2(offset.x, offset.z))
                if on, distance < nearest {
                    hit = index
                    nearest = distance
                }
            }
        } else {
            hit = scene.indices.first { scene[$0].anchor.box(in: geometry.camera)?.contains(finger.tip) == true }
        }
        if let hit {
            lastTouchTime = time
            guard hit != touching else { return nil }
            touching = hit
            return Self.touchName(scene[hit].label)
        }
        if time - lastTouchTime > 0.4 { touching = nil }  // brief dropouts don't re-announce
        return nil
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
