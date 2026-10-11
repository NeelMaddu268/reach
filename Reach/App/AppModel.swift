import ARKit
import Observation
import os
import QuartzCore

/// Owns the camera and the per-frame pipeline. Perception and guidance run on the camera's frame queue;
/// published state is only written on the main queue.
@Observable
final class AppModel {
    /// A frame for Gemini, with its camera pose and LiDAR depth (to pin what Gemini finds).
    struct Snapshot {
        var jpeg: Data
        var geometry: FrameGeometry
    }

    let camera = CameraService()
    let audio = AudioGuide()
    @ObservationIgnored private let voice = VoiceInput()
    private let locator = ObjectLocator()
    private let reader = Reader()
    private let moneyReader = MoneyReader()
    private let medicationCheck = MedicationCheck()
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
    /// How far LiDAR puts the finger in front of the object along the line of sight (smoothed), and whether that
    /// counts as hovering (with hysteresis).
    @ObservationIgnored private var smoothedGap: Double?
    @ObservationIgnored private var hovering = false
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
    /// One obstacle warning per reach.
    @ObservationIgnored private var obstacleWarned = false
    /// Every object pinned so far (by a scan or a find), by lowercased label, with when it was seen.
    @ObservationIgnored private var sightings: [String: (label: String, anchor: ObjectAnchor, time: TimeInterval)] = [:]
    /// The latest frame's camera, to say which side a remembered object is on.
    @ObservationIgnored private var lastCamera: ARCamera?
    @ObservationIgnored private var torch = AutoTorch()
    // Main only:
    @ObservationIgnored private var relocating = false
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var scanning = false
    /// The last held item asked about, kept for one follow-up question.
    @ObservationIgnored private var lastItem: Reader.Item?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var watchFailures = 0
    // Watch mode, frame queue only: looks a new object needs before it counts, and misses per scene pin.
    @ObservationIgnored private var watchCandidates: [(label: String, anchor: ObjectAnchor)] = []
    @ObservationIgnored private var watchMisses: [Int] = []

    /// Live-adjustable feel, handed to the frame queue on every change.
    var tuning = Tuning.load() {
        didSet {
            let tuning = tuning
            frameTuning.withLock { $0 = tuning }
            tuning.save()
            if voice.spanish != tuning.spanish { voice.spanish = tuning.spanish }
            audio.spanish = tuning.spanish
            audio.networkFallback = tuning.networkFallback
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
    /// What the user just said, shown big for a few seconds (dead-air killer).
    var heardCaption: String?
    /// Bills from the last money read, labeled ("$20", "?") on screen for a few seconds.
    var moneyBoxes: [LabeledBox] = []
    /// When scan / money boxes and the find target last arrived, so the judge view can animate them in.
    var boxesShownAt = Date.distantPast
    var targetShownAt = Date.distantPast
    /// How long the last Gemini call took, for the judge view's chip.
    var geminiMs: Double?
    /// The last Gemini error, shown on the camera card for a few seconds.
    var lastError: String?
    /// Scanned objects as seen in the current frame, for the judge view.
    var sceneBoxes: [LabeledBox] = []
    /// The scanned object the fingertip is on.
    var touchedLabel: String?
    /// Seconds from guidance start to lock, for each reach this session.
    var reachTimes: [Double] = []
    /// "Reached in 4.8 s", shown big for a few seconds after a lock.
    var reachBanner: String?
    var minimap: Minimap?
    var torchOn = false

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
        voice.spanish = tuning.spanish
        audio.spanish = tuning.spanish
        audio.networkFallback = tuning.networkFallback
        _ = await voice.requestPermissions()  // ask now, not mid-demo
        if SiriRequests.shared.pending == nil || !tuning.siriShortcuts {  // opened by Siri: get straight to it
            audio.say(t(Self.onboarding, "Mantén presionado para hablar, y di encuentra y un objeto."))
        }
        SiriRequests.shared.handler = { [weak self] request in
            Task { await self?.handleSiri(request) }
        }
    }

    /// A find or scan started from Siri.
    @MainActor
    private func handleSiri(_ request: SiriRequests.Request) async {
        guard tuning.siriShortcuts else { return }
        switch request {
        case .find(let object):
            // "my keys" → "keys", the same way a spoken "find my keys" is read.
            let phrase = (tuning.spanish ? "encuentra " : "find ") + object
            if case .find(let item) = Command(phrase, spanish: tuning.spanish) { await find(item) }
        case .scan:
            await scan()
        }
    }

    static let onboarding = "Hold to talk, then say find and an object."

    /// Voice commands of the features that are switched on.
    private var commandExtras: Command.Extras {
        var extras: Command.Extras = []
        if tuning.moneyReader { extras.insert(.money) }
        if tuning.medicationCheck { extras.insert(.medicationCheck) }
        if tuning.watchMode { extras.insert(.watch) }
        return extras
    }

    @MainActor
    private func showHeard(_ text: String) {
        heardCaption = text
        Task {
            try? await Task.sleep(for: .seconds(6))
            if heardCaption == text { heardCaption = nil }
        }
    }

    /// Runs a Gemini wait; if it takes more than 2.5 s, says "Still looking." once (dead-air killer).
    @MainActor
    private func stillLooking<T>(_ work: () async throws -> T) async rethrows -> T {
        guard tuning.deadAirKiller else { return try await work() }
        let line = t("Still looking.", "Sigo buscando.")
        let nudge = Task { @MainActor in
            try await Task.sleep(for: .seconds(2.5))
            audio.say(line)
        }
        defer { nudge.cancel() }
        return try await work()
    }

    /// The English or Spanish line, per the Spanish switch. Main only.
    private func t(_ english: String, _ spanish: String) -> String {
        tuning.spanish ? spanish : english
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
        let command = Command(heard, spanish: tuning.spanish, extras: commandExtras)
        if tuning.deadAirKiller {
            if command != nil { audio.working() }
            if !heard.isEmpty { showHeard(heard) }
        }
        switch command {
        case .find(let query): await find(query)
        case .whatsThis:
            if tuning.askAboutItems { await ask(nil) } else { await read() }
        case .ask(let question):
            if tuning.askAboutItems { await ask(question) } else { audio.say(t("Say find, then an object.", "Di encuentra y un objeto.")) }
        case .scan: await scan()
        case .money: await countMoney()
        case .checkMine(let name): await checkMine(name)
        case .watch: startWatching()
        case .stopWatching: stopWatching(saying: true)
        case .remember(let item):
            if tuning.myObjects || tuning.medicationCheck { await remember(item) } else { audio.say(t("Say find, then an object.", "Di encuentra y un objeto.")) }  // off: as before
        case .whereIs(let item):
            if tuning.whereDidILeave {
                await whereIs(item)
            } else if heard.lowercased().contains("where did") {
                audio.say(t("Say find, then an object.", "Di encuentra y un objeto."))  // as before this feature
            } else {
                await find(item)
            }
        case .stop: stop()
        case nil:
            audio.say(heard.isEmpty ? t("I didn't hear anything.", "No escuché nada.") : t("Say find, then an object.", "Di encuentra y un objeto."))
        }
    }

    // MARK: What's this?

    /// Describes what the user is holding up: Vision reads the text, Claude says what it is in one sentence.
    @MainActor
    func read() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        audio.say(t("Let me see.", "Déjame ver."))
        guard cameraError == nil, let snapshot = await snapshot() else { return cameraNotReady() }
        let start = CACurrentMediaTime()
        do {
            let answer = try await reader.describe(snapshot.jpeg, model: tuning.claudeModel, spanish: tuning.spanish)
            readMs = (CACurrentMediaTime() - start) * 1000
            audio.say(answer)
        } catch {
            readMs = (CACurrentMediaTime() - start) * 1000
            print("Read: \(error.localizedDescription)")
            audio.say(t("I couldn't read that.", "No pude leer eso."))
        }
    }

