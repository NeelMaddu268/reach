import CoreGraphics
import Foundation

/// Guidance state machine and the fingertip → object math. Runs on the camera frame queue.
/// Offsets are in image widths (x and y scaled to the same pixel length); +x = right, +y = away from the body.
final class Guide {
    enum State: String { case idle, locating, guiding, lost, locked }
    enum Event { case locked, lost, found }

    struct Output {
        var tone = AudioGuide.Tone.silent
        var event: Event?
        var lockZone: CGRect?
    }

    /// The tracker must stay lost this long before the state changes to `.lost`.
    static let lostAfter: TimeInterval = 1
    /// Distance (image widths) at which the tone is at its "far" setting.
    static let maxDistance = 0.8
    /// Smallest lock-zone side (image widths), so small objects stay reachable.
    static let minLockSide = 0.08
    static let heightInWidths = Double(1 / ImageSpace.aspect)

    private(set) var state = State.idle
    private var insideSince: TimeInterval?
    private var lostSince: TimeInterval?

    func start() {
        state = .guiding
        insideSince = nil
        lostSince = nil
    }

    /// Waiting for Gemini to find the object.
    func beginLocating() {
        state = .locating
    }

    func stop() {
        state = .idle
    }

    func update(fingertip: CGPoint?, target: ObjectTracker.Target?, time: TimeInterval, tuning: Tuning) -> Output {
        guard state == .guiding || state == .lost, let target else { return Output() }
        var output = Output()
        let zone = Self.lockZone(around: target.box, margin: tuning.lockMargin)
        output.lockZone = zone

        if target.isLost {
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

        // No hand in view: guide from the bottom-center of the frame (the user's body), quietly.
        let offset = Self.offset(from: fingertip ?? CGPoint(x: 0.5, y: 1), to: zone)
        let inside = fingertip != nil && offset.dx == 0 && offset.dy == 0
        if inside {
            insideSince = insideSince ?? time
            if time - insideSince! >= tuning.lockDwell {
                state = .locked
                output.event = .locked
                return output
            }
        } else {
            insideSince = nil
        }

        output.tone = Self.tone(dx: offset.dx, dy: offset.dy, inside: inside, tuning: tuning)
        if fingertip == nil { output.tone.volume = 0.35 }
        return output
    }

    static func lockZone(around box: CGRect, margin: Double) -> CGRect {
        var zone = box.insetBy(dx: -box.width * margin, dy: -box.height * margin)
        let minWidth = minLockSide, minHeight = minLockSide / heightInWidths
        if zone.width < minWidth { zone = zone.insetBy(dx: -(minWidth - zone.width) / 2, dy: 0) }
        if zone.height < minHeight { zone = zone.insetBy(dx: 0, dy: -(minHeight - zone.height) / 2) }
        return zone
    }

    /// From `point` to the nearest point of `zone`, in image widths. Zero when inside.
    static func offset(from point: CGPoint, to zone: CGRect) -> (dx: Double, dy: Double) {
        let dx = point.x < zone.minX ? zone.minX - point.x : (point.x > zone.maxX ? zone.maxX - point.x : 0)
        let dy = point.y < zone.minY ? zone.minY - point.y : (point.y > zone.maxY ? zone.maxY - point.y : 0)
        return (Double(dx), -Double(dy) * heightInWidths)  // image y grows toward the body
    }

    static func tone(dx: Double, dy: Double, inside: Bool, tuning: Tuning) -> AudioGuide.Tone {
        let closeness = 1 - min(hypot(dx, dy) / maxDistance, 1)
        let side = pow(min(abs(dx) / tuning.panRange, 1), tuning.panCurve)
        return AudioGuide.Tone(
            frequency: tuning.pitchFar * pow(tuning.pitchNear / tuning.pitchFar, closeness),
            pan: dx < 0 ? -side : side,
            beepPeriod: inside ? 0 : 0.55 - 0.45 * closeness,  // parking sensor: 0.55 s far → 0.1 s near → solid
            volume: 1)
    }
}
