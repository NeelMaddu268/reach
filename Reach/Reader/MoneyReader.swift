import CoreGraphics
import Foundation

/// "How much money is this?": Gemini reads each banknote's denomination, only where it's clearly visible.
/// Bills it can't make out are reported, never guessed or counted.
struct MoneyReader {
    struct Bill {
        /// Dollars, or nil when the denomination isn't clearly visible.
        var value: Int?
        /// Normalized, origin top-left.
        var box: CGRect
    }

    static let denominations = [1, 2, 5, 10, 20, 50, 100]

    func read(_ jpeg: Data, model: String) async throws -> [Bill] {
        let prompt = """
        Find every paper banknote in this photo, whether held up or lying on the table. For each, set box_2d to \
        [ymin, xmin, ymax, xmax] normalized to 0-1000, and value to its denomination in US dollars, but only if the \
        number or portrait is clearly visible. Otherwise set value to 0: a bill that is folded, covered, blurry, \
        face-down or only partly visible gets 0. Don't guess. Ignore coins and anything that isn't a banknote.
        """
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "bills": ["type": "ARRAY", "items": [
                    "type": "OBJECT",
                    "properties": ["value": ["type": "INTEGER"], "box_2d": ["type": "ARRAY", "items": ["type": "INTEGER"]]],
                    "required": ["value", "box_2d"],
                ]],
            ],
            "required": ["bills"],
        ]
        let json = try await Gemini.generate(prompt: prompt, images: [jpeg], schema: schema, model: model, timeout: 10)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else { throw Gemini.GeminiError.badReply }
        return reply.bills.compactMap { bill -> Bill? in
            guard bill.box_2d.count == 4 else { return nil }
            let b = bill.box_2d.map { CGFloat($0) / 1000 }
            let value = Self.denominations.contains(bill.value) ? bill.value : nil  // anything else counts as unreadable
            return Bill(value: value, box: CGRect(x: b[1], y: b[0], width: b[3] - b[1], height: b[2] - b[0]))
        }
    }

    /// "That's a twenty, two fives and a one: thirty-one dollars." Unreadable bills are said, not counted.
    static func spoken(_ bills: [Bill], spanish: Bool) -> String {
        let spell = NumberFormatter()
        spell.numberStyle = .spellOut
        spell.locale = Locale(identifier: spanish ? "es-US" : "en-US")
        func words(_ n: Int) -> String { spell.string(from: n as NSNumber) ?? "\(n)" }
        func join(_ items: [String]) -> String {
            items.count == 1 ? items[0] : items.dropLast().joined(separator: ", ") + (spanish ? " y " : " and ") + items.last!
        }

        let readable = bills.compactMap(\.value)
        let unreadable = bills.count - readable.count
        guard !bills.isEmpty else { return spanish ? "No veo billetes." : "I don't see any bills." }
        guard !readable.isEmpty else {
            return spanish ? "Veo \(bills.count) \(bills.count == 1 ? "billete" : "billetes") pero no distingo su valor. Ponlos planos, boca arriba, más cerca de la cámara."
                           : "I can see \(bills.count == 1 ? "a bill" : "\(bills.count) bills") but can't make out \(bills.count == 1 ? "its value" : "their values"). Hold them flat, face up, closer to the camera."
        }

        let counts = Dictionary(grouping: readable, by: { $0 }).mapValues(\.count)
        let items = counts.keys.sorted(by: >).map { value -> String in
            let count = counts[value]!
            if spanish {
                return count == 1 ? "un billete de \(words(value))" : "\(words(count)) de \(words(value))"
            }
            let (one, many) = Self.englishNames[value]!
            return count == 1 ? "a \(one)" : "\(words(count)) \(many)"
        }
        let total = readable.reduce(0, +)
        var line = spanish
            ? "Hay \(join(items)): \(total == 1 ? "un dólar" : "\(Self.beforeNoun(words(total))) dólares")."
            : "That's \(join(items)): \(words(total)) \(total == 1 ? "dollar" : "dollars")."
        if unreadable > 0 {
            line += spanish
                ? " No distingo \(unreadable == 1 ? "un billete" : "\(unreadable) billetes"), así que no \(unreadable == 1 ? "lo" : "los") conté."
                : " I can't make out \(unreadable == 1 ? "one more bill, so I didn't count it" : "\(unreadable) more bills, so I didn't count them")."
        }
        return line
    }

    /// "treinta y uno" → "treinta y un" before a noun ("treinta y un dólares").
    private static func beforeNoun(_ spanishNumber: String) -> String {
        spanishNumber.hasSuffix("uno") ? String(spanishNumber.dropLast()) : spanishNumber
    }

    private static let englishNames = [1: ("one", "ones"), 2: ("two", "twos"), 5: ("five", "fives"), 10: ("ten", "tens"),
                                       20: ("twenty", "twenties"), 50: ("fifty", "fifties"), 100: ("hundred", "hundreds")]

    private struct Reply: Decodable {
        struct Bill: Decodable {
            var value: Int
            var box_2d: [Int]
        }
        var bills: [Bill]
    }
}
