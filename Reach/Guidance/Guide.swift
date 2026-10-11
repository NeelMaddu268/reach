import Foundation

/// Guidance on the table. A coach says which way to move about every 1.5 s ("Farther and right." … "A little left."),
/// with soft pings between (on the object's side, faster as the hand closes in, a gentle hum once it's right over
/// it), and "Down." if it's hovering. Touching the object for a moment locks it. Runs on the frame queue.
final class Guide {
    enum State: String { case idle, locating, guiding, lost, locked }
    enum Event { case locked, lost, found }

    /// Where the object is relative to the fingertip (or to the user's body when no hand is in view).
    struct Input {
        /// Object center minus hand, in meters along the user's right and forward on the table.
        var right: Double
        var forward: Double
        /// LiDAR says the fingertip is clearly in front of the object along the line of sight (hovering above it);
        /// nil when the reading isn't trustworthy. Only ever blocks a lock: no reading never does.
        var hovering: Bool?
        /// Half the object's footprint (meters) along right / forward.
        var halfRight: Double
        var halfForward: Double
        var hasHand: Bool
        /// ARKit tracking is degraded, so positions may be off.
        var trackingLost: Bool
        /// Careful guidance: seconds since Vision last saw the hand (0 = this frame; more while a lost hand is held).
        var handAge: TimeInterval = 0
        /// Seconds since this hand track began.
        var trackAge: TimeInterval = .infinity
        /// LiDAR read the fingertip right at the object's top this frame.
        var touch = false
        /// ARKit's pose may be jumping (excessive motion, relocalizing, initializing). A featureless table doesn't count.
        var poseShaky = false
    }

    struct Output {
        var tone = AudioGuide.Tone.silent
        var event: Event?
        /// A short instruction to say now, if nothing else is being said.
        var cue: String?
    }

    /// Tracking must stay degraded this long before the state changes to `.lost`.
    static let lostAfter: TimeInterval = 1
    /// Distance (meters) at which the sonar is at its slowest and lowest.
    static let maxDistance = 0.5
    /// Smallest lock half-size (meters), so small objects stay reachable.
    static let minLockHalf = 0.03
    /// How often the coach speaks (sooner when the direction changes).
    static let cueEvery: TimeInterval = 1.5
    /// Within this distance of the object (meters), directions get "A little …".
    static let littleWithin = 0.08
    /// Careful guidance without LiDAR confirmation: how long after "Down." a still finger on the object locks
    /// (the clip, a reaction, and a lowering hand's descent fit inside it).
    static let waitAfterDown: TimeInterval = 1.8

    private(set) var state = State.idle
    private var insideSince: TimeInterval?
    private var lostSince: TimeInterval?
    private var handMissingSince: TimeInterval?
    private var lastCue: (text: String, time: TimeInterval)?
    private var lastSector: Int?
    // Careful guidance: where the hand was when the dwell began, LiDAR readings and touch readings since, when "Down."
    // was said for it, and how long the current instruction has held.
    private var dwellFrom: (right: Double, forward: Double)?
    private var readings = 0
    private var touches = 0
    private var downAt: TimeInterval?
    private var pendingCue: (text: String, since: TimeInterval)?
    /// How the last lock happened ("lidar 0.6 s"), for the stats line.
    private(set) var lockNote = ""

    func start() {
        state = .guiding
        insideSince = nil
        lostSince = nil
        handMissingSince = nil
        lastCue = nil
        lastSector = nil
        dwellFrom = nil
        readings = 0
        touches = 0
        downAt = nil
        pendingCue = nil
    }

    /// Waiting for Gemini to find the object.
    func beginLocating() {
        state = .locating
    }

    /// The last "Down." wasn't said (the user was talking, or an announcement took its place): say it again next frame,
    /// and don't start the wait after it until it is.
    func forgetDown() {
        downAt = nil
        lastCue = nil
    }

    static func isDown(_ cue: String) -> Bool {
        cue == down + "." || cue == downES + "."
    }

    func stop() {
        state = .idle
    }

