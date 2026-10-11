import Foundation

/// Gemini generateContent with photos and structured JSON output. Shared by the locator, the table scan and
/// held-item questions; the model comes from the tuning sheet's picker.
enum Gemini {
    enum GeminiError: LocalizedError {
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

    /// One call with `images` (JPEGs, in order) before `prompt`; returns the reply's JSON text.
    static func generate(prompt: String, images: [Data], schema: [String: Any], model: String,
                         timeout: TimeInterval = 6) async throws -> String {
        guard !AppConfig.geminiAPIKey.isEmpty else { throw GeminiError.missingKey }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.geminiAPIKey, forHTTPHeaderField: "x-goog-api-key")
        let parts: [[String: Any]] = images.map { ["inline_data": ["mime_type": "image/jpeg", "data": $0.base64EncodedString()]] }
            + [["text": prompt]]
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": parts]],
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
        guard status == 200 else { throw GeminiError.http(status, String(decoding: data, as: UTF8.self)) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let text = reply.candidates?.first?.content?.parts?.last(where: { $0.thought != true })?.text else {
            throw GeminiError.badReply
        }
        return text
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
