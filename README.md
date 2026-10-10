# Reach

Reach guides a blind person's hand to an object on a table.

Say "find my keys." Reach locates the keys in the camera frame, tracks them and your index fingertip every frame, and steers your hand with sound in your earbuds: stereo pan for left and right, pitch and beep rate for how close you are. You hear a ding and "Got them" when your finger reaches them. Hold something up and ask "what's this?" to hear what it is.

Built at Hacklanta II.

## Run it

You need a Mac with Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an iPhone running iOS 18 or later. The camera doesn't work in the simulator.

```bash
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
xcodegen generate
open Reach.xcodeproj
```

1. Put your Gemini API key in `Config/Secrets.xcconfig` (`GEMINI_API_KEY = ...`, no quotes).
2. In Xcode, select the **Reach** target → **Signing & Capabilities** and choose your team. To keep the team after a `project.yml` change, set `DEVELOPMENT_TEAM` in `Secrets.xcconfig` instead.
3. Plug in your iPhone, select it as the run destination, and press Run.

The status line at the top shows hand detection, fps, latency, and whether the API key was found (`key ✓`).

## How it works

| Module | What it does |
| --- | --- |
| `Camera/CameraService` | ARKit world tracking: camera frames plus how the phone moves |
| `Perception/HandTracker` | Vision hand pose → index fingertip, confidence-gated and smoothed |
| `Perception/ObjectAnchor` | Pins the found object to the table in 3D, so its box stays put while the phone moves |
| `Perception/ObjectLocator` | Gemini finds "X" in a frame and returns a bounding box |
| `Guidance/Guide` | State machine (idle → locating → guiding → locked), the fingertip-to-object vector, and spoken cues |
| `Audio/AudioGuide` | Synthesized tone: pan, pitch, and beep cadence from the vector, a lock ding, and speech |
| `Voice/Commands` | Push-to-talk with on-device speech recognition: "find …", "what's this?", "stop" |
| `Reader` | Text recognition + Gemini → one spoken sentence about what you're holding |

### Status

- [x] 1. Camera preview + live fingertip dot
- [x] 2. Tap to seed the tracker → audio guidance → lock ding
- [x] 3. "Find X" by voice via Gemini
- [ ] 4. "What's this?" reader
- [ ] 5. Polish: onboarding, voice clips, app icon

## Built with

- **Apple frameworks:** SwiftUI, ARKit + SceneKit (world tracking, plane detection, camera view), AVFoundation (AVAudioEngine, AVSpeechSynthesizer), Vision (hand pose, text recognition), Speech (on-device recognition)
- **Google Gemini API** (Flash model): object localization and "what's this?" answers
- **ElevenLabs:** pre-generated voice clips
- **XcodeGen:** project generation
- **AI coding tools:** Claude Code (Claude Opus 5.5) wrote most of the code
- No third-party Swift packages
