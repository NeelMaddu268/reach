import AVFoundation
import os

/// Earbud guidance: a sine tone whose pan, pitch and beep cadence come from `Guide`, a lock ding, and speech.
final class AudioGuide {
    struct Tone: Equatable {
        var frequency = 440.0
        var pan = 0.0         // -1 left … 1 right
        var beepPeriod = 0.0  // seconds per beep (half on, half off); 0 = solid tone
        var volume = 0.0
        static let silent = Tone()
    }

    private let engine = AVAudioEngine()
    private let synth = Synth()
    private let speech = AVSpeechSynthesizer()
    private var clipPlayer: AVAudioPlayer?

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

    /// Safe to call from any thread, every frame.
    func setTone(_ tone: Tone) {
        synth.shared.withLock { $0.tone = tone }
    }

    func ding() {
        synth.shared.withLock { $0.dings += 1 }
    }

    /// Silences the guidance tone (not the ding or speech), e.g. while listening.
    func setMuted(_ muted: Bool) {
        synth.shared.withLock { $0.muted = muted }
    }

    /// Plays Audio/Clips/<clip>.mp3 when it's bundled, otherwise speaks `text`. Call on main.
    func say(_ text: String, clip: String? = nil) {
        if let clip, let url = Bundle.main.url(forResource: clip, withExtension: "mp3"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            clipPlayer = player
            player.play()
            return
        }
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }

    /// A short spoken direction; skipped while something else is being said. Call on main.
    func cue(_ text: String) {
        guard !speech.isSpeaking, clipPlayer?.isPlaying != true else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.58
        speech.speak(utterance)
    }
}

/// Render-thread synth. Targets arrive through `shared`; everything else is touched only on the render thread.
private final class Synth {
    struct Shared {
        var tone = AudioGuide.Tone.silent
        var dings = 0
        var muted = false
    }

    static let sampleRate = 48_000.0
    let shared = OSAllocatedUnfairLock(initialState: Shared())

    private var target = Shared()
    private var dingsPlayed = 0
    private var phase = 0.0, frequency = 440.0, pan = 0.0, gain = 0.0
    private var beepClock = 0.0
    private var dingTime = 10.0

    func render(frameCount: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        if let latest = shared.withLockIfAvailable({ $0 }) { target = latest }  // never block the audio thread
        if target.dings != dingsPlayed {
            dingsPlayed = target.dings
            dingTime = 0
        }
        let tone = target.muted ? .silent : target.tone
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
        let dt = 1 / Self.sampleRate
        let glide = 1 - exp(-dt / 0.03)     // ~30 ms pitch/pan glide
        let envelope = 1 - exp(-dt / 0.004) // ~4 ms beep edges, no clicks

        for i in 0..<frameCount {
            frequency += (tone.frequency - frequency) * glide
            pan += (tone.pan - pan) * glide
            beepClock += dt
            if tone.beepPeriod > 0, beepClock >= tone.beepPeriod { beepClock = 0 }
            let on = tone.beepPeriod == 0 || beepClock < tone.beepPeriod / 2
            gain += ((on ? tone.volume : 0) - gain) * envelope

            phase += 2 * .pi * frequency * dt
            if phase > 2 * .pi { phase -= 2 * .pi }
            let sample = 0.4 * gain * sin(phase)
            let angle = (pan + 1) * .pi / 4  // equal-power pan
            let ding = dingTime < 1.5 ? Self.ding(at: dingTime) : 0
            dingTime += dt
            left[i] = Float(sample * cos(angle) + ding)
            right[i] = Float(sample * sin(angle) + ding)
        }
    }

    /// Two rising bell notes, centered.
    private static func ding(at t: Double) -> Double {
        var s = sin(2 * .pi * 1046.5 * t) * exp(-t / 0.15)
        if t > 0.12 { s += sin(2 * .pi * 1568 * (t - 0.12)) * exp(-(t - 0.12) / 0.3) }
        return 0.25 * s
    }
}
