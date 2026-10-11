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
- **Ask about what you're holding.** "Is this decaf?", "how many do I take?". Reach answers only from what's printed on the label. If the label mentions one of your allergies, it leads with *"Careful, the label says it contains peanuts."* It never tells you something is safe.
- **Count your money.** "How much money is this?" → *"That's a twenty, two fives and a one: thirty-one dollars."* It works for bills held up or spread on the table, and it says when it can't read one rather than guessing.
- **Check your medicine.** Say "this is my lisinopril" once. Later, "is this my lisinopril?" either confirms it with the strength printed on the label, or warns: *"Careful, this isn't your lisinopril. The label says metformin 500 mg."*
- **Watch the table.** "Tell me if anything changes" → *"Someone put a cup down to your right."*
- **Never leaves you in silence.** A chirp confirms every command instantly, and slow answers get "Still looking." Without internet, Reach tells you so and offers tap-to-guide.
- **"What's this?"** Hold something up and ask. Reach reads it and answers in one sentence: *"It's ibuprofen, 200 mg tablets, expiring April 2027."*

The phone screen (mirrored for the judges) shows what Reach sees: the object's box, your fingertip, the guidance line, and captions of everything it says.

## How we built it

- **Finding:** the camera frame plus "keys" goes to **Gemini 3.6 Flash**, which returns a bounding box as structured JSON in about 1.4 s. A table scan asks for every object at once.
- **Pinning:** **ARKit** world tracking pins that box to the table in 3D, using the phone's position at the moment the photo was taken. The target stays locked on the real object while your body moves.
- **Hand tracking:** **Vision** hand pose finds the index fingertip at 60 fps. **LiDAR depth** places it in 3D, so guidance happens in real distances on the table, including height above the object.
- **Sound:** a custom **AVAudioEngine** synth produces the sonar (panned ticks, pitch, solid tone) and the lock ding.
- **Voice:** **ElevenLabs** (Eleven v4 Turbo). Every fixed phrase is pre-generated so it plays instantly; dynamic phrases are spoken live and cached.
- **Listening:** push-to-talk with **on-device speech recognition**.
- **Questions about a held item:** **Vision** reads the label on the phone; **Gemini** answers only from what's printed. Allergy warnings are checked in code as well as by the model, and reassuring sentences ("safe", "allergen-free") are filtered out.

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

Swift, SwiftUI, ARKit, LiDAR scene depth, SceneKit, Vision (hand pose, text recognition), Speech, AVFoundation (AVAudioEngine), Google Gemini API (Gemini 3.6 Flash), Anthropic Claude API (Claude Opus 5.5, optional reader), ElevenLabs (Eleven v4 Turbo), XcodeGen. AI coding assistant: Claude Code.

---

## Demo script (for us, not Devpost)

**Before:** phone on the chest mount, earbuds in, screen mirrored to the laptop, wearer blindfolded. On the table: keys, a mug between the wearer and the keys, a snack whose label mentions peanuts, and a $20, two $5s and a $1. In Tuning → Features:
- Check that **Dead-air killer**, **Network failure path**, **Judge view polish**, **Ask about held items** and **Reach timer** are on (the defaults), and that Allergies says "peanuts".
- Turn on **Minimap**, **Obstacle warning** and **Money reader**.

1. **Launch.** Reach says: "Hold to talk, then say find and an object."
2. **Table scan.** Hold, say **"what's on the table?"**, let go.
   - Chirp, and a big caption shows what was said.
   - Reach says "I see 5 things, left to right: …". Cyan boxes pop in one after another, the Gemini chip shows the time, and the minimap fills in.
   - The wearer sweeps a hand across the table and Reach names each object as the fingertip lands on it.
3. **Find the keys.** Say **"find my keys"**. It's instant, because the keys were scanned: "Found keys, out and to the right."
   - The ticks speed up and the minimap rings pulse.
   - If the hand heads for the mug, Reach says "Careful, mug in the way."
   - Ding, "Got them.", and a big **"Reached in X.X s"**.
4. **Allergy snack.** The wearer holds up the snack and asks **"is this okay for me to eat?"** Reach says *"Careful, the label says it contains peanuts. …"*
5. **Count money.** The wearer spreads the bills and asks **"how much money is this?"** Each bill gets a green amount box and Reach says *"That's a twenty, two fives and a one: thirty-one dollars."*
6. **Encore (optional):**
   - With Medication check on: "is this my ibuprofen?"
   - With Watch mode on: "tell me if anything changes", then someone sets a cup down.
   - With Español on: "encuentra mis llaves".
7. **Backup:** if the Wi-Fi drops, Reach says it can't reach the internet. Tap the object on screen and it still guides. For speed, use Tuning → Models → Find: 3.5 Flash-Lite.
