import Foundation

/// Guidance in real distances on the table. A coach speaks short instructions ("Right, 6 inches") while the
/// hand is off target; a sonar ticks in between (panned toward the object, faster as the hand closes in, a solid
/// tone once the hand is right over it); touching the object for a moment locks it. Runs on the frame queue.
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
    static let cueEvery: TimeInterval = 1.6

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
            output.cue = cue(input, outRight: outRight, outForward: outForward, over: over, toGoDown: toGoDown, time: time)
        }
        return output
    }

    /// Which way to move and how far ("Out and right, 8 inches."), or "Lower, …" once right over the object.
    /// At most every `cueEvery` seconds (sooner when the direction changes), never the same words twice within 4 s.
    private func cue(_ input: Input, outRight: Double, outForward: Double, over: Bool, toGoDown: Double,
                     time: TimeInterval) -> String? {
        let text: String
        if !input.hasHand {
            handMissingSince = handMissingSince ?? time
            guard time - handMissingSince! > 3 else { return nil }
            text = "I can't see your hand."
        } else {
            handMissingSince = nil
            if over {
                guard toGoDown > 0, let above = input.above else { return nil }
                text = Self.phrase(Self.lower, above)
            } else {
                text = Self.phrase(Self.directions[steadySector(input)], hypot(input.right, input.forward))
            }
        }
        if let lastCue {
            let gap = time - lastCue.time
            let sameDirection = lastCue.text.prefix(while: { $0 != "," }) == text.prefix(while: { $0 != "," })
            guard gap >= (sameDirection ? Self.cueEvery : 0.8), text != lastCue.text || gap >= 4 else { return nil }
        }
        lastCue = (text, time)
        return text
    }

    /// "Found keys: out and to the right, 14 inches."
    static func announcement(_ label: String, _ input: Input) -> String {
        let distance = hypot(input.right, input.forward)
        guard distance >= 0.05 else { return "Found \(label), right in front of you." }
        let way = ["straight out", "out and to the right", "to the right", "in and to the right",
                   "straight in", "in and to the left", "to the left", "out and to the left"][sector(input)]
        return "Found \(label): \(way), \(inches(distance))."
    }

    /// Eight ways to move, clockwise from straight out (away from the body). "In" is toward the body.
    static let directions = ["Straight out", "Out and right", "Right", "In and right",
                             "Straight in", "In and left", "Left", "Out and left"]
    static let lower = "Lower"
    /// Spoken distances snap to these, so every instruction has a pre-made clip (scripts/make_clips.py).
    static let inchSteps = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18, 24, 30, 36]

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

    /// "Out and right, 6 inches."
    static func phrase(_ direction: String, _ meters: Double) -> String {
        "\(direction), \(inches(meters))."
    }

    static func inches(_ meters: Double) -> String {
        let value = meters / 0.0254
        let step = inchSteps.min { abs(Double($0) - value) < abs(Double($1) - value) }!
        return step == 1 ? "1 inch" : "\(step) inches"
    }
}
