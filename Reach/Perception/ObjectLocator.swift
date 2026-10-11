import CoreGraphics
import Foundation

/// Asks Gemini where an object is in a camera frame.
struct ObjectLocator {
    struct Found {
        var label: String
        /// Normalized, origin top-left.
        var box: CGRect
    }

    enum LocatorError: LocalizedError {
        case missingKey
        case http(Int, String)
        case badReply

        var errorDescription: String? {
            switch self {
            case .missingKey: "No Gemini API key"
            case .http(let status, let body): "Gemini HTTP \(status): \(body.prefix(200))"
            case .badReply: "Gemini returned something unexpected"
            }
        }
    }

    /// Picked live in the tuning sheet. All three returned exact boxes in testing; latency differs.
    static let models = ["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.8-flash"]
    var timeout: TimeInterval = 6

    /// Returns nil when Gemini doesn't see the object.
    func locate(_ query: String, in jpeg: Data, model: String) async throws -> Found? {
        let text = try await generate(prompt: Self.prompt(query), schema: Self.schema, jpeg: jpeg, model: model)
        guard let detection = try? JSONDecoder().decode(Detection.self, from: Data(text.utf8)) else { throw LocatorError.badReply }
        guard detection.found else { return nil }
        return Self.found(detection.label, detection.box_2d)
    }

    /// Every distinct object on the table (up to 12).
    func scan(_ jpeg: Data, model: String) async throws -> [Found] {
        let text = try await generate(prompt: Self.scanPrompt, schema: Self.scanSchema, jpeg: jpeg, model: model)
        guard let scan = try? JSONDecoder().decode(Scan.self, from: Data(text.utf8)) else { throw LocatorError.badReply }
        return scan.objects.compactMap { Self.found($0.label, $0.box_2d) }
    }

    /// One generateContent call with the photo; returns the JSON text of the reply.
    private func generate(prompt: String, schema: [String: Any], jpeg: Data, model: String) async throws -> String {
        guard !AppConfig.geminiAPIKey.isEmpty else { throw LocatorError.missingKey }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.geminiAPIKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [
                ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ["text": prompt],
            ]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": schema,
                "thinkingConfig": ["thinkingLevel": model == "gemini-3.8-flash" ? "low" : "minimal"],  // 3.8 has no "minimal"
            ],
        ])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            (data, response) = try await URLSession.shared.data(for: request)  // latency is spiky: retry once
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LocatorError.http(status, String(decoding: data, as: UTF8.self)) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let text = reply.candidates?.first?.content?.parts?.last(where: { $0.thought != true })?.text else {
            throw LocatorError.badReply
        }
        return text
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

    private struct Reply: Decodable {
        struct Candidate: Decodable { var content: Content? }
        struct Content: Decodable { var parts: [Part]? }
        struct Part: Decodable {
            var text: String?
            var thought: Bool?
        }
        var candidates: [Candidate]?
    }
}
