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
    /// A box waiting for ARKit to find the table under it; no guidance (silent) until it pins.
    @ObservationIgnored private var pendingBox: CGRect?
    @ObservationIgnored private var snapshotRequests: [(Snapshot?) -> Void] = []
    /// Label to announce ("Found keys, out and to the right.") once the next pin has real positions.
    @ObservationIgnored private var pendingAnnouncement: String?
    @ObservationIgnored private var pendingAnnouncementSince: TimeInterval = 0
    /// How far LiDAR puts the finger in front of the object along the line of sight (smoothed), and whether that
    /// counts as hovering (with hysteresis).
    @ObservationIgnored private var smoothedGap: Double?
    @ObservationIgnored private var hovering = false
    /// This frame's LiDAR reading put the fingertip right at the object's top (careful guidance).
    @ObservationIgnored private var touchNow = false
    /// Careful follow: a move seen in one look, waiting for a second look to agree.
    @ObservationIgnored private var followCandidate: ObjectAnchor?
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
    /// The "can't place it yet" line was said for this target.
    @ObservationIgnored private var pendingHintSaid = false
    /// Seconds of silence before that line: longer after a "Found keys." that slow live speech may still be saying.
    @ObservationIgnored private var hintAfter: TimeInterval = 4
    /// Every object pinned so far (by a scan or a find), by lowercased label, with when it was seen.
    @ObservationIgnored private var sightings: [String: (label: String, anchor: ObjectAnchor, time: TimeInterval)] = [:]
    /// Sightings (by key) where a reach ended, locked or not: "where are my keys?" still says where, but a find
    /// doesn't fall back there, as they may be in the user's hand.
    @ObservationIgnored private var unlockedEnds: Set<String> = []
    /// The latest frame's camera, to say which side a remembered object is on.
    @ObservationIgnored private var lastCamera: ARCamera?
    @ObservationIgnored private var torch = AutoTorch()
    // Main only:
    @ObservationIgnored private var relocating = false
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var scanning = false
    /// When hold-to-talk last ended (host clock), so a careful "Down." doesn't cut off the reply.
    @ObservationIgnored private var listenEndedAt: TimeInterval = 0
    /// The last listen is still being transcribed (voice.stop() is waiting).
    @ObservationIgnored private var ending = false
    /// The last held item asked about, kept for one follow-up question.
    @ObservationIgnored private var lastItem: Reader.Item?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    /// Which find is current (a repeated find has the same label).
    @ObservationIgnored private var findID = 0
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
    var isListening = false {
        didSet { if oldValue, !isListening { listenEndedAt = CACurrentMediaTime() } }
    }
    /// Watch mode is running (state stays idle meanwhile, so Stop checks this too).
    var watching = false
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
    /// How the last lock happened ("lidar 0.6 s"), for the stats line.
    var lockNote = ""
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
        camera.onError = { [weak self] error in
            guard let self else { return }
            cameraError = error.localizedDescription
            stop()  // no more frames: don't leave the sonar on its last ping
            cameraNotReady()
        }
        do {
            try camera.start()
        } catch {
            cameraError = error.localizedDescription
        }
        voice.spanish = tuning.spanish
        audio.spanish = tuning.spanish
        audio.networkFallback = tuning.networkFallback
        _ = await voice.requestPermissions()  // ask now, not mid-demo
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
            switch Command(phrase, spanish: tuning.spanish) {
            case .find(let item): await find(item)
            case nil: audio.say(t("Say find, then an object.", "Di encuentra y un objeto."))  // "my", "the", empty
            default: await find(object.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))  // "my scanner" reads as a scan
            }
        case .scan:
            await scan()
        }
    }

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

    /// Runs a Gemini wait; if it takes more than 2.5 s, says "Still looking." once (dead-air killer), unless `current`
    /// says the wait was stopped or replaced by then.
    @MainActor
    private func stillLooking<T>(while current: @escaping @MainActor () -> Bool = { true },
                                 _ work: () async throws -> T) async rethrows -> T {
        guard tuning.deadAirKiller else { return try await work() }
        let line = t("Still looking.", "Sigo buscando.")
        let nudge = Task { @MainActor in
            try await Task.sleep(for: .seconds(2.5))
            if current() { audio.say(line) }
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
        Haptics.tap()  // only when listening really starts: a press while the last one is still finishing records nothing
        isListening = true
        audio.setMuted(true)
        audio.hush()  // the mic would hear Reach's own voice on the loudspeaker
        if tuning.carefulGuidance { camera.frameQueue.async { self.guide.forgetDown() } }  // a "Down." cut off: say it again
        voice.start()
    }

    @MainActor
    func endListening() async {
        guard isListening, !ending else { return }  // a second end while the last one finishes has nothing to end
        ending = true
        let heard = await voice.stop()
        ending = false
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
            if tuning.askAboutItems {
                // "What is this for?" / "¿Para qué es esto?" is a question, not a bare "what's this?": keep the words
                // and the follow-up.
                let spoken = heard.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                await ask(spoken.hasSuffix(" for") || (tuning.spanish && spoken.hasPrefix("para ")) ? heard : nil)
            } else { await read() }
        case .ask(let question):
            if tuning.askAboutItems { await ask(question) } else { audio.say(t("Say find, then an object.", "Di encuentra y un objeto.")) }
        case .scan: await scan()
        case .money: await countMoney()
        case .checkMine(let name): await checkMine(name)
        case .watch: startWatching()
        case .stopWatching: stopWatching(saying: true)
        case .remember(let item):
            if tuning.spanish, tuning.medicationCheck, MyObjects.text(for: item) != nil,
               !heard.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es")).contains("guarda esto como") {
                // "¿Esta es mi lisinopril?" sounds just like the save: check it; only "guarda esto como mi …" overwrites
                await checkMine(item, then: t("To replace the saved one, say this is my \(item).",
                                              "Para reemplazar lo guardado, di guarda esto como \(Self.pluralES(item) ? "mis" : "mi") \(item)."))
            } else if tuning.myObjects || tuning.medicationCheck { await remember(item) } else { audio.say(t("Say find, then an object.", "Di encuentra y un objeto.")) }  // off: as before
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
            if heard.isEmpty, tuning.networkFallback, !voice.isPermitted {  // never silent: say why, like cameraNotReady
                audio.say(t("Reach can't hear you. Turn on Microphone and Speech Recognition for Reach in Settings.",
                            "Reach no te oye. Activa el micrófono y el reconocimiento de voz para Reach en Configuración."))
            } else {
                audio.say(heard.isEmpty ? t("I didn't hear anything.", "No escuché nada.") : t("Say find, then an object.", "Di encuentra y un objeto."))
            }
        }
    }

    // MARK: What's this?

    /// Describes what the user is holding up: Vision reads the text, Claude says what it is in one sentence.
    @MainActor
    func read() async {
        guard !reading else { return stillReading() }
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

    /// A held-item read is still running: say so, so the answer that follows isn't taken for this request.
    @MainActor
    private func stillReading() {
        audio.say(t("Still reading the last one. Ask again in a moment.",
                    "Sigo leyendo lo anterior. Pregunta de nuevo en un momento."))
    }

    /// A question about the held item (nil = "what's this?"), answered by Gemini from what's printed on it.
    /// The item is kept for one follow-up ("how many do I take?"); "what's this?" always starts a new one.
    @MainActor
    func ask(_ question: String?) async {
        guard !reading else { return stillReading() }
        reading = true
        defer { reading = false }
        audio.say(t("Let me see.", "Déjame ver."))
        guard cameraError == nil, let snapshot = await snapshot() else { return cameraNotReady() }
        let previous = question == nil ? nil : lastItem.flatMap { Date().timeIntervalSinceReferenceDate - $0.time < 120 ? $0 : nil }
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
            if let previous { lastItem = previous }  // a failed follow-up keeps the item, so the retry still has it
            print("Ask: \(error.localizedDescription)")
            geminiFailed(t("I couldn't read that.", "No pude leer eso."), error)
        }
    }

    // MARK: Money

    /// "How much money is this?": reads each bill (held up or on the table), labels it on screen, and says the
    /// total of the ones it can clearly read. Unreadable bills are said, never guessed.
    @MainActor
    func countMoney() async {
        guard !reading else { return stillReading() }
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
    /// `tail` is said after a yes, in the same line (a second say would cut the answer off); never after a no or a
    /// can't-confirm.
    @MainActor
    func checkMine(_ name: String, then tail: String? = nil) async {
        guard !reading else { return stillReading() }
        guard let photo = MyObjects.reference(for: name), let text = MyObjects.text(for: name) else {
            if MyObjects.hasText(like: name) {  // saved under a near name: ask with that one, never save this bottle as a new one
                return audio.say(t("I have something saved under a similar name. Ask again with the name you saved it as.",
                                   "Tengo algo guardado con un nombre parecido. Pregunta de nuevo con el nombre que usaste."))
            }
            return audio.say(t("I don't have your \(name) saved yet. Hold it up and say this is my \(name).",
                               "Todavía no tengo guardado tu \(name). Sostenlo y di esta es mi \(name)."))
        }
        reading = true
        defer { reading = false }
        audio.say(t("Let me see.", "Déjame ver."))
        guard cameraError == nil, let snapshot = await snapshot() else { return cameraNotReady() }
        let start = CACurrentMediaTime()
        do {
            let (answer, yes) = try await stillLooking {
                try await medicationCheck.check(name, jpeg: snapshot.jpeg, saved: (photo, text), model: tuning.geminiModel,
                                                spanish: tuning.spanish)
            }
            readMs = (CACurrentMediaTime() - start) * 1000
            geminiMs = readMs
            audio.say(tail.map { yes ? "\(answer) \($0)" : answer } ?? answer)
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
                guard tuning.followMovedObjects else { return }  // switched off mid-reach
                guard state == .guiding || state == .lost, let label = targetLabel, !isListening, !reading, !scanning else { continue }
                if let tip = fingertip, let box = targetBox,
                   box.insetBy(dx: -box.width * 0.5, dy: -box.height * 0.5).contains(tip) { continue }
                await followOnce(label, hint: targetBox)
            }
        }
    }

    @MainActor
    private func followOnce(_ label: String, hint: CGRect?) async {
        guard cameraError == nil, let snapshot = await snapshot(), Self.steady(snapshot.geometry.camera),
              let found = try? await locator.locate(label, in: snapshot.jpeg, model: Self.watchModel,
                                                    reference: tuning.myObjects ? MyObjects.reference(for: label) : nil,
                                                    near: hint, spanish: tuning.spanish, retry: false),
              targetLabel == label, state == .guiding || state == .lost, tuning.followMovedObjects, !Task.isCancelled else { return }
        let careful = tuning.carefulGuidance
        let shift: Float = await withCheckedContinuation { continuation in
            camera.frameQueue.async {
                guard let current = self.anchor,
                      let pinned = ObjectAnchor(box: found.box, seenIn: snapshot.geometry, session: self.camera.session) else {
                    return continuation.resume(returning: 0)
                }
                let shift = simd_distance(simd_float2(pinned.center.x, pinned.center.z), simd_float2(current.center.x, current.center.z))
                if careful {
                    // A move must show up in two looks in a row (one can be a fluke: a hand half over it, a lookalike).
                    let agrees = self.followCandidate.map {
                        simd_distance(simd_float2($0.center.x, $0.center.z), simd_float2(pinned.center.x, pinned.center.z)) < 0.04
                    } ?? false
                    self.followCandidate = shift > 0.05 && !agrees ? pinned : nil
                    guard agrees else { return continuation.resume(returning: 0) }
                }
                if shift > 0.05 {
                    // The scan's pin moves with it, so the next find doesn't go back to the old spot.
                    if let i = self.scene.firstIndex(where: { simd_distance($0.anchor.center, current.center) < 0.03 }) {
                        self.scene[i].anchor = pinned
                    }
                    self.anchor = pinned
                    self.recordSighting(label, pinned)
                    if careful { self.smoothedGap = nil }  // a new top height
                }
                continuation.resume(returning: shift)
            }
        }
        guard shift > 0.05 else { return }
        targetShownAt = Date()
        if shift > 0.1 { audio.say(t("The \(label) moved.", "\(Self.capitalized(label)) \(Self.pluralES(label) ? "se movieron" : "se movió").")) }
    }

    // MARK: Watch mode

    static let watchModel = "gemini-3.5-flash-lite"

    /// Listening, reading, scanning or guiding: watch mode stays quiet.
    @MainActor
    private var watchPaused: Bool { isListening || reading || scanning || [.guiding, .lost, .locating].contains(state) }

    /// "Tell me if anything changes": every ~3 s, a quick scan (Flash-Lite) is compared with the pins, and each
    /// object that appeared, moved or went is said once. Paused while guiding, listening or reading.
    @MainActor
    func startWatching() {
        watchTask?.cancel()
        watchFailures = 0
        audio.say(t("Watching the table. I'll tell you if anything changes.", "Vigilando la mesa. Te aviso si algo cambia."))
        watching = true
        watchTask = Task { @MainActor [weak self] in
            var firstLook = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                if watchPaused { continue }
                guard tuning.watchMode else { return stopWatching(saying: true) }  // switched off in Settings
                // No scan yet: the first look that gets used just learns the table.
                if await watchOnce(learnOnly: firstLook && sceneBoxes.isEmpty) { firstLook = false }
            }
        }
    }

    @MainActor
    func stopWatching(saying: Bool) {
        guard let watchTask else { return }
        watchTask.cancel()
        self.watchTask = nil
        watching = false
        if saying { audio.say(t("Stopped watching.", "Dejé de vigilar.")) }
    }

    /// One look. True if it was compared with the pins; false if it never was (no photo, a shaky pose, Gemini failed,
    /// or stopped or busy meanwhile), so a first look that didn't happen still leaves the next one to learn the table.
    @MainActor
    private func watchOnce(learnOnly: Bool) async -> Bool {
        // Relocalizing or a fast move: pins from this photo would be off, and every object would seem to move.
        guard cameraError == nil, let snapshot = await snapshot(), Self.steady(snapshot.geometry.camera) else { return false }
        let spanish = tuning.spanish
        let found: [ObjectLocator.Found]
        do {
            found = try await locator.scan(snapshot.jpeg, model: Self.watchModel, spanish: spanish, retry: false)
            watchFailures = 0
        } catch {
            guard !Task.isCancelled else { return false }  // stopped by a find, "stop watching" or a restart: not a Gemini failure
            watchFailures += 1
            print("Watch: \(error.localizedDescription)")
            if watchFailures >= 3 {
                stopWatching(saying: false)
                geminiFailed(t("I couldn't reach Gemini, so I stopped watching.", "No pude conectar con Gemini, así que dejé de vigilar."), error)
            }
            return false
        }
        guard watchTask != nil, tuning.watchMode, !Task.isCancelled, !watchPaused else { return false }  // busy or switched off now
        let lines: [String] = await withCheckedContinuation { continuation in
            camera.frameQueue.async {
                let sightings = found.compactMap { object in
                    ObjectAnchor(box: object.box, seenIn: snapshot.geometry, session: self.camera.session).map { (object.label, $0) }
                }
                continuation.resume(returning: self.applyWatch(sightings, camera: snapshot.geometry.camera, learnOnly: learnOnly, spanish: spanish))
            }
        }
        if !lines.isEmpty { audio.say(lines.joined(separator: " ")) }
        return true
    }

    /// Compares a fresh look with the scene pins, updates them, and returns what to say. A new object counts once it's
    /// seen twice in the same spot; a pin counts as gone once it's in view and missed twice. Frame queue only.
    private func applyWatch(_ sightings: [(label: String, anchor: ObjectAnchor)], camera: ARCamera, learnOnly: Bool,
                            spanish: Bool) -> [String] {
        if learnOnly {
            scene = sightings.sorted { $0.anchor.center.x < $1.anchor.center.x }
            scene.forEach { recordSighting($0.label, $0.anchor) }  // as a scan does, for "where are my keys?"
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
        var rest: [(label: String, anchor: ObjectAnchor)] = []
        for sighting in sightings {  // everything still there first, so a newcomer can't claim an unchanged pin as moved
            let open = scene.indices.filter { !seen.contains($0) }
            if let same = open.min(by: { distance(scene[$0].anchor, sighting.anchor) < distance(scene[$1].anchor, sighting.anchor) }),
               distance(scene[same].anchor, sighting.anchor) < 0.06 {
                seen.insert(same)  // still there
                recordSighting(scene[same].label, scene[same].anchor)  // seen just now
            } else {
                rest.append(sighting)
            }
        }
        var candidates: [(label: String, anchor: ObjectAnchor)] = []
        for sighting in rest {
            let open = scene.indices.filter { !seen.contains($0) }
            if let moved = open.first(where: { Self.matches(scene[$0].label, sighting.label)
                                               && distance(scene[$0].anchor, sighting.anchor) < 0.6 }) {
                seen.insert(moved)
                scene[moved].anchor = sighting.anchor
                recordSighting(scene[moved].label, sighting.anchor)
                let side = Self.side(of: sighting.anchor, from: camera, spanish: spanish)
                let verb = Self.pluralES(scene[moved].label) ? "se movieron" : "se movió"
                lines.append(spanish ? "\(Self.capitalized(scene[moved].label)) \(verb) \(side)."
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
                lines.append(spanish ? "Ya no \(Self.pluralES(pin.label) ? "están" : "está"): \(pin.label)." : "The \(pin.label) \(plural ? "are" : "is") gone.")
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

    /// Spanish puts the noun first ("frasco de pastillas", "gafas de sol"), so the first word says one or many.
    private static func pluralES(_ label: String) -> Bool {
        (label.split(separator: " ").first.map(String.init) ?? label).hasSuffix("s")
    }

    // MARK: What's on the table?

    /// Gemini lists every object on the table; each is pinned in 3D and named. Afterwards, "find" goes straight
    /// to a scanned object without asking Gemini again (and, with touch to explore on, touching an object names it).
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
        // Careful: no pins from a shaky photo (relocalizing, a fast move); a find then asks Gemini.
        let pinned = tuning.carefulGuidance && !Self.steady(snapshot.geometry.camera) ? [] : objects
        camera.frameQueue.async {
            self.scene = pinned.compactMap { object in
                ObjectAnchor(box: object.box, seenIn: snapshot.geometry, session: self.camera.session).map { (object.label, $0) }
            }
            self.scene.forEach { self.recordSighting($0.label, $0.anchor) }
            self.touching = nil
            self.watchMisses = []
        }
        boxesShownAt = Date()
        audio.say(Self.summary(objects.map(\.label), spanish: tuning.spanish))
        // So touch-to-explore names and obstacle warnings play instantly.
        let touchNames = tuning.touchToExplore ? objects.map { Self.touchName($0.label) } : []
        let obstacles = tuning.obstacleWarning ? objects.map { Self.obstaclePhrase($0.label, spanish: tuning.spanish) } : []
        audio.prefetch(touchNames + obstacles)
    }

    /// "I see 4 things: keys, blue mug, phone and pill bottle."
    private static func summary(_ labels: [String], spanish: Bool) -> String {
        switch labels.count {
        case 0: return spanish ? "No veo nada en la mesa." : "I don't see anything on the table."
        case 1: return spanish ? "Veo \(labels[0])." : "I see \(labels[0])."
        default:
            let list = labels.dropLast().joined(separator: ", ")
            return spanish ? "Veo \(labels.count) cosas: \(list) y \(labels.last!)."
                           : "I see \(labels.count) things: \(list) and \(labels.last!)."
        }
    }

    /// What's said when the fingertip lands on a scanned object: "Blue mug."
    private static func touchName(_ label: String) -> String {
        label.prefix(1).uppercased() + label.dropFirst() + "."
    }

    /// "keys" finds "car keys", "mug" finds "blue mug", "glasses" finds "reading glasses": whole words, plural or not,
    /// case and accents ignored ("teléfono" is "telefono"). "Pill bottle" isn't "water bottle", "phone" isn't "headphones".
    static func matches(_ label: String, _ query: String) -> Bool {
        let words = { (text: String) -> Set<String> in
            Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split { !$0.isLetter && !$0.isNumber }
                .map { $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : String($0) })
        }
        let label = words(label), query = words(query)
        return !label.isEmpty && !query.isEmpty && (query.isSubset(of: label) || label.isSubset(of: query))
    }

    /// A pinned object matching `query`: from the last scan, or (with `sightings: true`) the last place Reach saw one.
    @MainActor
    private func scannedObject(matching query: String,
                               sightings useSightings: Bool = false) async -> (label: String, anchor: ObjectAnchor)? {
        return await withCheckedContinuation { continuation in
            camera.frameQueue.async {
                if let scanned = self.scene.first(where: { Self.matches($0.label, query) }) {
                    return continuation.resume(returning: scanned)
                }
                // The newest one, unless a reach there has ended (it may be in the user's hand): never an older one instead.
                let last = useSightings ? self.sightings.filter { Self.matches($0.value.label, query) }.max { $0.value.time < $1.value.time } : nil
                let seen = last.flatMap { self.unlockedEnds.contains($0.key) ? nil : $0.value }
                continuation.resume(returning: seen.map { ($0.label, $0.anchor) })
            }
        }
    }

    /// Drops the scan pin at a grabbed object's spot (within 6 cm), so the next find asks Gemini. Its sighting stays
    /// for "where are my keys?", marked so a find doesn't fall back to it (or past it, to an older one).
    /// Frame queue only.
    private func forgetPins(at grabbed: ObjectAnchor) {
        let here = { (pin: ObjectAnchor) in
            simd_distance(simd_float2(pin.center.x, pin.center.z), simd_float2(grabbed.center.x, grabbed.center.z)) < 0.06
        }
        let count = scene.count
        scene.removeAll { here($0.anchor) }
        unlockedEnds.formUnion(sightings.filter { here($0.value.anchor) }.keys)
        if scene.count != count {
            touching = nil  // indexes into scene
            watchMisses = []  // aligned with scene
        }
    }

    /// A reach that ends without a lock (stopped, or replaced by a new target) may still have ended with it in the
    /// user's hand: forget its pins as a lock does, so the next find asks Gemini, but keep where it was for "where are my
    /// keys?". Frame queue only.
    private func forgetUnlockedTarget() {
        guard let anchor, guide.state == .guiding || guide.state == .lost else { return }
        forgetPins(at: anchor)
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
                guard let latest = self.sightings.filter({ Self.matches($0.value.label, item) }).max(by: { $0.value.time < $1.value.time }) else {
                    return continuation.resume(returning: spanish ? "Todavía no he visto \(item). Di encuentra \(item) y lo busco."
                                                                  : "I haven't seen \(item) yet. Say find \(item) and I'll look.")
                }
                let seen = latest.value
                let side = self.lastCamera.map { Self.side(of: seen.anchor, from: $0, spanish: spanish) } ?? (spanish ? "cerca" : "nearby")
                let ago = Self.timeAgo(Date().timeIntervalSinceReferenceDate - seen.time, spanish: spanish)
                let plural = spanish ? Self.pluralES(seen.label) : seen.label.hasSuffix("s") && !seen.label.hasSuffix("ss")
                // A reach there has ended: a find won't go back (they may be in hand), so promise a look, not a trip.
                let tail = self.unlockedEnds.contains(latest.key)
                    ? (spanish ? "Di encuentra \(item) y lo busco." : "Say find \(item) and I'll look.")
                    : (spanish ? "Di encuentra \(item) y te llevo." : "Say find \(item) and I'll take you there.")
                continuation.resume(returning: spanish
                    ? "\(plural ? "Tus" : "Tu") \(seen.label) \(plural ? "estaban" : "estaba") \(side), \(ago). \(tail)"
                    : "Your \(seen.label) \(plural ? "were" : "was") \(side), \(ago). \(tail)")
            }
        }
        audio.say(answer)
    }

    /// Frame queue only. Wall clock, which keeps counting while the phone sleeps, so "how long ago" stays true.
    private func recordSighting(_ label: String, _ pinned: ObjectAnchor) {
        sightings[label.lowercased()] = (label, pinned, Date().timeIntervalSinceReferenceDate)
        unlockedEnds.remove(label.lowercased())  // a fresh look: a find may go back here again
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
        findID += 1
        let id = findID
        targetLabel = query
        camera.frameQueue.async { self.forgetUnlockedTarget() }  // the reach it replaces
        if tuning.spanish && tuning.carefulGuidance { audio.prefetch(["Baja.", "Listo."]) }  // no bundled Spanish clips
        let ownOne = tuning.myObjects && MyObjects.reference(for: query) != nil  // their own one: ask Gemini, with its photo
        if !ownOne, let scanned = await scannedObject(matching: query) {  // already pinned by a scan: no Gemini round trip
            guard findID == id, targetLabel == query else { return }  // stopped or replaced meanwhile
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
            result = try await stillLooking(while: { self.findID == id && self.targetLabel == query }) {
                try await locate(query)
            }
        } catch {
            print("Locate: \(error.localizedDescription)")
            guard findID == id, targetLabel == query else { return }  // stopped or replaced while we waited: say nothing
            stop()
            if error is CameraNotReady { cameraNotReady() } else { geminiFailed(t("I couldn't reach Gemini.", "No pude conectar con Gemini."), error) }
            return
        }
        guard findID == id, targetLabel == query else { return }  // stopped or replaced while we waited
        guard let result else {
            // Not in view now: with "where did I leave" on, go to where it was last seen. Not for their own one: a
            // sighting isn't checked against its photo.
            let seen = tuning.whereDidILeave && !ownOne ? await scannedObject(matching: query, sightings: true) : nil
            guard findID == id, targetLabel == query else { return }  // stopped or replaced meanwhile
            if let seen {
                targetLabel = seen.label
                camera.frameQueue.async { self.startGuiding(to: seen.anchor, pendingBox: nil, announcing: seen.label) }
                startFollowing()
                return
            }
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
        camera.frameQueue.async { self.forgetUnlockedTarget() }  // the reach it replaces
        pin(box, seenIn: nil)
    }

    @MainActor
    func stop() {
        stopWatching(saying: true)  // a watch gives no sonar: say it ended (silent when none was running)
        followTask?.cancel()
        targetLabel = nil
        camera.frameQueue.async {
            self.forgetUnlockedTarget()
            self.clearTarget()
            self.guide.stop()
            self.audio.setTone(.silent)
        }
    }

    /// Pins `box` to the table using the frame that saw it (nil = the next frame).
    private func pin(_ box: CGRect, seenIn seen: FrameGeometry?, announcing label: String? = nil) {
        camera.frameQueue.async {
            let pinned = seen.flatMap { ObjectAnchor(box: box, seenIn: $0, session: self.camera.session) }
            if let pinned, let label { self.recordSighting(label, pinned) }  // a fresh look, not a re-used pin
            self.startGuiding(to: pinned, pendingBox: pinned == nil ? box : nil, announcing: label)
        }
    }

    /// Starts guiding to a pinned object (or a box still waiting to be pinned). Frame queue only.
    private func startGuiding(to pinned: ObjectAnchor?, pendingBox: CGRect?, announcing label: String?) {
        anchor = pinned
        self.pendingBox = pendingBox
        pendingAnnouncement = label
        pendingAnnouncementSince = CACurrentMediaTime()  // same clock as frame timestamps
        smoothedGap = nil
        hovering = false
        followCandidate = nil
        focusLocked = false  // refocus on the new target with the next frame
        guidingSince = CACurrentMediaTime()
        obstacleWarned = false
        pendingHintSaid = false
        hintAfter = label == nil ? 4 : 6  // slow live speech says "Found keys." at 4 s; a tap announces nothing
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
        let tip = fingertip  // the hand in the photo about to be taken (the next frame)
        guard let result = try? await locate(label), targetLabel == label, state == .lost || state == .guiding else { return }
        guard tuning.carefulGuidance else { return pin(result.found.box, seenIn: result.geometry) }
        // Careful: as when following, not from a photo with the hand on or near it (LiDAR would read the hand as its
        // top). And it's the same reach, so only the pin moves: the dwell, "Down.", the reach timer and the obstacle
        // warning carry on, and a lock that landed since the check above stays locked.
        let box = result.found.box
        if let tip, box.insetBy(dx: -box.width * 0.5, dy: -box.height * 0.5).contains(tip) { return }
        camera.frameQueue.async {
            guard self.guide.state == .guiding || self.guide.state == .lost,
                  let pinned = ObjectAnchor(box: box, seenIn: result.geometry, session: self.camera.session) else { return }
            // As when following, the scan's pin and the sighting move too, so a lock forgets them, not the old spot.
            if let current = self.anchor,
               let i = self.scene.firstIndex(where: { simd_distance($0.anchor.center, current.center) < 0.03 }) {
                self.scene[i].anchor = pinned
            }
            self.recordSighting(label, pinned)
            self.anchor = pinned
            self.pendingBox = nil  // a fresher pin than the box still waiting for the table
            self.smoothedGap = nil  // a new top height
        }
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

    /// A Gemini call failed. With the network-failure path: say what actually went wrong (offline, too slow, busy, or
    /// Gemini itself) plus a way forward, and show the error on screen. Otherwise `old`, as before.
    @MainActor
    private func geminiFailed(_ old: String, _ error: Error) {
        guard tuning.networkFallback else { return audio.say(old) }
        showError(error.localizedDescription)
        // VoiceOver keeps touches on the camera card (TouchSurface is hidden from it), so don't offer the tap there.
        if UIAccessibility.isVoiceOverRunning { return audio.say(old + " " + t("Try again in a moment.", "Intenta de nuevo en un momento.")) }
        let code = (error as? URLError)?.code
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                                        .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff]
        if let code, offline.contains(code) {
            audio.say(t(Self.offline, "No puedo conectarme a internet. Toca el objeto en la pantalla y te guío."))
        } else if code == .timedOut {
            audio.say(t("Gemini is taking too long. Tap the object on screen and I'll guide you.",
                        "Gemini está tardando demasiado. Toca el objeto en la pantalla y te guío."))
        } else if (error as? Gemini.GeminiError)?.isBusy == true {
            audio.say(t("Gemini is busy right now. Try again in a moment, or tap the object on screen and I'll guide you.",
                        "Gemini está ocupado ahora. Intenta de nuevo en un momento, o toca el objeto en la pantalla y te guío."))
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

    /// No photo to work with: say so (network-failure path) rather than going quiet. A denied camera points to Settings.
    @MainActor
    private func cameraNotReady() {
        guard tuning.networkFallback else { return }
        if cameraError != nil, [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video)) {
            return audio.say(t("Reach can't use the camera. Turn on Camera for Reach in Settings.",
                               "Reach no puede usar la cámara. Activa la cámara para Reach en Configuración."))
        }
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
        if let change = torch.update(light: frame.lightEstimate?.ambientIntensity, enabled: tuning.autoTorch, time: time),
           !camera.setTorch(change), change {
            torch = AutoTorch()  // couldn't turn it on (phone too hot): try again after another dark second
        }
        let torchOn = torch.isOn
        hands.restCutoff = tuning.restCutoff
        hands.speedResponse = tuning.speedResponse
        hands.careful = tuning.carefulGuidance
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
        let handAge = finger == nil ? TimeInterval.infinity : time - hands.lastSeen  // 0 = Vision saw it this frame
        var input = guideInput(geometry: geometry, finger: finger, box: box, trackingLost: trackingNote != nil,
                               careful: tuning.carefulGuidance, handAge: handAge)
        input?.trackAge = time - hands.trackedSince
        switch frame.camera.trackingState {
        case .normal, .limited(.insufficientFeatures): break  // a plain table mustn't block every lock
        default: input?.poseShaky = true
        }
        let output = guide.update(input, time: time, tuning: tuning)
        audio.setTone(output.tone)
        if output.event == .locked {
            audio.ding()
            camera.lockFocus(at: nil)
            focusLocked = false
            if let anchor { forgetPins(at: anchor) }  // it's in the user's hand now: the next find asks Gemini
        }
        var announcement: String?
        if let label = pendingAnnouncement {
            if var said = input {
                // Careful: "Found keys, to your right" from the body, not from whatever hand happens to be in view.
                if tuning.carefulGuidance, let body = bodyOffset(geometry) { (said.right, said.forward) = body }
                announcement = Guide.announcement(label, said, spanish: tuning.spanish)
                pendingAnnouncement = nil
            } else if time - pendingAnnouncementSince > 1.5 {  // ARKit hasn't pinned it yet: don't stay silent
                announcement = tuning.spanish ? "Encontré \(label)." : "Found \(label)."
                pendingAnnouncement = nil
            }
        }
        var pendingHint: String?
        if tuning.networkFallback, pendingBox != nil, !pendingHintSaid, pendingAnnouncement == nil, announcement == nil,
           guide.state == .guiding, time - guidingSince > hintAfter {  // ARKit still can't place the table: say why it's quiet
            pendingHintSaid = true
            pendingHint = tuning.spanish ? "Todavía no puedo ubicarlo. Mueve el teléfono un poco."
                                         : "I can't place it yet. Move the phone a little."
        }

        // Touch-to-explore, when not guiding somewhere.
        var touchedName: String?
        if tuning.touchToExplore, !scene.isEmpty, guide.state == .idle || guide.state == .locked, let finger {
            touchedName = touchedObject(finger, geometry: geometry, time: time)
        } else {
            touching = nil
        }
        let sceneBoxes = scene.compactMap { object in object.anchor.box(in: frame.camera).map { LabeledBox(label: object.label, box: $0) } }
        let touchedLabel = touching.map { scene[$0].label }

        let reachTime = output.event == .locked ? time - guidingSince : nil
        let lockNote = output.event == .locked ? guide.lockNote : nil
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
            if let lockNote { self.lockNote = lockNote }
            if let touchedName, !self.isListening {
                self.audio.say(touchedName)
            }
            if let pendingHint, !self.isListening { self.audio.say(pendingHint) }
            if let obstacleWarning, announcement == nil { self.audio.say(obstacleWarning) }
            // Careful: the reply to what the user just said goes first, then the "Down." (and the lock waiting on it).
            let holdDown = self.isListening || (output.urgent && CACurrentMediaTime() - self.listenEndedAt < 1.5)
            if let announcement {
                self.targetShownAt = Date()
                // Same frame as the warning: say both, or the announcement cuts the warning off.
                self.audio.say(obstacleWarning.map { "\(announcement) \($0)" } ?? announcement)
            } else if let cue = output.cue, !holdDown {  // don't talk over the user
                // Careful: the "Down." the lock waits on cuts in (the hand is over the object, so a direction still
                // playing is stale), so the wait after it starts from a "Down." that was really said.
                if output.urgent { self.audio.say(cue) } else { self.audio.cue(cue) }
            }
            if output.urgent, announcement != nil || holdDown {
                self.camera.frameQueue.async { self.guide.forgetDown() }  // not said: say it again
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
        let targetHalf = target.halfExtents(right: axes.right, forward: axes.forward)
        var first: (along: Float, label: String)?
        for object in scene {
            let center = simd_float2(object.anchor.center.x, object.anchor.center.z)
            let half = object.anchor.halfExtents(right: axes.right, forward: axes.forward)
            // The target itself, or another pin of it (the scan's vs. Gemini's, or from before a re-pin): two separate
            // objects can't stand closer than their half-widths added up. The smaller ones: a tall box casts long.
            let same = max(0.03, Float(min(targetHalf.right, targetHalf.forward) + min(half.right, half.forward)))
            guard simd_distance(center, end) > same else { continue }
            let along = simd_dot(center - start, path) / (length * length)
            guard along > 0.05, along < 0.95 else { continue }  // between the hand and the target
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
        var handY = tableY
        if let anchor, guide.state != .idle {
            marks.append(Minimap.Mark(label: "", at: place(anchor.center), isTarget: true))
            handY = anchor.topY  // where the guide casts the fingertip
        }
        let hand = finger.flatMap { geometry.point(at: $0.tip, onPlaneAt: handY) }
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
                            trackingLost: Bool, careful: Bool, handAge: TimeInterval) -> Guide.Input? {
        guard var pinned = anchor, let axes = geometry.axes(onPlaneAt: pinned.tableY) else { return nil }

        // Refine the object's height from LiDAR (its top inside the box) while the hand is nowhere near it.
        if let box, finger.map({ !box.insetBy(dx: -box.width, dy: -box.height).contains($0.tip) }) ?? true,
           let top = geometry.topPoint(in: box) {
            pinned.topY = min(max(pinned.topY + (top.y - pinned.topY) * 0.2, pinned.tableY), pinned.tableY + 0.4)
            // Careful: whatever is over the object (an arm, a hand Vision missed, a judge) reads higher, never lower.
            if careful, let measured = pinned.measuredTopY { pinned.topY = min(pinned.topY, measured + 0.005) }
            anchor = pinned
        }

        // The hand: where the fingertip's line of sight meets the object's height. Steady, unlike finger depth.
        let hand = finger.flatMap { geometry.point(at: $0.tip, onPlaneAt: pinned.topY) }
        // Careful: LiDAR only when Vision saw the finger this frame; a held finger's pixels show whatever is there now.
        touchNow = false
        let fresh = !careful || handAge == 0
        let hoveringNow = fresh ? finger.flatMap { isHovering(over: pinned.topY, finger: $0, geometry: geometry) } : nil
        guard let from = hand ?? geometry.point(at: CGPoint(x: 0.5, y: 1), onPlaneAt: pinned.tableY) else { return nil }

        let toObject = pinned.center - from
        let half = pinned.halfExtents(right: axes.right, forward: axes.forward)
        return Guide.Input(right: Double(simd_dot(toObject, axes.right)), forward: Double(simd_dot(toObject, axes.forward)),
                           hovering: hoveringNow, halfRight: half.right, halfForward: half.forward,
                           hasHand: finger != nil, trackingLost: trackingLost, handAge: handAge, touch: careful && touchNow)
    }

    /// The object relative to the user's body (the bottom middle of the frame), on the table. Frame queue only.
    private func bodyOffset(_ geometry: FrameGeometry) -> (right: Double, forward: Double)? {
        guard let anchor, let axes = geometry.axes(onPlaneAt: anchor.tableY),
              let body = geometry.point(at: CGPoint(x: 0.5, y: 1), onPlaneAt: anchor.tableY) else { return nil }
        let toObject = anchor.center - body
        return (Double(simd_dot(toObject, axes.right)), Double(simd_dot(toObject, axes.forward)))
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
        // Careful guidance: the finger right at the object's top (its back ~1.5-2.5 cm up). In height, not depth along
        // the camera axis, which stretches with the viewing angle: along one line of sight, height = gap * (camera
        // height above the top) / depth.
        let height = gap * Double(geometry.camera.transform.columns.3.y - topY) / Double(surfaceDepth)
        touchNow = !hovering && (0.005...0.035).contains(height)  // ~0 is LiDAR missing the finger and seeing the top
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

    /// Whether a photo's pose can be trusted to pin from (a plain table's insufficientFeatures is fine, as for locks).
    private static func steady(_ camera: ARCamera) -> Bool {
        switch camera.trackingState {
        case .normal, .limited(.insufficientFeatures): true
        default: false
        }
    }
}
