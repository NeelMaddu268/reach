import Foundation

/// ElevenLabs text to speech. The same voice and model make the bundled clips (scripts/make_clips.py).
enum ElevenLabs {
    static let voiceID = "EXAVITQu4vr4xnSDxMaL"
    static let model = "eleven_v4_turbo"

    static func speech(_ text: String, spanish: Bool = false) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=mp3_44100_128")!,
                                 timeoutInterval: 6)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        var body: [String: Any] = ["text": text, "model_id": model]
        if spanish { body["language_code"] = "es" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// A phrase's clip name: "Right, 6 inches." → "right-6-inches". Must match slug() in scripts/make_clips.py.
    static func slug(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .joined(separator: "-")
    }
}
