import Foundation
import QuartzCore
import Vision

/// "What's this?": reads any text in the photo with Vision, then asks Claude for one spoken sentence about
/// the object the user is holding up.
struct Reader {
    enum ReaderError: LocalizedError {
        case missingKey
        case http(Int, String)
        case refused
        case badReply

        var errorDescription: String? {
            switch self {
            case .missingKey: "No Anthropic API key"
            case .http(let status, let body): "Claude HTTP \(status): \(body.prefix(200))"
            case .refused: "Claude declined"
            case .badReply: "Claude returned something unexpected"
            }
        }
    }

    /// Picked live in the tuning sheet.
    static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    var timeout: TimeInterval = 15

    func describe(_ jpeg: Data, model: String, spanish: Bool = false) async throws -> String {
        guard !AppConfig.anthropicAPIKey.isEmpty else { throw ReaderError.missingKey }
        let text = await Self.recognizeText(in: jpeg)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !AppConfig.anthropicWorkspaceID.isEmpty {
            request.setValue(AppConfig.anthropicWorkspaceID, forHTTPHeaderField: "anthropic-workspace-id")
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "output_config": ["effort": "low"],  // a quick answer; thinking can't be turned off on these models
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ["type": "text", "text": Self.prompt(text) + (spanish ? "\nAnswer in Spanish." : "")],
            ]]],
        ]
        // If the model declines for safety reasons, the API retries on Anthropic's recommended fallback model.
        // (Haiku has no server-side fallback.)
        if !model.contains("haiku") {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ReaderError.http(status, String(decoding: data, as: UTF8.self)) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.stop_reason != "refusal" else { throw ReaderError.refused }
        guard let answer = reply.content.first(where: { $0.type == "text" })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { throw ReaderError.badReply }
        return answer
    }

    /// The last item asked about, kept for one follow-up.
    struct Item {
        var jpeg: Data
        var text: [String]
        var question: String
        var answer: String
        var time: TimeInterval
    }

    /// A question about the held item (nil = "what's this?"), answered by Gemini only from what's printed or clearly
    /// visible. Leads with an allergy warning when the printed text mentions one of `allergies`; never reassures.
    func ask(_ question: String?, jpeg: Data, previous: Item?, allergies: [String], model: String, spanish: Bool = false)
        async throws -> (spoken: String, item: Item) {
        let text = await Self.recognizeText(in: jpeg)
        let question = question ?? "What is this? Name it and the most useful details printed on it, like flavor, strength or dose, or expiry date."
        var images = [jpeg]
        var earlier = ""
        if let previous {
            images.insert(previous.jpeg, at: 0)
            earlier = """
            Earlier, about the item in the first photo, they asked "\(previous.question)" and were told \
            "\(previous.answer)". Text read from that photo: \(Self.joined(previous.text)). The second photo is from \
            now; if it shows a different item, answer about that one.

            """
        }
        let prompt = """
        You're helping a blind person who is holding something up to a camera on their chest.
        \(earlier)Their question: "\(question)"
        Set answer to one or two short spoken sentences, using only what is printed on the item or clearly visible. \
        No outside knowledge, no guessing.
        - Dosing or how much to take: repeat the directions printed on the label and add nothing. If none are readable, say so.
        - Never say anything is safe or allergen-free, and never say it doesn't contain something.
        - If you can't read enough of it to answer, set readable to false and say what you can't read.
        - Set allergens_on_label to whichever of these the printed text mentions (ingredients, "contains" or \
        "may contain" lines): \(allergies.isEmpty ? "none" : allergies.joined(separator: ", ")). Empty if none.
        Text read from the current photo (may have errors): \(Self.joined(text))\(spanish ? "\nWrite answer in Spanish." : "")
        """
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "readable": ["type": "BOOLEAN"],
                "answer": ["type": "STRING"],
                "allergens_on_label": ["type": "ARRAY", "items": ["type": "STRING"]],
            ],
            "required": ["readable", "answer", "allergens_on_label"],
        ]
        let json = try await Gemini.generate(prompt: prompt, images: images, schema: schema, model: model, timeout: 10)
        guard let reply = try? JSONDecoder().decode(Answer.self, from: Data(json.utf8)) else { throw Gemini.GeminiError.badReply }

        // Warn from the text read on the phone as well as Gemini's reading, so a missed mention still warns.
        let printed = text.joined(separator: " ").lowercased()
        let flagged = allergies.filter { allergen in
            Self.mentions(printed, allergen) || reply.allergens_on_label.contains { Self.mentions($0.lowercased(), allergen) }
        }
        var spoken = Self.withoutReassurance(reply.answer)
        if spoken.isEmpty {
            spoken = reply.readable
                ? (spanish ? "Solo puedo decirte lo que está impreso en la etiqueta." : "I can only tell you what's printed on the label.")
                : (spanish ? "No puedo leer bien la etiqueta. Acércala, con la etiqueta hacia la cámara."
                           : "I can't read the label clearly. Try holding it closer, label toward the camera.")
        }
        if !flagged.isEmpty {
            let and = spanish ? " y " : " and "
            let names = flagged.count == 1 ? flagged[0] : flagged.dropLast().joined(separator: ", ") + and + flagged.last!
            spoken = (spanish ? "Cuidado, la etiqueta dice que contiene \(names). " : "Careful, the label says it contains \(names). ") + spoken
        }
        return (spoken, Item(jpeg: jpeg, text: text, question: question, answer: reply.answer, time: CACurrentMediaTime()))
    }

    /// "peanuts" matches "peanut", "Peanuts", "peanut butter".
    private static func mentions(_ text: String, _ allergen: String) -> Bool {
        let singular = allergen.hasSuffix("s") ? String(allergen.dropLast()) : allergen
        return !singular.isEmpty && text.contains(singular)
    }

    /// Drops any sentence that reassures ("safe", "allergen-free", "doesn't contain …"): Reach only reports what's printed.
    private static func withoutReassurance(_ answer: String) -> String {
        let reassurance = try! NSRegularExpression(pattern:
            #"\bsafe\b|allergen[- ]free|\bfree (of|from)\b|\b(does ?n['’]?t|does not|do not|don['’]t) contain|\bcontains? no\b|\bno traces?\b"#
            + #"|\bsegur[oa]s?\b|sin al[eé]rgenos|libre de|\bno contiene\b"#,
            options: .caseInsensitive)
        var sentences: [String] = []
        answer.enumerateSubstrings(in: answer.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            let range = NSRange(sentence.startIndex..., in: sentence)
            if reassurance.firstMatch(in: sentence, range: range) == nil { sentences.append(sentence) }
        }
        return sentences.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joined(_ text: [String]) -> String {
        text.isEmpty ? "none" : text.joined(separator: " | ")
    }

    private struct Answer: Decodable {
        var readable: Bool
        var answer: String
        var allergens_on_label: [String]
    }

    private static func prompt(_ text: [String]) -> String {
        let read = text.isEmpty ? "none" : text.joined(separator: " | ")
        return """
        I'm blind and holding something up to the camera on my chest. In one short sentence I can listen to, \
        tell me what it is and the most useful details on it (like name, flavor, strength or dose, expiry date, \
        or price). If it's not clear what I'm holding, describe what's in front of the camera instead. \
        Plain words only, no lists or symbols.
        Text read from the photo (may have errors, or come from the background): \(read)
        """
    }

    /// Text Vision can read in the photo, top to bottom.
    private static func recognizeText(in jpeg: Data) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(data: jpeg).perform([request])
                continuation.resume(returning: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
            }
        }
    }

    private struct Reply: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var content: [Block]
        var stop_reason: String?
    }
}
