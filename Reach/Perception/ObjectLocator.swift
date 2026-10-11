import CoreGraphics
import Foundation

/// Asks Gemini where an object is in a camera frame.
struct ObjectLocator {
    struct Found {
        var label: String
        /// Normalized, origin top-left.
        var box: CGRect
    }

    var timeout: TimeInterval = 6

    /// Returns nil when Gemini doesn't see the object. With a `reference` photo of the user's own one
    /// ("this is my mug"), Gemini looks for that same object rather than any match.
    /// `near`: where it was a moment ago (following a moved object), so Gemini doesn't jump to a lookalike.
    func locate(_ query: String, in jpeg: Data, model: String, reference: Data? = nil, near hint: CGRect? = nil,
                spanish: Bool = false) async throws -> Found? {
        var prompt = Self.prompt(query) + (spanish ? "\nWrite label in Spanish." : "")
        if let hint {
            let b = [hint.minY, hint.minX, hint.maxY, hint.maxX].map { Int(min(max($0, 0), 1) * 1000) }
            prompt += "\nA moment ago it was at box_2d \(b). If it's still there, return that one; otherwise find where it is now."
        }
        if reference != nil {
            prompt = "The first photo shows the person's own \(query). Find that same one, not a similar one, in the second photo.\n"
                + prompt
        }
        let text = try await Gemini.generate(prompt: prompt, images: [reference, jpeg].compactMap { $0 }, schema: Self.schema,
                                             model: model, timeout: timeout)
        guard let detection = try? JSONDecoder().decode(Detection.self, from: Data(text.utf8)) else { throw Gemini.GeminiError.badReply }
        guard detection.found else { return nil }
        return Self.found(detection.label, detection.box_2d)
    }

    /// Every distinct object on the table (up to 12).
    func scan(_ jpeg: Data, model: String, spanish: Bool = false) async throws -> [Found] {
        let text = try await Gemini.generate(prompt: Self.scanPrompt + (spanish ? "\nWrite labels in Spanish." : ""), images: [jpeg], schema: Self.scanSchema, model: model,
                                             timeout: timeout)
        guard let scan = try? JSONDecoder().decode(Scan.self, from: Data(text.utf8)) else { throw Gemini.GeminiError.badReply }
        return scan.objects.compactMap { Self.found($0.label, $0.box_2d) }
    }

    /// Gemini's box_2d ([ymin, xmin, ymax, xmax], 0–1000) as a normalized rect.
    private static func found(_ label: String, _ box2d: [Int]) -> Found? {
        guard box2d.count == 4 else { return nil }
        let b = box2d.map { CGFloat($0) / 1000 }
        let box = CGRect(x: b[1], y: b[0], width: b[3] - b[1], height: b[2] - b[0])
        guard box.width > 0, box.height > 0 else { return nil }
        return Found(label: label, box: box)
    }

    private static func prompt(_ query: String) -> String {
        """
        This photo is from a phone worn on someone's chest, looking down at the table in front of them. Find: \(query).
        Only set found to true if you're confident this is the object asked for. Set label to a short name for exactly \
        what you see (like "car keys" or "blue mug"). Set box_2d to [ymin, xmin, ymax, xmax] normalized to 0-1000, \
        tight around only that object's own pixels: no surrounding table, shadow or neighboring items. If several \
        match, pick the one closest to the person (nearest the bottom center). If it isn't visible, set found to \
        false and box_2d to [].
        """
    }

    private static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "found": ["type": "BOOLEAN"],
            "label": ["type": "STRING"],
            "box_2d": ["type": "ARRAY", "items": ["type": "INTEGER"]],
        ],
        "required": ["found", "label", "box_2d"],
    ]

    private static let scanPrompt = """
        This photo is from a phone worn on someone's chest, looking down at the table in front of them. List the \
        distinct objects on the table, up to 12. Skip the table itself, hands, and anything not on the table. For each, \
        set label to a short name (like "keys", "blue mug", "pill bottle") and box_2d to [ymin, xmin, ymax, xmax] \
        normalized to 0-1000, tight around just that object.
        """

    private static let scanSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "objects": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["label": ["type": "STRING"], "box_2d": ["type": "ARRAY", "items": ["type": "INTEGER"]]],
                "required": ["label", "box_2d"],
            ]],
        ],
        "required": ["objects"],
    ]

    private struct Scan: Decodable {
        struct Object: Decodable {
            var label: String
            var box_2d: [Int]
        }
        var objects: [Object]
    }

    private struct Detection: Decodable {
        var found: Bool
        var label: String
        var box_2d: [Int]
    }
}
