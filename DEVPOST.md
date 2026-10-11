# Reach: Devpost draft

> Draft for the Hacklanta II submission. Edit freely; team names and links still to add.

## Inspiration

Apps for blind people can already describe a scene: "there are keys on the table." But knowing your keys are *somewhere on the table* doesn't get them into your hand. Sighted people take the last foot of reaching for granted. We wanted to close that gap: not just tell you what's there, but guide your hand to it.

## What it does

Reach is an iPhone app worn on a chest mount, with earbuds.

- **"Find my keys."** Hold anywhere on the screen and say it. Reach finds the keys in the camera view and says where they are: *"Found keys, out and to the right."*
- **Your hand gets guided there.** A sonar ticks in the ear on the keys' side, faster as your hand gets closer, and turns into a steady tone when your hand is right above them. If your hand heads the wrong way or stalls, Reach nudges you ("Out and right."). If you're hovering above the object, it says "Lower."
- **It knows when you've touched it.** Using the iPhone's LiDAR depth sensor, Reach knows how high your fingertip is, not just where it is in the picture. It only says *"Got them."* (with a ding) when your finger is actually on the object.
- **"What's on the table?"** Reach names everything in front of you, left to right: *"I see 4 things: keys, blue mug, phone and pill bottle."* Then it becomes **touch to explore**. Run your hand over the table and Reach names each object as your fingertip lands on it, like braille for the tabletop. "Find the mug" afterwards is instant.
- **"What's this?"** Hold something up and ask. Reach reads it and answers in one sentence: *"It's ibuprofen, 200 mg tablets, expiring April 2027."*

The phone screen (mirrored for the judges) shows what Reach sees: the object's box, your fingertip, the guidance line, and captions of everything it says.

## How we built it

- **Finding:** the camera frame plus "keys" goes to **Gemini 3.6 Flash**, which returns a bounding box as structured JSON in about 1.4 s. A table scan asks for every object at once.
- **Pinning:** **ARKit** world tracking pins that box to the table in 3D, using the phone's position at the moment the photo was taken. The target stays locked on the real object while your body moves.
- **Hand tracking:** **Vision** hand pose finds the index fingertip at 60 fps. **LiDAR depth** places it in 3D, so guidance happens in real distances on the table, including height above the object.
- **Sound:** a custom **AVAudioEngine** synth produces the sonar (panned ticks, pitch, solid tone) and the lock ding.
- **Voice:** **ElevenLabs** (Eleven v4 Turbo). Every fixed phrase is pre-generated so it plays instantly; dynamic phrases are spoken live and cached.
- **Listening:** push-to-talk with **on-device speech recognition**.
- **"What's this?":** **Vision** text recognition, then **Claude Opus 5.5** writes one plain spoken sentence.

## Challenges we ran into

- **The target drifted.** Our first version used a 2D image tracker, which slid off the object whenever the wearer moved. Switching to ARKit world anchoring fixed it for good.
- **Losing the finger.** Busy backgrounds and fast moves made the hand detector drop the fingertip. Autofocus hunting as the hand moved in made it worse. We lock focus on the target, cap the shutter speed, run at 60 fps, and estimate the tip from the knuckles when it's unclear.
- **Talking too much.** We tried spoken step-by-step directions with inch counts ("Right, 6 inches"). In testing it felt confusing and chatty. The final design lets the sonar lead and speaks only when you need correcting.
- **Hovering vs. touching.** From a chest camera, a hand above the keys looks like it's on them. LiDAR depth fixed that.

## Accomplishments that we're proud of

- Guiding a hand to one specific object on a cluttered table with sound alone. (Confirm with a blindfolded run before submitting.)
- The box stays glued to the object while the wearer leans and reaches.

## What we learned

- For guidance, less speech is better: continuous sound for "where", words only for corrections.
- Pinning things in 3D (ARKit) beats tracking them in 2D for anything that doesn't move.

## What's next

- Running object finding on-device for speed and privacy.
- Guiding to things beyond tabletops: shelves, fridges, dropped items on the floor.
- Haptic guidance through an Apple Watch.

## Built with

Swift, SwiftUI, ARKit, LiDAR scene depth, SceneKit, Vision (hand pose, text recognition), Speech, AVFoundation (AVAudioEngine), Google Gemini API (Gemini 3.6 Flash), Anthropic Claude API (Claude Opus 5.5), ElevenLabs (Eleven v4 Turbo), XcodeGen. AI coding assistant: Claude Code.

---

## Demo script (for us, not Devpost)

1. Phone on the chest mount, earbuds in, screen mirrored to the laptop. The wearer is blindfolded.
2. Launch. Reach says: "Hold to talk, then say find and an object."
3. Hold, say **"find my keys"**, let go. Point the judges at the screen: the box appears on the keys, and the caption reads "Found keys, out and to the right."
4. The wearer reaches out. Point at the green fingertip dot and the yellow line on screen while the ticks speed up.
5. Ding, "Got them." The box turns green.
6. Ask **"what's on the table?"** Cyan labeled boxes appear on every object. The wearer sweeps a hand across the table and Reach names each object as the finger lands on it. Then say **"find the mug"**: guidance starts instantly, with no Gemini wait.
7. The wearer picks up a pill bottle or snack, holds it up, and asks **"what's this?"** The caption shows the answer.
8. Backup if the venue Wi-Fi is slow: in Tuning, set "What's this" to Haiku. To find without voice, tap an object on screen.
