# Reach: agent notes

Reach is an iOS app that guides a blind user's hand to an object on a table. The user says "find my keys" → Gemini locates the keys in the camera frame → Vision tracks the object and the user's index fingertip every frame → audio in earbuds guides the hand (pan = left/right, pitch/beep rate = closeness) → a ding and "Got them" when the fingertip reaches it. "What's this?" while holding something → text recognition + Gemini → read aloud.

Demo setup: a blindfolded teammate wears the phone on a chest mount aimed down at a cluttered table, and the phone screen is mirrored to a laptop for the judges. Built for Hacklanta II (Devpost due 9 AM Sun; feature freeze 10 PM Sat).

## Project

- `project.yml` (XcodeGen) → `xcodegen generate` → `Reach.xcodeproj` (gitignored). `Reach/` is a synced folder, so new files show up without regenerating. Re-run xcodegen only when `project.yml` changes.
- iOS 18+, iPhone only, portrait. Swift 5 language mode. No third-party packages.
- Secrets: `Config/Secrets.xcconfig` (gitignored) → Info.plist `GEMINI_API_KEY` → `AppConfig.geminiAPIKey`.

## Modules (one folder each, under `Reach/`)

- `App/`: `ReachApp`, `AppModel` (owns the camera and the per-frame pipeline), `AppConfig`.
- `Camera/CameraService`: back wide camera, 1280×720 @ 30 fps, portrait BGRA buffers on a serial frame queue. `CameraPreview`: aspect-fit preview layer.
- `Perception/HandTracker`: `VNDetectHumanHandPoseRequest` → index fingertip (confidence-gated, smoothed, held through short dropouts).
- `Perception/ObjectTracker`: `VNTrackObjectRequest` seeded from a normalized box; reports box + confidence; flags "lost"; holds the box still while the fingertip is near it (the hand would drag the tracker).
- `Perception/ObjectLocator`: Gemini `generateContent` with the JPEG frame + query → label + `box_2d` → normalized rect. *(step 3)*
- `Guidance/Guide`: state machine idle → locating → guiding → locked (→ lost → relocate), plus the fingertip → lock-zone math. `Tuning` holds the live-adjustable feel knobs.
- `Audio/AudioGuide`: AVAudioEngine sine tone with pan, pitch and beep cadence, plus a lock ding and speech (with an Audio/Clips/ hook).
- `Voice/Commands`: push-to-talk, on-device `SFSpeechRecognizer`, parses "find (my) X", "what's this/that", "stop". *(step 3)*
- `Reader`: `VNRecognizeTextRequest` + Gemini one-sentence answer → speech. *(step 4)*
- `UI/`: `ContentView` (+ `TargetPicker`: tap or drag to seed), `DebugOverlay` (judge view), `StatusHUD`, `TuningSheet`.

## Conventions

- **Image space:** every point/rect passed between modules is normalized `[0, 1]` with the **origin at the top left** of the portrait 720×1280 frame. Image-up ≈ away from the user's body. Convert at the boundary: Vision uses a bottom-left origin; Gemini `box_2d` is `[ymin, xmin, ymax, xmax]` in 0–1000.
- Per-frame perception runs on the camera frame queue. Observable UI state is written only on the main queue.
- The preview is aspect-fit, so `ImageSpace.fitRect(in:)` maps image space to the screen for both drawing and taps.

## Build check

```bash
xcodegen generate
xcodebuild -project Reach.xcodeproj -scheme Reach -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build -quiet
```

## Rules

- You can't run the camera; Neel tests on a real iPhone. Compile-check with xcodebuild against the iOS simulator after each step (the camera won't work there, which is fine).
- Light verification: no subagents, no review passes, no test suites. A few unit tests for the guidance math only if they're quick. If the build fails twice on the same thing, stop and tell Neel.
- Never commit secrets. List the libraries and AI tools used in the README.
- Small, readable Swift. No third-party packages unless clearly needed.
- Build in this order. Commit and push after each step, then say exactly what to test on the phone:
  1. Skeleton + camera preview + a live fingertip dot.
  2. GATE by 3:00 PM Sat: tap an object on screen to seed the tracker (no Gemini) → audio guides the hand to it → lock ding. Tune the feel together: smoothing, pan curve, pitch range, lock radius.
  3. Gemini "find X" by voice → seeds the tracker; re-locate when lost.
  4. The "what's this?" reader.
  5. Polish: overlay, one-line onboarding prompt ("Hold to talk, then say 'find' and an object"), ElevenLabs clips, app icon.
