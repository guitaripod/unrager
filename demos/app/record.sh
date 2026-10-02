#!/bin/bash
# Records the demo scenes on a Mac with the "Unrager QA" simulator booted:
#   demos/app/record.sh 01Feed 02Filter ...    (scene = test name without "testScene")
# Needs the mock server running (`python3 mock_server.py`) and the UI tests built
# once with `xcodebuild build-for-testing -scheme UnragerDemo`.
set -uo pipefail
UDID="${UNRAGER_QA_UDID:-89909A2B-B042-4471-A0A8-01AD67B12708}"
OUT="${DEMO_OUT:-$HOME/demo-out}"
mkdir -p "$OUT"
cd "$(dirname "$0")/../../ios"
for scene in "$@"; do
  xcrun simctl terminate "$UDID" com.guitaripod.unrager >/dev/null 2>&1
  xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/$scene.mp4" >/dev/null 2>&1 &
  recorder=$!
  sleep 1.5
  xcodebuild test-without-building -project Unrager.xcodeproj -scheme UnragerDemo \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
    -only-testing:"UnragerDemoTour/DemoTour/testScene$scene" > "$OUT/$scene.log" 2>&1
  status=$(grep -E "Test Case .* (passed|failed)" "$OUT/$scene.log" | tail -1)
  sleep 1
  kill -INT "$recorder" 2>/dev/null
  wait "$recorder" 2>/dev/null
  echo "$scene: $status"
done
