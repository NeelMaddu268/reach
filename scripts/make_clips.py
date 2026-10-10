#!/usr/bin/env python3
"""Pre-generates the fixed spoken phrases as ElevenLabs clips in Reach/Audio/Clips/, so they play instantly.

Voice and model come from Reach/Audio/ElevenLabs.swift; distances and directions from Reach/Guidance/Guide.swift;
the key from Config/Secrets.xcconfig. Phrases without a clip are spoken live (and cached on the phone).
Usage: scripts/make_clips.py [--force]
"""
import json, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLIPS = ROOT / "Reach/Audio/Clips"

# Fixed sentences the app says (AppModel / Guide). Keep in sync when adding new ones.
FIXED = [
    "Got it.", "Got them.", "I can't see your hand.", "I didn't hear anything.",
    "Say find, then an object.", "I couldn't reach Gemini.", "Reading isn't ready yet.",
]


def swift_constant(path, name):
    return re.search(rf'static let {name} = (.+)', (ROOT / path).read_text()).group(1)


def slug(text):  # must match ElevenLabs.slug in Swift
    return "-".join(re.findall(r"[a-z0-9]+", text.lower()))


def inches(step):
    return "1 inch" if step == 1 else f"{step} inches"


def phrases():
    steps = json.loads(swift_constant("Reach/Guidance/Guide.swift", "inchSteps"))
    directions = json.loads(swift_constant("Reach/Guidance/Guide.swift", "directions"))
    return FIXED + [f"{d}, {inches(s)}." for d in directions for s in steps]


def main():
    key = re.search(r"^ELEVENLABS_API_KEY *= *(\S+)", (ROOT / "Config/Secrets.xcconfig").read_text(), re.M)
    if not key:
        sys.exit("Set ELEVENLABS_API_KEY in Config/Secrets.xcconfig")
    voice = json.loads(swift_constant("Reach/Audio/ElevenLabs.swift", "voiceID"))
    model = json.loads(swift_constant("Reach/Audio/ElevenLabs.swift", "model"))
    CLIPS.mkdir(parents=True, exist_ok=True)
    todo = [p for p in phrases() if "--force" in sys.argv or not (CLIPS / f"{slug(p)}.mp3").exists()]

    def make(text):
        # curl, not urllib (python.org builds ship without root certificates). The key goes in on stdin,
        # so it never shows up in process lists or error messages.
        for attempt in range(3):
            result = subprocess.run(
                ["curl", "-sSf", "--max-time", "30", "-o", str(CLIPS / f"{slug(text)}.mp3"),
                 "-H", "@-", "-H", "Content-Type: application/json",
                 "-d", json.dumps({"text": text, "model_id": model}),
                 f"https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format=mp3_44100_128"],
                input=f"xi-api-key: {key.group(1)}\n", text=True, capture_output=True)
            if result.returncode == 0:
                return text
        raise SystemExit(f"Failed: {text!r} (curl exit {result.returncode}: {result.stderr.strip()})")

    with ThreadPoolExecutor(2) as pool:
        for text in pool.map(make, todo):
            print("made", text)
    print(f"{len(todo)} new clips, {len(list(CLIPS.glob('*.mp3')))} total in {CLIPS.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
