import AVFoundation
import os

/// Earbud audio: the sonar (a ticking sine whose pan, pitch and tick rate come from `Guide`), the lock ding,
/// and the voice. Speech prefers a bundled ElevenLabs clip (Audio/Clips/), then live ElevenLabs (cached on disk),
/// then the best iPhone voice installed.
final class AudioGuide: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    struct Tone: Equatable {
        var frequency = 440.0
        var pan = 0.0         // -1 left … 1 right
        var beepPeriod = 0.0  // seconds between ticks; 0 = solid tone
        var volume = 0.0
        static let silent = Tone()
    }

    private let engine = AVAudioEngine()
    private let synth = Synth()
    private let speech = AVSpeechSynthesizer()
    /// Speak Spanish: live ElevenLabs with language "es" (the bundled clips are English) and an es-US fallback voice.
    var spanish = false
    /// No gaps: if live speech is slow (> 1.2 s) or failed in the last 30 s, the iPhone voice speaks right away.
    var networkFallback = false
    private var liveVoiceDownUntil = Date.distantPast
    /// The phrase the live voice is fetching; cleared when the iPhone voice takes over or a new phrase starts.
    private var speakToken: UUID?
    private var player: AVAudioPlayer?
    private var fetch: Task<Void, Never>?
    /// Called on main with each thing said, for on-screen captions (the judges can't hear the earbuds).
    var onSpeak: ((String) -> Void)?

    override init() {
        super.init()
        speech.delegate = self
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            // A2DP (not HFP) keeps AirPods in stereo while the phone's own mic listens.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Audio session: \(error)")
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: Synth.sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { [synth] _, _, frameCount, buffers in
            synth.render(frameCount: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(buffers))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        // Route changes (AirPods in or out) stop the engine.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            try? self?.engine.start()
        }
        do {
            try engine.start()
        } catch {
            print("Audio engine: \(error)")
        }
    }

    // MARK: Sonar

    /// Safe to call from any thread, every frame.
    func setTone(_ tone: Tone) {
        synth.shared.withLock { $0.tone = tone }
    }

    func ding() {
        synth.shared.withLock { $0.dings += 1 }
    }

    /// A short rising chirp: "got it, working on it".
    func working() {
        synth.shared.withLock { $0.chirps += 1 }
    }

    /// Silences the sonar (not the ding or speech), e.g. while listening.
    func setMuted(_ muted: Bool) {
        synth.shared.withLock { $0.muted = muted }
    }

    // MARK: Voice (call on main)

    /// Says `text` now, cutting off anything being said.
    func say(_ text: String) {
        fetch?.cancel()
        fetch = nil
        player?.stop()
        speech.stopSpeaking(at: .immediate)
        speak(text)
    }

    /// Says `text` unless something is already being said.
    func cue(_ text: String) {
        guard player?.isPlaying != true, !speech.isSpeaking, fetch == nil else { return }
        speak(text)
    }

    /// Fetches and caches speech for phrases about to be needed (e.g. object names), so they play instantly.
    func prefetch(_ texts: [String]) {
        guard !AppConfig.elevenLabsAPIKey.isEmpty else { return }
        let spanish = spanish
        Task.detached(priority: .utility) {
            for text in texts where Self.storedAudio(for: text) == nil {
                if let audio = try? await ElevenLabs.speech(text, spanish: spanish) { Self.cache(audio, for: text) }
            }
        }
    }

    private func speak(_ text: String) {
        onSpeak?(text)
        setDucked(true)
        if let audio = Self.storedAudio(for: text) {
            play(audio)
            return
        }
        let fallback = networkFallback
        guard !AppConfig.elevenLabsAPIKey.isEmpty, !(fallback && Date() < liveVoiceDownUntil) else {
            speakWithSystemVoice(text)
            return
        }
        let spanish = spanish
        let token = UUID()
        speakToken = token
        fetch = Task { @MainActor [weak self] in
            let audio = try? await ElevenLabs.speech(text, spanish: spanish)
            guard let self, !Task.isCancelled else { return }
            if let audio {
                Self.cache(audio, for: text)
            } else if fallback {
                liveVoiceDownUntil = Date() + 30
            }
            guard speakToken == token else { return }  // the iPhone voice already said it; keep the audio for next time
            speakToken = nil
            fetch = nil
            if let audio {
                play(audio)
            } else {
                speakWithSystemVoice(text)
            }
        }
        guard fallback else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, speakToken == token else { return }
            speakToken = nil
            fetch = nil
            speakWithSystemVoice(text)
        }
    }

    private func play(_ audio: Data) {
        guard let player = try? AVAudioPlayer(data: audio) else { return setDucked(false) }
        player.delegate = self
        self.player = player
        player.play()
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        let language = spanish ? "es-US" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .max { $0.quality.rawValue < $1.quality.rawValue }  // the best installed one
        speech.speak(utterance)
    }

    /// The sonar drops back while the voice talks, so instructions are easy to hear.
    private func setDucked(_ ducked: Bool) {
        synth.shared.withLock { $0.duck = ducked ? 0.3 : 1 }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === self.player { setDucked(false) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        setDucked(false)
    }

    // MARK: Stored speech

    /// A bundled clip (scripts/make_clips.py), or audio cached from an earlier live request.
    private static func storedAudio(for text: String) -> Data? {
        let name = ElevenLabs.slug(text)
        if let url = Bundle.main.url(forResource: name, withExtension: "mp3") { return try? Data(contentsOf: url) }
        return try? Data(contentsOf: cacheURL(name))
    }

    private static func cache(_ audio: Data, for text: String) {
        let url = cacheURL(ElevenLabs.slug(text))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? audio.write(to: url)
    }

    private static func cacheURL(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speech/\(ElevenLabs.voiceID)/\(name.prefix(150)).mp3")
    }
}

