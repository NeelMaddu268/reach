#!/bin/zsh
# Build Reach, install it on the connected iPhone, and launch it.
set -euo pipefail
cd "${0:A:h}/.."

json=$(mktemp)
xcrun devicectl list devices --json-output "$json" >/dev/null
device=$(python3 -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    p = d.get("hardwareProperties", {})
    if p.get("platform") == "iOS" and p.get("deviceType") == "iPhone" and p.get("reality") == "physical" \
       and d.get("connectionProperties", {}).get("tunnelState") == "connected":
        print(p["udid"]); break
' "$json")
rm -f "$json"
[[ -n "$device" ]] || { echo "No connected iPhone found." >&2; exit 1; }

xcodebuild -project Reach.xcodeproj -scheme Reach -destination "id=$device" -derivedDataPath build/DeviceData \
  -allowProvisioningUpdates build -quiet
xcrun devicectl device install app --device "$device" build/DeviceData/Build/Products/Debug-iphoneos/Reach.app >/dev/null
xcrun devicectl device process launch --device "$device" --terminate-existing com.neelmaddu.reach
