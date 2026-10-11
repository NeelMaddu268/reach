import AVFoundation
import Speech

enum Command: Equatable {
    case find(String)
    case whatsThis
    /// Any other question, about the held item: "is this decaf?", "how many do I take?"
    case ask(String)
    case scan
    /// "Where are my keys?", "where did I leave my wallet?"
    case whereIs(String)
    /// "This is my mug": remember what the user's own one looks like.
    case remember(String)
    case stop
    /// "How much money is this?", "count my money" (money reader).
    case money
    /// "Is this my lisinopril?" (medication check).
    case checkMine(String)

    /// Commands that belong to features switched on in Tuning. With none on, parsing is exactly as before.
    struct Extras: OptionSet {
        let rawValue: Int
        static let money = Extras(rawValue: 1 << 0)
        static let medicationCheck = Extras(rawValue: 1 << 1)
    }

    /// Parses "find my keys", "where are my glasses", "what's this", "what's on the table", "stop".
    init?(_ transcript: String, spanish: Bool = false, extras: Extras = []) {
        if let command = Self.extra(transcript, spanish: spanish, extras: extras) {
            self = command
            return
        }
        if spanish {
            guard let command = Self.spanish(transcript) else { return nil }
            self = command
            return
        }
        let text = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))

        if text.hasPrefix("stop") || text.hasPrefix("cancel") {
            self = .stop
            return
        }
        let scanPhrases = ["what's on the table", "what is on the table", "what's in front of me", "what is in front of me",
                           "what do you see", "what's here", "look around", "scan"]
        if scanPhrases.contains(where: text.contains) {
            self = .scan
            return
        }
        let readPhrases = ["what's this", "what is this", "what's that", "what is that", "what is it", "what's in my hand",
                           "what am i holding", "read this", "read it"]
        if readPhrases.contains(where: text.contains) {
            self = .whatsThis
            return
        }
        for trigger in ["this is my", "these are my", "that's my", "that is my"] {
            guard let range = text.range(of: trigger + " ") else { continue }
            let object = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !object.isEmpty else { return nil }
            self = .remember(object)
            return
        }
        let triggers = ["find", "look for", "where did i leave", "where did i put", "where's", "where is", "where are"]
        for trigger in triggers {
            guard let range = text.range(of: trigger + " ") else { continue }
            var words = text[range.upperBound...].split(separator: " ").map(String.init)
            while let first = words.first, ["me", "my", "the", "a", "an", "our", "your"].contains(first) {
                words.removeFirst()
            }
            if words.last == "please" { words.removeLast() }
            guard !words.isEmpty else { return nil }
            let object = words.joined(separator: " ")
            self = trigger.hasPrefix("where") ? .whereIs(object) : .find(object)
            return
        }
        let questionStarts = ["is ", "does ", "do ", "how ", "what ", "which ", "can ", "should ", "when ", "are ",
                              "will ", "has ", "have ", "who "]
        if questionStarts.contains(where: text.hasPrefix) {
            self = .ask(transcript.trimmingCharacters(in: .whitespaces))
            return
        }
        return nil
    }
}

extension Command {
    /// Phrases for switched-on features, checked before everything else.
    private static func extra(_ transcript: String, spanish: Bool, extras: Extras) -> Command? {
        guard !extras.isEmpty else { return nil }
        let text = transcript.lowercased().replacingOccurrences(of: "’", with: "'")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: spanish ? "es" : "en"))
        if extras.contains(.money) {
            let phrases = spanish ? ["cuanto dinero", "que billete", "cuenta mi dinero", "cuenta el dinero", "cuanto efectivo"]
                                  : ["how much money", "what bill", "which bill", "count my money", "count the money",
                                     "count this money", "how much cash", "count my cash"]
            if phrases.contains(where: text.contains) { return .money }
        }
        if extras.contains(.medicationCheck) {
            let triggers = spanish ? ["es este mi", "es esta mi", "son estos mis", "son estas mis", "es mi", "son mis"]
                                   : ["is this my", "is that my", "are these my", "are those my"]
            for trigger in triggers {
                guard let range = text.range(of: trigger + " ") else { continue }
                let name = text[range.upperBound...].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                if !name.isEmpty { return .checkMine(name) }
            }
        }
        return nil
    }

    /// "Encuentra mis llaves", "¿qué es esto?", "¿qué hay en la mesa?", "¿dónde están mis llaves?", "esta es mi taza", "para".
    private static func spanish(_ transcript: String) -> Command? {
        // Accents folded, so "qué" and "que" both match.
        let text = transcript.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if ["para", "alto", "basta"].contains(text) || text.hasPrefix("detente") || text.hasPrefix("cancela") { return .stop }
        if ["que hay en la mesa", "que hay frente a mi", "que ves", "mira alrededor", "escanea"].contains(where: text.contains) {
            return .scan
        }
        if ["que es esto", "que es eso", "que tengo en la mano", "lee esto"].contains(where: text.contains) { return .whatsThis }
        func object(after trigger: String) -> String? {
            guard let range = text.range(of: trigger + " ") else { return nil }
            var words = text[range.upperBound...].split(separator: " ").map(String.init)
            while let first = words.first, ["me", "mi", "mis", "el", "la", "los", "las", "un", "una", "unos", "unas"].contains(first) {
                words.removeFirst()
            }
            if words.suffix(2) == ["por", "favor"] { words.removeLast(2) }
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
        for trigger in ["esta es mi", "este es mi", "estas son mis", "estos son mis"] {
            if let object = object(after: trigger) { return .remember(object) }
        }
        for trigger in ["encuentra", "busca", "donde deje", "donde puse", "donde esta", "donde estan"] {
            if let object = object(after: trigger) { return trigger.hasPrefix("donde") ? .whereIs(object) : .find(object) }
        }
        let questionStarts = ["es ", "tiene ", "cuantas ", "cuantos ", "cuanto ", "cuanta ", "que ", "cual ", "puedo ",
                              "debo ", "cuando ", "esta ", "contiene ", "lleva "]
        if questionStarts.contains(where: text.hasPrefix) { return .ask(transcript.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

/// Push-to-talk speech recognition, on device. Call from the main thread.
final class VoiceInput {
    /// Listen in Spanish (es-US) instead of English.
    var spanish = false {
        didSet { recognizer = SFSpeechRecognizer(locale: Locale(identifier: spanish ? "es-US" : "en-US")) }
    }
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var isFinal = false

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    func start() {
        guard let recognizer, recognizer.isAvailable, request == nil else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }  // no mic (simulator)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = spanish ? ["encuentra", "qué es esto", "qué hay en la mesa", "para"] : ["find", "what's this", "stop"]
        transcript = ""
        isFinal = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                transcript = result.bestTranscription.formattedString
                isFinal = result.isFinal
            }
            if error != nil { isFinal = true }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do {
            try engine.start()
            self.request = request
        } catch {
            input.removeTap(onBus: 0)
            task?.cancel()
        }
    }

    /// Stops listening and returns what was heard.
    func stop() async -> String {
        guard let request else { return "" }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        self.request = nil
        // On-device recognition finishes within a few hundred ms of the end of audio.
        for _ in 0..<20 where !isFinal {
            try? await Task.sleep(for: .milliseconds(50))
        }
        task?.cancel()
        task = nil
        return transcript
    }
}
