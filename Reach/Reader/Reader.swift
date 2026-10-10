import Foundation
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

    func describe(_ jpeg: Data, model: String) async throws -> String {
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
                ["type": "text", "text": Self.prompt(text)],
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