    func update(_ input: Input?, time: TimeInterval, tuning: Tuning) -> Output {
        guard state == .guiding || state == .lost, let input else {
            if tuning.carefulGuidance { insideSince = nil }  // a lock needs an unbroken dwell
            return Output()
        }
        var output = Output()

        if input.trackingLost {
            lostSince = lostSince ?? time
            if state == .guiding, time - lostSince! > Self.lostAfter {
                state = .lost
                output.event = .lost
            }
        } else {
            lostSince = nil
            if state == .lost {
                state = .guiding
                output.event = .found
            }
        }

        // The lock zone: the footprint grown (or shrunk) by the margin on each side.
        let zoneRight = max(input.halfRight * (1 + 2 * tuning.lockMargin), Self.minLockHalf)
        let zoneForward = max(input.halfForward * (1 + 2 * tuning.lockMargin), Self.minLockHalf)
        let outRight = max(abs(input.right) - zoneRight, 0)
        let outForward = max(abs(input.forward) - zoneForward, 0)
        let over = outRight == 0 && outForward == 0
        let hovering = over && input.hovering == true
        let toGoDown = hovering ? 0.05 : 0.0  // keeps the sonar just short of "there" until the finger comes down

        var unconfirmed = false
        if tuning.carefulGuidance {
            // On it: Vision saw the hand in the last 0.3 s, it's inside the zone (1 cm slack once a dwell is under way, so
            // the tip flickering over the edge doesn't restart it), LiDAR doesn't say it's hovering, and ARKit is steady.
            let slack = insideSince == nil ? 0 : 0.01
            let onIt = input.hasHand && input.handAge <= 0.6 && input.hovering != true && !input.poseShaky
                && abs(input.right) <= zoneRight + slack && abs(input.forward) <= zoneForward + slack
            let moved = dwellFrom.map { hypot(input.right - $0.right, input.forward - $0.forward) > 0.04 } ?? true
            // "Down." counts once per arrival: a re-tap or a lowering hand restarts the dwell but not the wait after it.
            let near = abs(input.right) <= zoneRight + 0.1 && abs(input.forward) <= zoneForward + 0.1
            if !input.hasHand || !near { downAt = nil }
            if !onIt {
                insideSince = nil
            } else if insideSince == nil || moved {  // start over wherever it settles: a sweep or a jump never locks
                insideSince = time
                dwellFrom = (input.right, input.forward)
                readings = 0
                touches = 0
            }
            if let since = insideSince {
                if input.hovering != nil { readings += 1 }
                if input.touch { touches += 1 }
                // LiDAR mostly reads the fingertip right at the object's top (a low hover reads that only now and then).
                let confirmed = touches >= 3 && touches * 2 >= readings
                // Without that, "Down." is said at 0.6 s; a hovering hand moves when it hears it, a touching one stays.
                let waited = tuning.spokenCues ? downAt.map { time - $0 >= Self.waitAfterDown } == true
                                               : time - since >= tuning.lockDwell * 4
                // Still 0.6 s with LiDAR confirming (at the default 0.4 s hold), or still 1.8 s after "Down." without;
                // only on a frame where Vision saw the hand, inside the zone itself (the slack only keeps the dwell).
                if input.handAge == 0, over, time - since >= tuning.lockDwell * 1.5, confirmed || waited {
                    lockNote = String(format: "%@ %.1f s", confirmed ? "lidar" : "no lidar", time - since)
                    state = .locked
                    output.event = .locked
                    return output
                }
                unconfirmed = !confirmed && time - since >= tuning.lockDwell * 1.5
            }
        } else if input.hasHand && over && !hovering {
            insideSince = insideSince ?? time
            if time - insideSince! >= tuning.lockDwell {
                lockNote = String(format: "basic %.1f s", time - insideSince!)
                state = .locked
                output.event = .locked
                return output
            }
        } else {
            insideSince = nil
        }

        // Sonar.
        let closeness = 1 - min((outRight * outRight + outForward * outForward + toGoDown * toGoDown).squareRoot() / Self.maxDistance, 1)
        let side = pow(min(abs(input.right) / tuning.panRange, 1), tuning.panCurve)
        output.tone = AudioGuide.Tone(
            frequency: tuning.pingLow * pow(tuning.pingHigh / tuning.pingLow, closeness),
            pan: over ? 0 : (input.right < 0 ? -side : side),
            beepPeriod: over ? 0 : 0.6 - 0.48 * closeness,  // pings speed up 0.6 s → 0.12 s; a hum when over it
            volume: input.hasHand ? 1 : 0.35)

        if tuning.spokenCues {
            output.cue = cue(input, over: over, hovering: hovering, unconfirmed: unconfirmed, outRight: outRight,
                             outForward: outForward, time: time, careful: tuning.carefulGuidance, spanish: tuning.spanish)
        }
        return output
    }

