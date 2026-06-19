#!/usr/bin/env bash
# Build, ad-hoc sign, and install unrager onto a registered iPhone over USB or
# the network (Tailscale). One-time: register the device + mint the profile with
# `python3 scripts/provision.py --udid <UDID> --serial <DIST_CERT_SERIAL>`.
#
#   UDID=<device-udid> ./scripts/install-device.sh
#
# Env:
#   UDID            target device UDID (required)
#   TEAM            signing team id (default P4DQK6SRKR)
#   IDENTITY        codesign identity (default Apple Distribution: Midgar Oy ...)
#   PROFILE         provisioning profile name (default "Unrager AdHoc")
#   SERVER          server the app points at (baked default is the Tailscale IP)
set -euo pipefail
cd "$(dirname "$0")/.."

UDID="${UDID:?set UDID to the target device}"
TEAM="${TEAM:-P4DQK6SRKR}"
IDENTITY="${IDENTITY:-Apple Distribution: Midgar Oy (P4DQK6SRKR)}"
PROFILE="${PROFILE:-Unrager AdHoc}"

echo "==> generating project"
xcodegen generate >/dev/null

echo "==> building Release (ad-hoc signed)"
xcodebuild -project Unrager.xcodeproj -scheme Unrager \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath build-device \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM" \
  "CODE_SIGN_IDENTITY=$IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE" \
  build | tail -1

APP="build-device/Build/Products/Release-iphoneos/Unrager.app"

echo "==> installing to $UDID"
xcrun devicectl device install app --device "$UDID" "$APP"

echo "==> launching"
xcrun devicectl device process launch --terminate-existing --device "$UDID" com.guitaripod.unrager
echo "done. Set the server address in Settings if it isn't reachable."
