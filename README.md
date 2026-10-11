# Reach

Reach guides a blind person's hand to an object on a table.

Wear the iPhone on a chest mount with earbuds in. Say "find my keys": Reach finds them, pins them in 3D, and steers your hand with a sonar in your ears (ticks on the side of the keys, faster as you get closer, a steady tone when you're right above them), plus a word when you need correcting ("Out and right.", "Lower."). It dings and says "Got them" only when your fingertip actually touches the keys, using the LiDAR depth sensor. Ask "what's on the table?" to hear everything in front of you, then run your hand over the table and Reach names whatever your finger touches. Hold something up and ask about it: "what's this?", "does this have peanuts?".

Built at Hacklanta II.

## Features

Always on:

- **Find by voice:** "find my keys" → Gemini finds the keys → ARKit pins them to the table → sonar + spoken nudges → ding, "Got them."
- **Table scan + touch to explore:** "what's on the table?" names every object left to right and pins each one. Sweeping a hand over the table names the object under the fingertip. "Find" then goes straight to a scanned object.
- **Judge view:** the mirrored screen shows the camera, labeled boxes, the fingertip, the guidance line, and captions of everything Reach says.

Switchable in **Tuning (slider button) → Features**, saved across launches:

| Switch | Default | What it does |
| --- | --- | --- |
| Dead-air killer | on | A chirp the moment a command is heard, big captions of what you said and what Reach said, "Still looking." when Gemini is slow |
| Network failure path | on | Never silent: "I can't reach the internet. Tap the object on screen and I'll guide you."; the iPhone voice takes over instantly if the live voice is slow |
| Siri shortcuts | on | "Hey Siri, Reach find" → "What should I find?" → "my keys" → Reach opens and guides; "Hey Siri, what's on the table in Reach" → opens and scans. Off = Siri just opens the app |
| Judge view polish | on | Boxes pop in as results arrive, a Gemini latency chip, one-line status, captions at the bottom |
| Ask about held items | on | "what's this?" and questions about the held item ("is this decaf?", "how many do I take?"), answered by Gemini only from what's printed. One follow-up. Off: "what's this?" uses the Claude reader. |
| Allergies | "peanuts" | If the label's printed text mentions one, the answer starts with "Careful, the label says it contains peanuts." |
| Reach timer | on | "Reached in 4.8 s" after each grab, plus a session tally |
| Minimap | off | Top-down radar of the table: pinned objects, the hand, rings pulsing with the sonar |
| Obstacle warning | off | "Careful, mug in the way." when a scanned object sits on the hand's path (needs a scan) |
| Where did I leave… | off | "Where are my keys?" answers from where Reach last saw them, then offers to guide |
| This is my … | off | "This is my mug" saves a reference photo; "find my mug" then looks for that one |
| Auto flashlight | off | Flashlight on in a dark room, off when it's bright again |
| Español | off | Spanish speech recognition, Spanish lines, live Spanish voice |
| Money reader | off | "How much money is this?": "That's a twenty, two fives and a one: thirty-one dollars." Each bill boxed on screen; a bill it can't clearly read is said, never guessed |
| Medication check | off | "This is my lisinopril" also saves the label text; "is this my lisinopril?" → "Yes, this is your lisinopril, 10 mg." or "Careful, this isn't your lisinopril. The label says …" |
| Watch mode | off | "Tell me if anything changes": re-scans every ~3 s and says what appeared, moved or went ("Someone put a cup down to your right.") |

With every switch off, find → guide → lock works exactly as it did before the switches existed (tag `demo-v2`).

### Voice commands

Hold anywhere on the screen (or the blue button), speak, let go.

| English | Español |
| --- | --- |
| "find my keys", "look for the mug" | "encuentra mis llaves", "busca la taza" |
| "what's on the table?" | "¿qué hay en la mesa?" |
| "what's this?", "is this decaf?", "how many do I take?" | "¿qué es esto?", "¿tiene cacahuates?" |
| "where are my keys?", "where did I leave my wallet?" | "¿dónde están mis llaves?" |
| "this is my mug" | "esta es mi taza" |
| "how much money is this?", "count my money" | "¿cuánto dinero hay?", "cuenta mi dinero" |
| "is this my lisinopril?" | "¿es mi lisinopril?" |
| "tell me if anything changes", "stop watching" | "avísame si algo cambia", "deja de vigilar" |
| "stop" | "para" |

## Run it

You need a Mac with Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an iPhone with LiDAR (a Pro model, iPhone 12 Pro or later) on iOS 18 or later. The camera doesn't work in the simulator.

```bash
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
xcodegen generate
open Reach.xcodeproj
```

1. Put your API keys in `Config/Secrets.xcconfig` (no quotes): `GEMINI_API_KEY`, `ELEVENLABS_API_KEY`, and optionally `ANTHROPIC_API_KEY` (plus `ANTHROPIC_WORKSPACE_ID` if the key isn't scoped to a workspace), which is used only when "Ask about held items" is off.
2. Set `DEVELOPMENT_TEAM` in `Secrets.xcconfig`, or pick your team in Xcode → Reach target → Signing & Capabilities.
3. Run on your iPhone from Xcode, or with `scripts/deploy.sh` (builds, installs and launches on a paired iPhone, over cable or Wi-Fi).

### Scripts

- `scripts/deploy.sh`: build, install and launch on the paired iPhone.
- `scripts/make_clips.py`: pre-generates the fixed English phrases as ElevenLabs clips in `Reach/Audio/Clips/`. Re-run after changing phrases, the voice or the model.
- `scripts/make_icon.swift`: draws the app icon.

## How it works

| Module | What it does |
| --- | --- |
| `Camera/CameraService` | ARKit world tracking (60 fps, LiDAR depth), focus lock on the target, shutter cap against blur, torch |
| `Camera/AutoTorch` | Flashlight on in the dark, compensating for its own light |
| `Perception/HandTracker` | Vision hand pose → index fingertip, smoothed, robust to clutter |
| `Perception/FrameGeometry` | LiDAR depth → the fingertip in 3D, including its height above the object |
| `Perception/ObjectAnchor` | Pins a found object to the table in 3D, from the pose of the photo Gemini saw |
| `Perception/Gemini`, `ObjectLocator` | Gemini calls: find one object, scan the table, with an optional reference photo |
| `Perception/MyObjects` | Reference photos of the user's own things |
| `Guidance/Guide` | Sonar, "speak only when needed" nudges, and the touch lock |
| `Audio/AudioGuide`, `ElevenLabs` | Synthesized sonar and ding; ElevenLabs voice (bundled clips, then live and cached, then the iPhone voice) |
| `Voice/Commands` | Push-to-talk, on-device speech recognition, English and Spanish commands |
| `Reader/Reader` | Held-item questions (Vision text recognition + Gemini, allergy warning), or the Claude reader |
| `Reader/MoneyReader`, `MedicationCheck` | Counting bills it can clearly read; comparing a pill bottle's printed label with the saved one |
| `UI/` | Camera view, overlay (animated boxes, latency chip), captions, reach timer, minimap, tuning sheet |

## Built with

- **Apple frameworks:** SwiftUI, ARKit + SceneKit (world tracking, plane detection, LiDAR scene depth), Vision (hand pose, text recognition), Speech (on-device recognition), AVFoundation (AVAudioEngine, AVSpeechSynthesizer)
- **Google Gemini API** (Gemini 3.6 Flash by default; 3.5 Flash-Lite and 3.8 Flash selectable): finding objects, table scans, held-item questions, money, medication checks, "this is my …" references; watch mode uses 3.5 Flash-Lite
- **Anthropic Claude API** (Claude Opus 5.5 by default): the "what's this?" reader when "Ask about held items" is off
- **ElevenLabs** (Eleven v4 Turbo, premade voice "Sarah"): the app's voice
- **XcodeGen:** project generation
- No third-party Swift packages

## Disclosures

- **AI coding tools:** Claude Code (Claude Opus 5.5) wrote most of the code, with the team testing on device and directing the design.
- **AI at runtime:** object finding, table scans and answers come from Google Gemini (and Anthropic Claude for the optional reader); the voice is ElevenLabs. These can be wrong.
- **What leaves the phone:**
  - **Gemini:** camera frames (JPEG), and reference photos when you use "this is my …".
  - **Anthropic:** frames only from the optional Claude reader.
  - **ElevenLabs:** the text Reach speaks.
  - **Stays on the phone:** speech recognition, hand tracking, depth, AR tracking and text recognition all run on the device. Reference photos and the speech cache are stored only on the phone.
- **Not a medical device:**
  - Allergy and dosing answers only repeat what's printed on the label, and Reach never says something is safe or allergen-free.
  - The medication check compares printed labels only. It says when it can't confirm, and it never replaces a pharmacist.
  - The money reader only counts bills whose denomination it can clearly see, and says when it can't read one.
  - Labels can be misread, so confirm with a sighted person or a pharmacist before eating or taking medicine.
- **Demo build:** API keys are compiled into the app, which is fine for a hackathon demo on our own phone but not for distribution.
