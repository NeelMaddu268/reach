import Foundation

/// Guidance on the table. A sonar does most of the work (ticks panned toward the object, faster as the hand
/// closes in, a solid tone once the hand is right over it). Speech only steps in when needed: the hand heads
/// the wrong way or stalls ("Out and right."), or is over the object but not down on it ("Lower."). Touching the
/// object for a moment locks it. Runs on the frame queue.
final class Guide {
    enum State: String { case idle, locating, guiding, lost, locked }
    enum Event { case locked, lost, found }

    /// Where the object is relative to the fingertip (or to the user's body when no hand is in view).
    struct Input {
        /// Object center minus hand, in meters along the user's right and forward on the table.
        var right: Double
        var forward: Double
        /// Fingertip height above the object's top (meters); nil when unknown (no depth reading).
        var above: Double?
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
    /// The fingertip counts as touching within this height above the object's top (meters).
    static let touchHeight = 0.04
    /// Speak up when the hand has made no progress for this long…
    static let stallAfter: TimeInterval = 2
    /// …or has moved this much farther away than its closest recent point (meters).
    static let wrongWayBy = 0.04
    /// Getting this much closer (meters) counts as progress.
    static let progressBy = 0.015

    private(set) var state = State.idle
    private var insideSince: TimeInterval?
    private var lostSince: TimeInterval?
    private var handMissingSince: TimeInterval?
    private var lastCue: (text: String, time: TimeInterval)?
    private var lastSector: Int?
    /// Closest the hand has come recently, and when; reset whenever Reach speaks.
    private var best: (distance: Double, time: TimeInterval)?
    private var overSince: TimeInterval?

    func start() {
        state = .guiding
        insideSince = nil
        lostSince = nil
        handMissingSince = nil
        lastCue = nil
        lastSector = nil
        best = nil
        overSince = nil
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
        let toGoDown = max((input.above ?? 0) - Self.touchHeight, 0)

        if input.hasHand && over && toGoDown == 0 {
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
            frequency: tuning.pitchFar * pow(tuning.pitchNear / tuning.pitchFar, closeness),
            pan: over ? 0 : (input.right < 0 ? -side : side),
            beepPeriod: over ? 0 : 0.6 - 0.5 * closeness,  // ticks speed up 0.6 s → 0.1 s; solid when over it
            volume: input.hasHand ? 1 : 0.35)

        if tuning.spokenCues {
            output.cue = cue(input, over: over, toGoDown: toGoDown, time: time, spanish: tuning.spanish)
        }
        return output
    }

    /// Speaks only when needed: the hand heads the wrong way or stalls, or hovers over the object.
    private func cue(_ input: Input, over: Bool, toGoDown: Double, time: TimeInterval, spanish: Bool) -> String? {
        var text: String?
        if !input.hasHand {
            best = nil
            handMissingSince = handMissingSince ?? time
            if time - handMissingSince! > 3 { text = spanish ? "No veo tu mano." : "I can't see your hand." }
        } else if over {
            handMissingSince = nil
            best = nil
            // Once on arriving over it, then again if the hand stays hovering.
            if toGoDown > 0, overSince == nil || time - lastCueTime >= Self.stallAfter + 0.5 {
                text = (spanish ? Self.lowerES : Self.lower) + "."
            }
            overSince = overSince ?? time
        } else {
            handMissingSince = nil
            overSince = nil
            let distance = hypot(input.right, input.forward)
            if let best, distance > best.distance + Self.wrongWayBy || time - best.time > Self.stallAfter {
                text = (spanish ? Self.directionsES : Self.directions)[steadySector(input)] + "."
            }
            if text != nil || best == nil || distance < best!.distance - Self.progressBy {
                best = (distance, time)
            }
        }
        guard let text else { return nil }
        // Never back to back, and the same words at most every 4 s ("I can't see your hand." every 6 s).
        if let lastCue {
            let gap = time - lastCue.time
            guard gap >= 1.2, text != lastCue.text || gap >= (input.hasHand ? 4 : 6) else { return nil }
        }
        lastCue = (text, time)
        return text
    }

    private var lastCueTime: TimeInterval { lastCue?.time ?? 0 }

    /// "Found keys, out and to the right."
    static func announcement(_ label: String, _ input: Input, spanish: Bool = false) -> String {
        guard hypot(input.right, input.forward) >= 0.05 else {
            return spanish ? "Encontré \(label), justo frente a ti." : "Found \(label), right in front of you."
        }
        let way = spanish
            ? ["al frente", "al frente y a la derecha", "a la derecha", "hacia ti y a la derecha",
               "hacia ti", "hacia ti y a la izquierda", "a la izquierda", "al frente y a la izquierda"][sector(input)]
            : ["straight out", "out and to the right", "to the right", "in and to the right",
               "straight in", "in and to the left", "to the left", "out and to the left"][sector(input)]
        return spanish ? "Encontré \(label), \(way)." : "Found \(label), \(way)."
    }

    /// Eight ways to move, clockwise from straight out (away from the body). "In" is toward the body.
    /// Each has a pre-made clip ("Out and right.") from scripts/make_clips.py, as does `lower`.
    static let directions = ["Straight out", "Out and right", "Right", "In and right",
                             "Straight in", "In and left", "Left", "Out and left"]
    static let lower = "Lower"
    /// Spanish versions (spoken live by ElevenLabs; no pre-made clips).
    static let directionsES = ["Al frente", "Al frente y a la derecha", "Derecha", "Hacia ti y a la derecha",
                               "Hacia ti", "Hacia ti y a la izquierda", "Izquierda", "Al frente y a la izquierda"]
    static let lowerES = "Baja"

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
