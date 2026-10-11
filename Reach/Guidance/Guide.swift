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

    private(set) var state = State.idle
    private var insideSince: TimeInterval?
    private var lostSince: TimeInterval?
    private var handMissingSince: TimeInterval?
    private var lastCue: (text: String, time: TimeInterval)?
    private var lastSector: Int?

    func start() {
        state = .guiding
        insideSince = nil
        lostSince = nil
        handMissingSince = nil
        lastCue = nil
        lastSector = nil
    }

    /// Waiting for Gemini to find the object.
    func beginLocating() {
        state = .locating
    }

    func stop() {
        state = .idle
    }

    func update(_ input: Input?, time: TimeInterval, tuning: Tuning) -> Output {
        guard state == .guiding || state == .lost, let input else { return Output() }
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

        if input.hasHand && over && !hovering {
            insideSince = insideSince ?? time
            if time - insideSince! >= tuning.lockDwell {
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
            output.cue = cue(input, over: over, hovering: hovering, outRight: outRight, outForward: outForward,
                             time: time, spanish: tuning.spanish)
        }
        return output
    }

    /// Steady coaching: the way to move about every `cueEvery` seconds until the hand is there, sooner when the
    /// direction changes; "A little …" when close; "Down." while hovering over the object.
    private func cue(_ input: Input, over: Bool, hovering: Bool, outRight: Double, outForward: Double,
                     time: TimeInterval, spanish: Bool) -> String? {
        let text: String
        if !input.hasHand {
            handMissingSince = handMissingSince ?? time
            guard time - handMissingSince! > 3 else { return nil }
            text = spanish ? "No veo tu mano." : "I can't see your hand."
        } else {
            handMissingSince = nil
            if over {
                guard hovering else { return nil }  // on it: the lock takes over
                text = (spanish ? Self.downES : Self.down) + "."
            } else {
                let way = (spanish ? Self.directionsES : Self.directions)[steadySector(input)]
                let little = hypot(outRight, outForward) < Self.littleWithin
                text = (little ? (spanish ? "Un poco " : "A little ") + way.lowercased() : way) + "."
            }
        }
        if let lastCue {
            let gap = time - lastCue.time
            let every = input.hasHand ? Self.cueEvery : 6
            guard gap >= (text == lastCue.text ? every : 0.8) else { return nil }
        }
        lastCue = (text, time)
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
