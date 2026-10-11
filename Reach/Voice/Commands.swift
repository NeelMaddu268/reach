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
    case stop

    /// Parses "find my keys", "where are my glasses", "what's this", "what's on the table", "stop".
    init?(_ transcript: String) {
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

/// Push-to-talk speech recognition, on device. Call from the main thread.
final class VoiceInput {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
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
        request.contextualStrings = ["find", "what's this", "stop"]
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