/// Render-thread synth. Targets arrive through `shared`; everything else is touched only on the render thread.
private final class Synth {
    struct Shared {
        var tone = AudioGuide.Tone.silent
        var dings = 0
        var chirps = 0
        var muted = false
        var duck: Float = 1
    }

    static let sampleRate = 48_000.0
    static let tickLength = 0.045  // seconds
    let shared = OSAllocatedUnfairLock(initialState: Shared())

    private var target = Shared()
    private var dingsPlayed = 0
    private var chirpsPlayed = 0
    private var chirpTime = 10.0
    private var phase = 0.0, frequency = 440.0, pan = 0.0, gain = 0.0, duck = 1.0
    private var beepClock = 0.0
    private var dingTime = 10.0

    func render(frameCount: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        if let latest = shared.withLockIfAvailable({ $0 }) { target = latest }  // never block the audio thread
        if target.dings != dingsPlayed {
            dingsPlayed = target.dings
            dingTime = 0
        }
        if target.chirps != chirpsPlayed {
            chirpsPlayed = target.chirps
            chirpTime = 0
        }
        let tone = target.muted ? .silent : target.tone
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
        let dt = 1 / Self.sampleRate
        let glide = 1 - exp(-dt / 0.03)     // ~30 ms pitch/pan/duck glide
        let envelope = 1 - exp(-dt / 0.004) // ~4 ms tick edges, no clicks

        for i in 0..<frameCount {
            frequency += (tone.frequency - frequency) * glide
            pan += (tone.pan - pan) * glide
            duck += (Double(target.duck) - duck) * glide
            beepClock += dt
            if tone.beepPeriod > 0, beepClock >= tone.beepPeriod { beepClock = 0 }
            let on = tone.beepPeriod == 0 || beepClock < min(Self.tickLength, tone.beepPeriod / 2)
            gain += ((on ? tone.volume * duck : 0) - gain) * envelope

            phase += 2 * .pi * frequency * dt
            if phase > 2 * .pi { phase -= 2 * .pi }
            let sample = 0.4 * gain * sin(phase)
            let angle = (pan + 1) * .pi / 4  // equal-power pan
            let ding = (dingTime < 1.5 ? Self.ding(at: dingTime) : 0) + (chirpTime < 0.2 ? Self.chirp(at: chirpTime) : 0)
            dingTime += dt
            chirpTime += dt
            left[i] = Float(sample * cos(angle) + ding)
            right[i] = Float(sample * sin(angle) + ding)
        }
    }

    /// Two quick rising blips (880 → 1175 Hz), centered.
    private static func chirp(at t: Double) -> Double {
        func blip(_ t: Double, _ frequency: Double) -> Double {
            t > 0 && t < 0.06 ? sin(2 * .pi * frequency * t) * sin(.pi * t / 0.06) : 0
        }
        return 0.2 * (blip(t, 880) + blip(t - 0.08, 1175))
    }

    /// Two rising bell notes, centered.
    private static func ding(at t: Double) -> Double {
        var s = sin(2 * .pi * 1046.5 * t) * exp(-t / 0.15)
        if t > 0.12 { s += sin(2 * .pi * 1568 * (t - 0.12)) * exp(-(t - 0.12) / 0.3) }
        return 0.25 * s
    }
}
