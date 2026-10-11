import Foundation

/// "Is this my lisinopril?": compares the held bottle's printed label with the one saved by "this is my lisinopril",
/// using printed text only. Says it can't confirm whenever the label can't be read.
struct MedicationCheck {
    func check(_ name: String, jpeg: Data, saved: (photo: Data, text: String), model: String, spanish: Bool) async throws -> String {
        let text = await Reader.recognizeText(in: jpeg)
        let prompt = """
        The first photo is the label of the person's own \(name). Text read from it: \(saved.text.isEmpty ? "none" : saved.text).
        The second photo is what they're holding now. Text read from it (may have errors): \(text.isEmpty ? "none" : text.joined(separator: " | ")).
        Using only printed text, is the item now the same medication as the saved one (same drug name and strength)?
        Set readable to false if you can't read the current label's drug name. Set name and strength to what the current \
        label prints (empty if not printed). Set label_says to the current label's drug name and strength as printed, \
        in a few words.
        """
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "readable": ["type": "BOOLEAN"], "same": ["type": "BOOLEAN"], "name": ["type": "STRING"],
                "strength": ["type": "STRING"], "label_says": ["type": "STRING"],
            ],
            "required": ["readable", "same", "name", "strength", "label_says"],
        ]
        let json = try await Gemini.generate(prompt: prompt, images: [saved.photo, jpeg], schema: schema, model: model, timeout: 10)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else { throw Gemini.GeminiError.badReply }

        let cantConfirm = spanish ? "No puedo leer bien esta etiqueta, así que no puedo confirmar que sea tu \(name)."
                                  : "I can't read this label clearly, so I can't confirm it's your \(name)."
        guard reply.readable else { return cantConfirm }
        if reply.same {
            // Only say yes when the name is actually printed on the label in front of the camera.
            let printed = (text.joined(separator: " ") + " " + reply.name + " " + reply.label_says).lowercased()
            guard printed.contains(name.lowercased()) || !saved.text.lowercased().contains(name.lowercased()) else { return cantConfirm }
            let strength = reply.strength.trimmingCharacters(in: .whitespaces)
            if spanish { return strength.isEmpty ? "Sí, es tu \(name)." : "Sí, es tu \(name), \(strength)." }
            return strength.isEmpty ? "Yes, this is your \(name)." : "Yes, this is your \(name), \(strength)."
        }
        let says = reply.label_says.isEmpty ? reply.name : reply.label_says
        if spanish { return "Cuidado, esto no es tu \(name). La etiqueta dice \(says)." }
        return "Careful, this isn't your \(name). The label says \(says)."
    }

    private struct Reply: Decodable {
        var readable: Bool
        var same: Bool
        var name: String
        var strength: String
        var label_says: String
    }
}