    /// A question about the held item (nil = "what's this?"), answered by Gemini from what's printed on it.
    /// The item is kept for one follow-up ("how many do I take?"); "what's this?" always starts a new one.
    @MainActor
    func ask(_ question: String?) async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        audio.say(t("Let me see.", "Déjame ver."))
        guard cameraError == nil, let snapshot = await snapshot() else { return cameraNotReady() }
        let previous = question == nil ? nil : lastItem.flatMap { CACurrentMediaTime() - $0.time < 120 ? $0 : nil }
        lastItem = nil
        let start = CACurrentMediaTime()
        do {
            let result = try await stillLooking {
                try await reader.ask(question, jpeg: snapshot.jpeg, previous: previous,
                                     allergies: tuning.allergyList, model: tuning.geminiModel, spanish: tuning.spanish)
            }
            readMs = (CACurrentMediaTime() - start) * 1000
            geminiMs = readMs
            if previous == nil { lastItem = result.item }
            audio.say(result.spoken)
        } catch {
            readMs = (CACurrentMediaTime() - start) * 1000
            print("Ask: \(error.localizedDescription)")
            geminiFailed(t("I couldn't read that.", "No pude leer eso."), error)
        }
    }

    // MARK: Money

    /// "How much money is this?": reads each bill (held up or on the table), labels it on screen, and says the
    /// total of the ones it can clearly read. Unreadable bills are said, never guessed.
    @MainActor
    func countMoney() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        audio.say(t("Let me see.", "Déjame ver."))
        guard cameraError == nil, let snapshot = await snapshot() else { return cameraNotReady() }
        let start = CACurrentMediaTime()
        do {
            let bills = try await stillLooking { try await moneyReader.read(snapshot.jpeg, model: tuning.geminiModel) }
            readMs = (CACurrentMediaTime() - start) * 1000
            geminiMs = readMs
            let boxes = bills.map { LabeledBox(label: $0.value.map { "$\($0)" } ?? "?", box: $0.box) }
            moneyBoxes = boxes
            boxesShownAt = Date()
            Task {
                try? await Task.sleep(for: .seconds(10))
                if moneyBoxes.map(\.box) == boxes.map(\.box) { moneyBoxes = [] }
            }
            audio.say(MoneyReader.spoken(bills, spanish: tuning.spanish))
        } catch {
            readMs = (CACurrentMediaTime() - start) * 1000
            print("Money: \(error.localizedDescription)")
            geminiFailed(t("I couldn't read that.", "No pude leer eso."), error)
        }
    }

    // MARK: Is this my medicine?

    /// "Is this my lisinopril?": the held bottle's label against the one saved with "this is my lisinopril".
    @MainActor
    func checkMine(_ name: String) async {
        guard !reading else { return }
        guard let photo = MyObjects.reference(for: name), let text = MyObjects.text(for: name) else {
            return audio.say(t("I don't have your \(name) saved yet. Hold it up and say this is my \(name).",
                               "Todavía no tengo guardado tu \(name). Sostenlo y di esta es mi \(name)."))
        }
        reading = true
        defer { reading = false }
        audio.say(t("Let me see.", "Déjame ver."))
        guard cameraError == nil, let snapshot = await snapshot() else { return cameraNotReady() }
        let start = CACurrentMediaTime()
        do {
            let answer = try await stillLooking {
                try await medicationCheck.check(name, jpeg: snapshot.jpeg, saved: (photo, text), model: tuning.geminiModel,
                                                spanish: tuning.spanish)
            }
            readMs = (CACurrentMediaTime() - start) * 1000
            geminiMs = readMs
            audio.say(answer)
        } catch {
            readMs = (CACurrentMediaTime() - start) * 1000
            print("Check: \(error.localizedDescription)")
            geminiFailed(t("I couldn't read that.", "No pude leer eso."), error)
        }
    }

    // MARK: Following a moved object

    /// Keeps the pin on the object if someone moves it: while guiding, Gemini (Flash-Lite) re-checks where it is about
    /// every 2 s, told where it was so it doesn't jump to a lookalike, and it's re-pinned if it moved more than 5 cm.
    /// Skipped while the hand is on or near it (the hand would hide it).
    @MainActor
    private func startFollowing() {
        followTask?.cancel()
        guard tuning.followMovedObjects else { return }
        followTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard state == .guiding || state == .lost, let label = targetLabel, !isListening, !reading, !scanning else { continue }
                if let tip = fingertip, let box = targetBox,
                   box.insetBy(dx: -box.width * 0.5, dy: -box.height * 0.5).contains(tip) { continue }
                await followOnce(label, hint: targetBox)
            }
        }
    }

    @MainActor
    private func followOnce(_ label: String, hint: CGRect?) async {
        guard cameraError == nil, let snapshot = await snapshot(),
              let found = try? await locator.locate(label, in: snapshot.jpeg, model: Self.watchModel, near: hint,
                                                    spanish: tuning.spanish),
              targetLabel == label, state == .guiding || state == .lost, !Task.isCancelled else { return }
        let shift: Float = await withCheckedContinuation { continuation in
            camera.frameQueue.async {
                guard let current = self.anchor,
                      let pinned = ObjectAnchor(box: found.box, seenIn: snapshot.geometry, session: self.camera.session) else {
                    return continuation.resume(returning: 0)
                }
                let shift = simd_distance(simd_float2(pinned.center.x, pinned.center.z), simd_float2(current.center.x, current.center.z))
                if shift > 0.05 {
                    self.anchor = pinned
                    self.recordSighting(label, pinned)
                }
                continuation.resume(returning: shift)
            }
        }
        guard shift > 0.05 else { return }
        targetShownAt = Date()
        if shift > 0.1 { audio.say(t("The \(label) moved.", "\(Self.capitalized(label)) se movió.")) }
    }

    // MARK: Watch mode

    static let watchModel = "gemini-3.5-flash-lite"

    /// "Tell me if anything changes": every ~3 s, a quick scan (Flash-Lite) is compared with the pins, and each
    /// object that appeared, moved or went is said once. Paused while guiding, listening or reading.
    @MainActor
    func startWatching() {
        watchTask?.cancel()
        watchFailures = 0
        audio.say(t("Watching the table. I'll tell you if anything changes.", "Vigilando la mesa. Te aviso si algo cambia."))
        watchTask = Task { @MainActor [weak self] in
            var firstLook = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                let busy = isListening || reading || scanning || [.guiding, .lost, .locating].contains(state)
                if busy { continue }
                await watchOnce(learnOnly: firstLook && sceneBoxes.isEmpty)  // no scan yet: the first look just learns the table
                firstLook = false
            }
        }
    }

    @MainActor
    func stopWatching(saying: Bool) {
        guard let watchTask else { return }
        watchTask.cancel()
        self.watchTask = nil
        if saying { audio.say(t("Stopped watching.", "Dejé de vigilar.")) }
    }

    @MainActor
    private func watchOnce(learnOnly: Bool) async {
        guard cameraError == nil, let snapshot = await snapshot() else { return }
        let spanish = tuning.spanish
        let found: [ObjectLocator.Found]
        do {
            found = try await locator.scan(snapshot.jpeg, model: Self.watchModel, spanish: spanish)
            watchFailures = 0
        } catch {
            watchFailures += 1
            print("Watch: \(error.localizedDescription)")
            if watchFailures >= 3 {
                stopWatching(saying: false)
                geminiFailed(t("I couldn't reach Gemini, so I stopped watching.", "No pude conectar con Gemini, así que dejé de vigilar."), error)
            }
            return
        }
        guard watchTask != nil, !Task.isCancelled else { return }
        let lines: [String] = await withCheckedContinuation { continuation in
            camera.frameQueue.async {
                let sightings = found.compactMap { object in
                    ObjectAnchor(box: object.box, seenIn: snapshot.geometry, session: self.camera.session).map { (object.label, $0) }
                }
                continuation.resume(returning: self.applyWatch(sightings, camera: snapshot.geometry.camera, learnOnly: learnOnly, spanish: spanish))
            }
        }
        if !lines.isEmpty { audio.say(lines.joined(separator: " ")) }
    }

    /// Compares a fresh look with the scene pins, updates them, and returns what to say. A new object counts once it's
    /// seen twice in the same spot; a pin counts as gone once it's in view and missed twice. Frame queue only.
    private func applyWatch(_ sightings: [(label: String, anchor: ObjectAnchor)], camera: ARCamera, learnOnly: Bool,
                            spanish: Bool) -> [String] {
        if learnOnly {
            scene = sightings.sorted { $0.anchor.center.x < $1.anchor.center.x }
            watchMisses = []
            watchCandidates = []
            touching = nil
            return []
        }
        func distance(_ a: ObjectAnchor, _ b: ObjectAnchor) -> Float {
            simd_distance(simd_float2(a.center.x, a.center.z), simd_float2(b.center.x, b.center.z))
        }
        var lines: [String] = []
        var seen = Set<Int>()
        var candidates: [(label: String, anchor: ObjectAnchor)] = []
        for sighting in sightings {
            let open = scene.indices.filter { !seen.contains($0) }
            if let same = open.min(by: { distance(scene[$0].anchor, sighting.anchor) < distance(scene[$1].anchor, sighting.anchor) }),
               distance(scene[same].anchor, sighting.anchor) < 0.06 {
                seen.insert(same)  // still there
            } else if let moved = open.first(where: { Self.matches(scene[$0].label, sighting.label)
                                                       && distance(scene[$0].anchor, sighting.anchor) < 0.6 }) {
                seen.insert(moved)
                scene[moved].anchor = sighting.anchor
                recordSighting(scene[moved].label, sighting.anchor)
                let side = Self.side(of: sighting.anchor, from: camera, spanish: spanish)
                lines.append(spanish ? "\(Self.capitalized(scene[moved].label)) se movió \(side)."
                                     : "The \(scene[moved].label) moved \(side).")
            } else if watchCandidates.contains(where: { distance($0.anchor, sighting.anchor) < 0.06 }) {
                scene.append(sighting)
                seen.insert(scene.count - 1)
                recordSighting(sighting.label, sighting.anchor)
                let side = Self.side(of: sighting.anchor, from: camera, spanish: spanish)
                lines.append(spanish ? "Nuevo \(side): \(sighting.label)." : "Someone put \(Self.withArticle(sighting.label)) down \(side).")
            } else {
                candidates.append(sighting)  // one look can be a fluke
            }
        }
        watchCandidates = candidates

        var kept: [(label: String, anchor: ObjectAnchor)] = []
        var misses: [Int] = []
        for (index, pin) in scene.enumerated() {
            if seen.contains(index) {
                kept.append(pin)
                misses.append(0)
                continue
            }
            let inView = pin.anchor.box(in: camera).map { CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9).contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
            let missed = (index < watchMisses.count ? watchMisses[index] : 0) + (inView ? 1 : 0)
            if missed >= 2 {
                let plural = pin.label.hasSuffix("s") && !pin.label.hasSuffix("ss")
                lines.append(spanish ? "Ya no está: \(pin.label)." : "The \(pin.label) \(plural ? "are" : "is") gone.")
            } else {
                kept.append(pin)
                misses.append(missed)
            }
        }
        if kept.count != scene.count || !lines.isEmpty { touching = nil }
        scene = kept
        watchMisses = misses
        return lines
    }

    /// "a cup", "an apple", "keys".
    private static func withArticle(_ label: String) -> String {
        if label.hasSuffix("s") && !label.hasSuffix("ss") { return label }
        return ("aeiou".contains(label.prefix(1).lowercased()) ? "an " : "a ") + label
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: What's on the table?

    /// Gemini lists every object on the table; each is pinned in 3D and named left to right. Afterwards,
    /// touching an object names it, and "find" goes straight to a scanned object without asking Gemini again.
    @MainActor
    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        audio.say(t("Looking at the table.", "Mirando la mesa."))
        guard cameraError == nil, let snapshot = await snapshot() else { return cameraNotReady() }
        let start = CACurrentMediaTime()
        let found: [ObjectLocator.Found]
        do {
            found = try await stillLooking { try await locator.scan(snapshot.jpeg, model: tuning.geminiModel, spanish: tuning.spanish) }
            locateMs = (CACurrentMediaTime() - start) * 1000
            geminiMs = locateMs
        } catch {
            locateMs = (CACurrentMediaTime() - start) * 1000
            print("Scan: \(error.localizedDescription)")
            geminiFailed(t("I couldn't reach Gemini.", "No pude conectar con Gemini."), error)
            return
        }
        let objects = found.sorted { $0.box.midX < $1.box.midX }
        camera.frameQueue.async {
            self.scene = objects.compactMap { object in
                ObjectAnchor(box: object.box, seenIn: snapshot.geometry, session: self.camera.session).map { (object.label, $0) }
            }
            self.scene.forEach { self.recordSighting($0.label, $0.anchor) }
            self.touching = nil
            self.watchMisses = []
        }
        boxesShownAt = Date()
        audio.say(Self.summary(objects.map(\.label), spanish: tuning.spanish))
        // So touch-to-explore names and obstacle warnings play instantly.
        audio.prefetch(objects.map { Self.touchName($0.label) } + objects.map { Self.obstaclePhrase($0.label, spanish: tuning.spanish) })
    }

    /// "I see 4 things, left to right: keys, blue mug, phone and pill bottle."
    private static func summary(_ labels: [String], spanish: Bool) -> String {
        switch labels.count {
        case 0: return spanish ? "No veo nada en la mesa." : "I don't see anything on the table."
        case 1: return spanish ? "Veo \(labels[0])." : "I see \(labels[0])."
        default:
            let list = labels.dropLast().joined(separator: ", ")
            return spanish ? "Veo \(labels.count) cosas, de izquierda a derecha: \(list) y \(labels.last!)."
                           : "I see \(labels.count) things, left to right: \(list) and \(labels.last!)."
        }
    }

    /// What's said when the fingertip lands on a scanned object: "Blue mug."
    private static func touchName(_ label: String) -> String {
        label.prefix(1).uppercased() + label.dropFirst() + "."
    }

    /// "keys" finds "car keys", "mug" finds "blue mug", "glasses" finds "reading glasses".
    static func matches(_ label: String, _ query: String) -> Bool {
        let label = label.lowercased(), query = query.lowercased()
        if label.contains(query) || query.contains(label) { return true }
        let head = { (text: String) -> String in
            let word = String(text.split(separator: " ").last ?? "")
            return word.hasSuffix("s") ? String(word.dropLast()) : word
        }
        return head(label) == head(query)
    }

    /// A pinned object matching `query`: from the last scan, or (with "where did I leave" on) anywhere Reach has seen one.
    @MainActor
    private func scannedObject(matching query: String) async -> (label: String, anchor: ObjectAnchor)? {
        let useSightings = tuning.whereDidILeave
        return await withCheckedContinuation { continuation in
            camera.frameQueue.async {
                if let scanned = self.scene.first(where: { Self.matches($0.label, query) }) {
                    return continuation.resume(returning: scanned)
                }
                let seen = useSightings ? self.sightings.values.filter { Self.matches($0.label, query) }.max { $0.time < $1.time } : nil
                continuation.resume(returning: seen.map { ($0.label, $0.anchor) })
            }
        }
    }

    // MARK: This is my mug

    /// Finds `item` in the frame (the one being held up, nearest the person) and saves it as the reference photo.
    @MainActor
    func remember(_ item: String) async {
        audio.say(t("Let me see.", "Déjame ver."))
        guard cameraError == nil, let snapshot = await snapshot() else { return cameraNotReady() }
        do {
            guard let found = try await stillLooking({
                      try await locator.locate(item, in: snapshot.jpeg, model: tuning.geminiModel, spanish: tuning.spanish)
                  }),
                  let crop = FrameEncoder.crop(snapshot.jpeg, to: found.box) else {
                audio.say(t("I couldn't see your \(item). Hold it up in front of the camera and try again.",
                            "No pude ver tu \(item). Sostenlo frente a la cámara e intenta de nuevo."))
                return
            }
            try MyObjects.save(crop, as: item)
            if tuning.medicationCheck {  // keep its printed label for "is this my …?"
                try MyObjects.saveText(await Reader.recognizeText(in: crop).joined(separator: " | "), as: item)
            }
            audio.say(t("Got it. I'll remember your \(item).", "Listo. Recordaré tu \(item)."))
        } catch {
            print("Remember: \(error.localizedDescription)")
            geminiFailed(t("I couldn't reach Gemini.", "No pude conectar con Gemini."), error)
        }
    }

    // MARK: Where did I leave it?

    /// "Your keys were to your left, 3 minutes ago. Say find keys and I'll take you there."
    @MainActor
    func whereIs(_ item: String) async {
        let spanish = tuning.spanish
        let answer: String = await withCheckedContinuation { continuation in
            camera.frameQueue.async {
                guard let seen = self.sightings.values.filter({ Self.matches($0.label, item) }).max(by: { $0.time < $1.time }) else {
                    return continuation.resume(returning: spanish ? "Todavía no he visto \(item). Di encuentra \(item) y lo busco."
                                                                  : "I haven't seen \(item) yet. Say find \(item) and I'll look.")
                }
                let side = self.lastCamera.map { Self.side(of: seen.anchor, from: $0, spanish: spanish) } ?? (spanish ? "cerca" : "nearby")
                let ago = Self.timeAgo(CACurrentMediaTime() - seen.time, spanish: spanish)
                let plural = seen.label.hasSuffix("s")
                continuation.resume(returning: spanish
                    ? "\(plural ? "Tus" : "Tu") \(seen.label) \(plural ? "estaban" : "estaba") \(side), \(ago). Di encuentra \(item) y te llevo."
                    : "Your \(seen.label) \(plural ? "were" : "was") \(side), \(ago). Say find \(item) and I'll take you there.")
            }
        }
        audio.say(answer)
    }

    /// Frame queue only.
    private func recordSighting(_ label: String, _ pinned: ObjectAnchor) {
        sightings[label.lowercased()] = (label, pinned, CACurrentMediaTime())
    }

    /// Which way a pinned object is from where the camera points now.
    private static func side(of pinned: ObjectAnchor, from camera: ARCamera, spanish: Bool) -> String {
        guard let box = pinned.box(in: camera) else { return spanish ? "detrás de ti" : "behind you" }
        switch box.midX {
        case ..<0: return spanish ? "más a tu izquierda" : "off to your left"
        case ..<0.4: return spanish ? "a tu izquierda" : "to your left"
        case ...0.6: return spanish ? "frente a ti" : "in front of you"
        case ...1: return spanish ? "a tu derecha" : "to your right"
        default: return spanish ? "más a tu derecha" : "off to your right"
        }
    }

    private static func timeAgo(_ seconds: TimeInterval, spanish: Bool) -> String {
        switch seconds {
        case ..<20: return spanish ? "hace un momento" : "just now"
        case ..<60: return spanish ? "hace \(Int(seconds / 10) * 10) segundos" : "\(Int(seconds / 10) * 10) seconds ago"
        case ..<120: return spanish ? "hace un minuto" : "a minute ago"
        case ..<3600: return spanish ? "hace \(Int(seconds / 60)) minutos" : "\(Int(seconds / 60)) minutes ago"
        default: return spanish ? "hace más de una hora" : "over an hour ago"
        }
    }

    // MARK: Targets

    /// Find `query` with Gemini, then guide the hand to it.
    @MainActor
    func find(_ query: String) async {
        stopWatching(saying: false)  // any find ends watch mode
        followTask?.cancel()
        targetLabel = query
        if let scanned = await scannedObject(matching: query) {  // already pinned by a scan: no Gemini round trip
            targetLabel = scanned.label
            camera.frameQueue.async { self.startGuiding(to: scanned.anchor, pendingBox: nil, announcing: scanned.label) }
            startFollowing()
            return
        }
        audio.say(t("Looking for \(query).", "Buscando \(query)."))
        camera.frameQueue.async {
            self.clearTarget()
            self.guide.beginLocating()
        }
        let result: (found: ObjectLocator.Found, geometry: FrameGeometry)?
        do {
            result = try await stillLooking { try await locate(query) }
        } catch {
            print("Locate: \(error.localizedDescription)")
            if targetLabel == query { stop() }
            if error is CameraNotReady { cameraNotReady() } else { geminiFailed(t("I couldn't reach Gemini.", "No pude conectar con Gemini."), error) }
            return
        }
        guard targetLabel == query else { return }  // stopped or replaced while we waited
        guard let result else {
            stop()
            audio.say(t("I don't see \(query).", "No veo \(query)."))
            return
        }
        targetLabel = result.found.label
        pin(result.found.box, seenIn: result.geometry, announcing: result.found.label)
        startFollowing()
    }

    /// Guide the hand to a box tapped or drawn on screen (normalized, origin top-left).
    func seed(_ box: CGRect) {
        targetLabel = nil
        pin(box, seenIn: nil)
    }

    @MainActor
    func stop() {
        stopWatching(saying: false)
        followTask?.cancel()
        targetLabel = nil
        camera.frameQueue.async {
            self.clearTarget()
            self.guide.stop()
            self.audio.setTone(.silent)
        }
    }

    /// Pins `box` to the table using the frame that saw it (nil = the next frame).
    private func pin(_ box: CGRect, seenIn seen: FrameGeometry?, announcing label: String? = nil) {
        camera.frameQueue.async {
            let pinned = seen.flatMap { ObjectAnchor(box: box, seenIn: $0, session: self.camera.session) }
            self.startGuiding(to: pinned, pendingBox: pinned == nil ? box : nil, announcing: label)
        }
    }

    /// Starts guiding to a pinned object (or a box still waiting to be pinned). Frame queue only.
    private func startGuiding(to pinned: ObjectAnchor?, pendingBox: CGRect?, announcing label: String?) {
        anchor = pinned
        self.pendingBox = pendingBox
        if let pinned, let label { recordSighting(label, pinned) }
        pendingAnnouncement = label
        pendingAnnouncementSince = CACurrentMediaTime()  // same clock as frame timestamps
        smoothedGap = nil
        hovering = false
        focusLocked = false  // refocus on the new target with the next frame
        guidingSince = CACurrentMediaTime()
        obstacleWarned = false
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
        pin(result.found.box, seenIn: result.geometry)
    }

    @MainActor
    private func locate(_ query: String) async throws -> (found: ObjectLocator.Found, geometry: FrameGeometry)? {
        guard cameraError == nil, let snapshot = await snapshot() else {
            if tuning.networkFallback { throw CameraNotReady() }
            return nil
        }
        let start = CACurrentMediaTime()
        defer {
            locateMs = (CACurrentMediaTime() - start) * 1000
            geminiMs = locateMs
        }
        let reference = tuning.myObjects ? MyObjects.reference(for: query) : nil
        guard let found = try await locator.locate(query, in: snapshot.jpeg, model: tuning.geminiModel, reference: reference,
                                                   spanish: tuning.spanish) else {
            return nil
        }
        return (found, snapshot.geometry)
    }

    /// The next frame as a JPEG, with its camera pose. With the network-failure path on, gives up after 1.5 s
    /// (ARKit paused, say) instead of waiting forever.
    @MainActor
    private func snapshot() async -> Snapshot? {
        let limit: TimeInterval? = tuning.networkFallback ? 1.5 : nil
        return await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Snapshot?) -> Void = { snapshot in
                let first = done.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: snapshot) }
            }
            camera.frameQueue.async { self.snapshotRequests.append(finish) }
            if let limit { DispatchQueue.main.asyncAfter(deadline: .now() + limit) { finish(nil) } }
        }
    }

    private struct CameraNotReady: Error {}

    static let offline = "I can't reach the internet. Tap the object on screen and I'll guide you."

    /// A Gemini call failed. With the network-failure path: say what actually went wrong (offline, too slow, or
    /// Gemini itself) plus a way forward, and show the error on screen. Otherwise `old`, as before.
    @MainActor
    private func geminiFailed(_ old: String, _ error: Error) {
        guard tuning.networkFallback else { return audio.say(old) }
        showError(error.localizedDescription)
        let code = (error as? URLError)?.code
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                                        .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff]
        if let code, offline.contains(code) {
            audio.say(t(Self.offline, "No puedo conectarme a internet. Toca el objeto en la pantalla y te guío."))
        } else if code == .timedOut {
            audio.say(t("Gemini is taking too long. Tap the object on screen and I'll guide you.",
                        "Gemini está tardando demasiado. Toca el objeto en la pantalla y te guío."))
        } else {
            audio.say(t("Gemini had a problem. Tap the object on screen and I'll guide you.",
                        "Gemini tuvo un problema. Toca el objeto en la pantalla y te guío."))
        }
    }

    /// The last error, on screen for a few seconds (so a failure is never a mystery).
    @MainActor
    private func showError(_ text: String) {
        lastError = text
        Task {
            try? await Task.sleep(for: .seconds(8))
            if lastError == text { lastError = nil }
        }
    }

    /// No photo to work with: say so (network-failure path) rather than going quiet.
    @MainActor
    private func cameraNotReady() {
        guard tuning.networkFallback else { return }
        audio.say(t("The camera isn't ready. Try again.", "La cámara no está lista. Intenta de nuevo."))
    }

    // MARK: Frames

    private func process(_ frame: ARFrame) {
        let time = frame.timestamp
        if !snapshotRequests.isEmpty {
            let snapshot = FrameEncoder.jpeg(frame.capturedImage).map { Snapshot(jpeg: $0, geometry: FrameGeometry(frame: frame)) }
            snapshotRequests.forEach { $0(snapshot) }
            snapshotRequests.removeAll()
        }
        // Every frame (up to 60 fps) while guiding; 15 fps otherwise, to keep the phone cool through a long demo.
        let guiding = guide.state == .guiding || guide.state == .lost
        guard time - lastProcessed >= (guiding ? 1.0 / 65 : 1.0 / 15) else { return }
        let frameInterval = time - lastProcessed
        lastProcessed = time

        let tuning = frameTuning.withLock { $0 }
        if let change = torch.update(light: frame.lightEstimate?.ambientIntensity, enabled: tuning.autoTorch, time: time) {
            camera.setTorch(change)
        }
        let torchOn = torch.isOn
        hands.restCutoff = tuning.restCutoff
        hands.speedResponse = tuning.speedResponse
        let finger = hands.process(frame.capturedImage, time: time)
        let geometry = FrameGeometry(frame: frame)
        lastCamera = frame.camera

        if let box = pendingBox, let pinned = ObjectAnchor(box: box, seenIn: geometry, session: camera.session) {
            anchor = pinned
            pendingBox = nil
        }
        let trackingNote = Self.note(for: frame.camera.trackingState)
        let box = anchor?.box(in: frame.camera) ?? pendingBox
        if let box, !focusLocked, guide.state == .guiding || guide.state == .lost {
            camera.lockFocus(at: geometry.landscapePoint(CGPoint(x: box.midX, y: box.midY)))
            focusLocked = true
        }
        let input = guideInput(geometry: geometry, finger: finger, box: box, trackingLost: trackingNote != nil)
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
                announcement = Guide.announcement(label, input, spanish: tuning.spanish)
                pendingAnnouncement = nil
            } else if time - pendingAnnouncementSince > 1.5 {  // ARKit hasn't pinned it yet: don't stay silent
                announcement = tuning.spanish ? "Encontré \(label)." : "Found \(label)."
                pendingAnnouncement = nil
            }
        }

        // Touch-to-explore, when not guiding somewhere.
        var touchedName: String?
        if !scene.isEmpty, guide.state == .idle || guide.state == .locked, let finger {
            touchedName = touchedObject(finger, geometry: geometry, time: time)
        } else {
            touching = nil
        }
        let sceneBoxes = scene.compactMap { object in object.anchor.box(in: frame.camera).map { LabeledBox(label: object.label, box: $0) } }
        let touchedLabel = touching.map { scene[$0].label }

        let reachTime = output.event == .locked ? time - guidingSince : nil
        var obstacleWarning: String?
        if tuning.obstacleWarning, !scene.isEmpty, !obstacleWarned, guide.state == .guiding, let anchor, let finger,
           let hand = geometry.point(at: finger.tip, onPlaneAt: anchor.topY),
           let axes = geometry.axes(onPlaneAt: anchor.tableY),
           let label = obstacle(from: hand, to: anchor, axes: axes) {
            obstacleWarning = Self.obstaclePhrase(label, spanish: tuning.spanish)
            obstacleWarned = true
        }
        let minimap = tuning.minimap ? makeMinimap(geometry: geometry, finger: finger, tone: output.tone) : nil

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
            self.torchOn = torchOn
            self.touchedLabel = touchedLabel
            if let touchedName, !self.isListening {
                self.audio.say(touchedName)
            }
            if let obstacleWarning { self.audio.say(obstacleWarning) }
            if let announcement {
                self.targetShownAt = Date()
                self.audio.say(announcement)
            } else if let cue = output.cue, !self.isListening {  // don't talk over the user
                self.audio.cue(cue)
            }
            switch output.event {
            case .locked:
                self.followTask?.cancel()
                self.audio.say(Self.gotIt(self.targetLabel, spanish: self.tuning.spanish))
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

    /// The first scanned object (not the target) within 6 cm of the hand's straight path to the target,
    /// on the table plane. Frame queue only.
    private func obstacle(from hand: simd_float3, to target: ObjectAnchor, axes: (right: simd_float3, forward: simd_float3)) -> String? {
        let start = simd_float2(hand.x, hand.z), end = simd_float2(target.center.x, target.center.z)
        let path = end - start
        let length = simd_length(path)
        guard length > 0.05 else { return nil }
        var first: (along: Float, label: String)?
        for object in scene {
            let center = simd_float2(object.anchor.center.x, object.anchor.center.z)
            guard simd_distance(center, end) > 0.03 else { continue }  // the target itself
            let along = simd_dot(center - start, path) / (length * length)
            guard along > 0.05, along < 0.95 else { continue }  // between the hand and the target
            let half = object.anchor.halfExtents(right: axes.right, forward: axes.forward)
            let gap = simd_distance(center, start + along * path) - Float(half.right + half.forward) / 2
            if gap < 0.06, along < (first?.along ?? .infinity) { first = (along, object.label) }
        }
        return first?.label
    }

    private static func obstaclePhrase(_ label: String, spanish: Bool) -> String {
        spanish ? "Cuidado, \(label) en el camino." : "Careful, \(label) in the way."
    }

    /// Pinned objects and the hand, top-down in meters from the user's body. Frame queue only.
    private func makeMinimap(geometry: FrameGeometry, finger: HandTracker.Finger?, tone: AudioGuide.Tone) -> Minimap? {
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
        let hand = finger.flatMap { geometry.point(at: $0.tip, onPlaneAt: tableY) }
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
    private func guideInput(geometry: FrameGeometry, finger: HandTracker.Finger?, box: CGRect?,
                            trackingLost: Bool) -> Guide.Input? {
        guard var pinned = anchor, let axes = geometry.axes(onPlaneAt: pinned.tableY) else { return nil }

        // Refine the object's height from LiDAR at its middle while the hand is nowhere near it.
        if let box, finger.map({ !box.insetBy(dx: -box.width, dy: -box.height).contains($0.tip) }) ?? true,
           let top = geometry.surfacePoint(at: CGPoint(x: box.midX, y: box.midY)) {
            pinned.topY = min(max(pinned.topY + (top.y - pinned.topY) * 0.2, pinned.tableY), pinned.tableY + 0.4)
            anchor = pinned
        }

        // The hand: where the fingertip's line of sight meets the object's height. Steady, unlike finger depth.
        let hand = finger.flatMap { geometry.point(at: $0.tip, onPlaneAt: pinned.topY) }
        let hoveringNow = finger.flatMap { isHovering(over: pinned.topY, finger: $0, geometry: geometry) }
        guard let from = hand ?? geometry.point(at: CGPoint(x: 0.5, y: 1), onPlaneAt: pinned.tableY) else { return nil }

        let toObject = pinned.center - from
        let half = pinned.halfExtents(right: axes.right, forward: axes.forward)
        return Guide.Input(right: Double(simd_dot(toObject, axes.right)), forward: Double(simd_dot(toObject, axes.forward)),
                           hovering: hoveringNow, halfRight: half.right, halfForward: half.forward,
                           hasHand: finger != nil, trackingLost: trackingLost)
    }

    /// Whether LiDAR clearly puts the finger in front of a surface at height `topY` along its line of sight, i.e.
    /// hovering above it rather than touching: in at 6 cm, out at 4 cm. Nil when the finger's depth isn't trustworthy.
    /// Frame queue only.
    private func isHovering(over topY: Float, finger: HandTracker.Finger, geometry: FrameGeometry) -> Bool? {
        guard let fingerDepth = geometry.fingerDepth(tip: finger.tip, pad: finger.pad),
              let surfaceDepth = geometry.depthOnPlane(at: finger.tip, y: topY) else { return nil }
        let gap = Double(surfaceDepth - fingerDepth)
        let smoothed = smoothedGap.map { $0 + (gap - $0) * 0.4 } ?? gap
        smoothedGap = smoothed
        hovering = hovering ? smoothed > 0.04 : smoothed > 0.06
        return hovering
    }

    /// The name of the scanned object the fingertip just landed on, once per arrival. With LiDAR, "on" means
    /// within the object's footprint and touching its top; without, inside its box on screen. Frame queue only.
    private func touchedObject(_ finger: HandTracker.Finger, geometry: FrameGeometry, time: TimeInterval) -> String? {
        var hit: Int?
        if let axes = geometry.axes(onPlaneAt: scene[0].anchor.tableY) {
            var nearest = Float.infinity
            for (index, object) in scene.enumerated() {
                // The fingertip's line of sight at this object's height, inside its footprint, and not clearly hovering.
                guard let point = geometry.point(at: finger.tip, onPlaneAt: object.anchor.topY) else { continue }
                let offset = object.anchor.center - point
                let half = object.anchor.halfExtents(right: axes.right, forward: axes.forward)
                let on = abs(Double(simd_dot(offset, axes.right))) <= half.right + 0.01
                    && abs(Double(simd_dot(offset, axes.forward))) <= half.forward + 0.01
                let distance = simd_length(simd_float2(offset.x, offset.z))
                if on, distance < nearest, isHovering(over: object.anchor.topY, finger: finger, geometry: geometry) != true {
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
    private static func gotIt(_ label: String?, spanish: Bool) -> String {
        if spanish { return "Listo." }
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
