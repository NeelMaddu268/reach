#!/bin/zsh
# Build Reach, install it on the connected iPhone, and launch it.
set -euo pipefail
cd "${0:A:h}/.."

json=$(mktemp)
xcrun devicectl list devices --json-output "$json" >/dev/null
# A paired iPhone, preferring one that's connected right now (cable or Wi-Fi tunnel up).
device=$(python3 -c '
import json, sys
phones = [d for d in json.load(open(sys.argv[1]))["result"]["devices"]
          if d.get("hardwareProperties", {}).get("platform") == "iOS"
          and d["hardwareProperties"].get("deviceType") == "iPhone"
          and d["hardwareProperties"].get("reality") == "physical"
          and d.get("connectionProperties", {}).get("pairingState") == "paired"]
phones.sort(key=lambda d: d["connectionProperties"].get("tunnelState") != "connected")
print(phones[0]["hardwareProperties"]["udid"] if phones else "")
' "$json")
rm -f "$json"
[[ -n "$device" ]] || { echo "No paired iPhone found." >&2; exit 1; }

xcodebuild -project Reach.xcodeproj -scheme Reach -destination "id=$device" -derivedDataPath build/DeviceData \
  -allowProvisioningUpdates build -quiet
xcrun devicectl device install app --timeout 90 --device "$device" build/DeviceData/Build/Products/Debug-iphoneos/Reach.app >/dev/null
echo "Installed."
xcrun devicectl device process launch --timeout 30 --device "$device" --terminate-existing com.neelmaddu.reach >/dev/null 2>&1 \
  && echo "Launched." || echo "Couldn't launch (phone locked?): open Reach on the phone."
