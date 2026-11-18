#!/usr/bin/env bash
# Screenshots of the iPad layout, one per shape: builds the `PadTour` UI tests,
# rotates the simulator through portrait, landscape, sidebar and board states,
# and unpacks the attachments it takes.
#
#   ios/scripts/pad-shots.sh                          # iPad Pro 13-inch, every test
#   ios/scripts/pad-shots.sh PadTour/testPadBoard     # one test
#   DEVICE="iPad mini (A17 Pro)" OUT=/tmp/shots ios/scripts/pad-shots.sh
#
# Needs the mock server running (`python3 demos/app/mock_server.py`) and Xcode's
# simulators: the app is pointed at http://127.0.0.1:8790 by the tests.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${DEVICE:-iPad Pro 13-inch (M5)}"
OUT="${OUT:-/tmp/pad-shots}"
RESULT="${RESULT:-/tmp/pad-shots.xcresult}"

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
wanted = sys.argv[1]
data = json.load(sys.stdin)["devices"]
for runtime in sorted(data, reverse=True):
    for device in data[runtime]:
        if device["name"] == wanted:
            print(device["udid"])
            raise SystemExit
raise SystemExit("no simulator named " + wanted)
' "$DEVICE")"

echo "==> $DEVICE ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "==> building the tour"
xcodebuild build-for-testing -project Unrager.xcodeproj -scheme UnragerDemo \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO >/dev/null

only=()
if [[ $# -gt 0 ]]; then
  for test in "$@"; do only+=(-only-testing:"UnragerDemoTour/$test"); done
else
  only=(-only-testing:"UnragerDemoTour/PadTour")
fi

echo "==> shooting"
rm -rf "$RESULT" "$OUT"
xcodebuild test-without-building -project Unrager.xcodeproj -scheme UnragerDemo \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO "${only[@]}" -resultBundlePath "$RESULT" >/tmp/pad-shots.log 2>&1 || true
grep -E "Test Case .* (passed|failed)" /tmp/pad-shots.log | tail -10 || true

xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null
python3 - "$OUT" <<'PY'
import json, os, shutil, sys
out = sys.argv[1]
manifest = json.load(open(os.path.join(out, "manifest.json")))
entries = [a for test in manifest for a in test.get("attachments", [])]
for entry in entries:
    name, file = entry.get("suggestedHumanReadableName"), entry.get("exportedFileName")
    if name and file and file.endswith(".png") and not name.startswith("UI Snapshot"):
        shutil.copy(os.path.join(out, file), os.path.join(out, name.split("_0_")[0] + ".png"))
PY
ls "$OUT" | grep -E "^[0-9]" | sort