    /// Steady coaching: the way to move about every `cueEvery` seconds until the hand is there, sooner when the
    /// direction changes; "A little …" when close; "Down." while hovering over the object (or, careful, while a
    /// dwell on it has no LiDAR touch readings).
    private func cue(_ input: Input, over: Bool, hovering: Bool, unconfirmed: Bool, outRight: Double, outForward: Double,
                     time: TimeInterval, careful: Bool, spanish: Bool) -> String? {
        let text: String
        if !input.hasHand {
            handMissingSince = handMissingSince ?? time
            guard time - handMissingSince! > 3 else { return nil }
            text = spanish ? "No veo tu mano." : "I can't see your hand."
        } else if careful, input.handAge > 0.1 || input.trackAge < 0.3 {
            return nil  // a held or just-found hand: no new direction until Vision has been seeing it
        } else {
            handMissingSince = nil
            if over {
                // On it: the lock takes over. Without LiDAR, "Down." once per arrival (a hovering hand needs it once;
                // repeating it makes a touching finger lift and tap again).
                guard hovering || (unconfirmed && downAt == nil) else { return nil }
                text = (spanish ? Self.downES : Self.down) + "."
            } else {
                let way = (spanish ? Self.directionsES : Self.directions)[steadySector(input)]
                let little = hypot(outRight, outForward) < Self.littleWithin
                text = (little ? (spanish ? "Un poco " : "A little ") + way.lowercased() : way) + "."
            }
        }
        if careful, pendingCue?.text != text { pendingCue = (text, time) }  // how long this same instruction has held
        if let lastCue {
            let gap = time - lastCue.time
            let every = input.hasHand ? Self.cueEvery : 6
            guard gap >= (text == lastCue.text ? every : 0.8) else { return nil }
            // Careful: a change cuts the wait short only once it has held 0.3 s, so it doesn't flip-flop near the object.
            // ("Down." for a dwell LiDAR can't confirm has already held 0.6 s.)
            if careful, text != lastCue.text, gap < every, !(over && unconfirmed), let pendingCue,
               time - pendingCue.since < 0.3 { return nil }
        }
        lastCue = (text, time)
        if over && unconfirmed { downAt = downAt ?? time }  // the lock waits for a reaction to this
        return text
    }

    /// "Found keys, farther and to your right."
    static func announcement(_ label: String, _ input: Input, spanish: Bool = false) -> String {
        guard hypot(input.right, input.forward) >= 0.05 else {
            return spanish ? "Encontré \(label), justo frente a ti." : "Found \(label), right in front of you."
        }
        let way = spanish
            ? ["justo al frente", "más lejos y a tu derecha", "a tu derecha", "más cerca y a tu derecha",
               "cerca de ti", "más cerca y a tu izquierda", "a tu izquierda", "más lejos y a tu izquierda"][sector(input)]
            : ["straight ahead", "farther and to your right", "to your right", "closer and to your right",
               "close to you", "closer and to your left", "to your left", "farther and to your left"][sector(input)]
        return spanish ? "Encontré \(label), \(way)." : "Found \(label), \(way)."
    }

    /// Eight ways to move the hand, clockwise from straight ahead: "farther" is away from the body, "closer" toward it.
    /// Each, its "A little …" form and `down` have pre-made clips (scripts/make_clips.py).
    static let directions = ["Farther", "Farther and right", "Right", "Closer and right",
                             "Closer", "Closer and left", "Left", "Farther and left"]
    static let down = "Down"
    /// Spanish versions (spoken live by ElevenLabs; no pre-made clips).
    static let directionsES = ["Más lejos", "Más lejos y a la derecha", "Derecha", "Más cerca y a la derecha",
                               "Más cerca", "Más cerca y a la izquierda", "Izquierda", "Más lejos y a la izquierda"]
    static let downES = "Baja"

    /// Index into `directions` for the way from the hand to the object.
    static func sector(_ input: Input) -> Int {
        let degrees = atan2(input.right, input.forward) * 180 / .pi  // 0 = straight out, 90 = right
        return Int((degrees + 360 + 22.5).truncatingRemainder(dividingBy: 360) / 45)
    }

    /// `sector`, but keeps the previous direction until the hand is 10° past the boundary, so wording doesn't flicker.
    private func steadySector(_ input: Input) -> Int {
        var sector = Self.sector(input)
        if let last = lastSector, last != sector {
            let degrees = atan2(input.right, input.forward) * 180 / .pi
            var fromLast = abs(degrees - Double(last) * 45).truncatingRemainder(dividingBy: 360)
            if fromLast > 180 { fromLast = 360 - fromLast }
            if fromLast < 22.5 + 10 { sector = last }
        }
        lastSector = sector
        return sector
    }
}
