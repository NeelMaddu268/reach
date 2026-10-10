/// The "feel" knobs, adjustable live from the tuning sheet.
struct Tuning: Equatable {
    // Fingertip smoothing (One Euro filter).
    var restCutoff = 2.5        // Hz; lower = steadier dot while the hand is still
    var speedResponse = 15.0    // higher = less lag while the hand moves

    // Sonar pan: fully left/right once the object is this far to the side (meters).
    var panRange = 0.15
    var panCurve = 0.6          // < 1 makes small offsets easier to hear

    // Sonar pitch from closeness, far → near (Hz). Ticks also speed up as the hand gets closer.
    var pitchFar = 300.0
    var pitchNear = 1100.0

    // Lock: the object's footprint grown (or, negative, shrunk) by this fraction of its size on each side;
    // the fingertip must touch inside it this long (s). Gemini's boxes run a little big, hence slightly inside.
    var lockMargin = -0.1
    var lockDwell = 0.4

    /// The coach: "Right, 6 inches", "Down, 3 inches", … Off = sonar only.
    var spokenCues = true

    var geminiModel = "gemini-3.6-flash"
}
