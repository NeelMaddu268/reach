/// The "feel" knobs, adjustable live from the tuning sheet.
struct Tuning: Equatable {
    // Fingertip smoothing (One Euro filter).
    var restCutoff = 2.5        // Hz; lower = steadier dot while the hand is still
    var speedResponse = 15.0    // higher = less lag while the hand moves

    // Pan: fully left/right once the object is this far to the side (fraction of frame width).
    var panRange = 0.35
    var panCurve = 0.6          // < 1 makes small offsets easier to hear

    // Pitch from distance, far → near (Hz). Beeps also speed up as the hand gets closer.
    var pitchFar = 300.0
    var pitchNear = 1100.0

    // Lock: the object box grown by this fraction of its size on each side; hold inside it this long (s).
    var lockMargin = 0.25
    var lockDwell = 0.4
}
