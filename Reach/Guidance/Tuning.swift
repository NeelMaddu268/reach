import Foundation

/// The "feel" knobs and feature switches, adjustable live from the tuning sheet and kept across launches.
struct Tuning: Equatable, Codable {
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

    /// Speak up when the hand heads the wrong way, stalls, or hovers ("Out and right.", "Lower."). Off = sonar only.
    var spokenCues = true

    var geminiModel = "gemini-3.6-flash"
    /// Answers "what's this?" when held-item questions are off.
    var claudeModel = "claude-opus-5-5"

    // Features. With every switch off, find → guide → lock works exactly as it did before they existed.

    /// Questions about a held item ("is this decaf?", "how many do I take?") and "what's this?", answered by Gemini
    /// from the label only, with one follow-up. Off = "what's this?" goes to the Claude reader.
    var askAboutItems = true
    /// Comma-separated. A held item whose printed text mentions one is announced with "Careful, the label says …" first.
    var allergies = "peanuts"
    /// "Reached in 4.8 s" after each lock, and a session tally in the HUD.
    var reachTimer = true
    /// Top-down radar of the table in the corner of the judge view.
    var minimap = false
    /// "Careful, mug in the way." when a scanned object sits on the hand's path to the target (needs a table scan).
    var obstacleWarning = false
    /// "Where are my keys?" answers from where Reach last saw them; off = it starts a find, as before.
    var whereDidILeave = false
    /// "This is my mug" saves a reference photo; "find my mug" then looks for that one.
    var myObjects = false
    /// Flashlight on in a dark room, off when it's bright.
    var autoTorch = false
}

extension Tuning {
    /// Saved values laid over the defaults, so settings survive launches and new knobs get their defaults.
    static func load() -> Tuning {
        guard let data = UserDefaults.standard.data(forKey: "tuning"),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Tuning())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, saved in saved }),
              let tuning = try? JSONDecoder().decode(Tuning.self, from: merged) else { return Tuning() }
        return tuning
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "tuning")
    }

    /// The allergy list, lowercased.
    var allergyList: [String] {
        allergies.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}
