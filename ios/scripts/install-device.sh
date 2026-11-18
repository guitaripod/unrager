#!/usr/bin/env bash
# Build, ad-hoc sign, and install unrager onto a registered iPhone or iPad over
# USB or the network (Tailscale). One-time: register the device + mint the
# profile with `python3 scripts/provision.py --udid <UDID> --serial <DIST_CERT_SERIAL>`
# (repeat --udid to cover several devices in one profile).
#
#   UDID=<device-udid> ./scripts/install-device.sh
#
# Env:
#   UDID            target device UDID (required)
#   TEAM            signing team id (default P4DQK6SRKR)
#   IDENTITY        codesign identity (default Apple Distribution: Midgar Oy ...)
#   PROFILE         provisioning profile name (default "Unrager AdHoc")
#   SERVER          server the app starts pointed at (default: the maintainer's
#                   Tailscale address; for your own, use install.sh)
#   VERSION         version shown in Settings (default: the crate version in
#                   ../Cargo.toml without any pre-release suffix, so a stale
#                   phone build stands out against the server's version)
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

UDID="${UDID:?set UDID to the target device}"
TEAM="${TEAM:-P4DQK6SRKR}"
IDENTITY="${IDENTITY:-Apple Distribution: Midgar Oy (P4DQK6SRKR)}"
PROFILE="${PROFILE:-Unrager AdHoc}"
SERVER="${SERVER:-http://100.91.211.44:7777}"
CRATE_VERSION="$(sed -n '/^\[workspace\.package\]/,/^\[/s/^version *= *"\([^"]*\)".*/\1/p' ../Cargo.toml | head -1)"
VERSION="${VERSION:-${CRATE_VERSION%%-*}}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "bad VERSION '$VERSION' (from ../Cargo.toml)" >&2; exit 1; }

# Whether this session may use the signing key: a throwaway signature with the
# same identity answers in a fraction of a second, without building anything.
session_can_sign() {
  local probe; probe="$(mktemp -t unrager-signprobe)"
  echo probe > "$probe"
  local ok=1
  codesign --force --sign "$IDENTITY" "$probe" >/dev/null 2>&1 || ok=0
  rm -f "$probe"
  [[ $ok == 1 ]]
}

# Runs this script again as a launchd job in the logged-in session, which owns
# the keychain, and waits for it: the build's output comes back here as it goes.
run_in_signed_in_session() {
  local label="com.unrager.install.$$"
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  local log; log="$(mktemp -t unrager-install).log"
  local marker="UNRAGER_INSTALL_STATUS"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd '$(pwd)' &amp;&amp; UNRAGER_IN_GUI_SESSION=1 UDID='$UDID' TEAM='$TEAM' IDENTITY='$IDENTITY' PROFILE='$PROFILE' SERVER='$SERVER' VERSION='$VERSION' bash '$SCRIPT'; echo "$marker \$?"</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
PLIST
  echo "==> signing needs the login keychain: building in the signed-in session"
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" || {
    echo "couldn't start the signed-in session; run this script from a Terminal on the Mac instead" >&2
    rm -f "$plist"; exit 1
  }
  local status=""
  for _ in $(seq 1 900); do
    if grep -q "$marker" "$log" 2>/dev/null; then
      status="$(sed -n "s/.*$marker //p" "$log" | tail -1)"
      break
    fi
    sleep 2
  done
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  rm -f "$plist"
  grep -v "$marker" "$log" | tail -40
  [[ "$status" == "0" ]] || { echo "install failed (status ${status:-timeout})" >&2; exit "${status:-1}"; }
  exit 0
}

# Signing needs the distribution key, which lives in the login keychain: a
# session that isn't the Mac's own (ssh, an agent) can't unlock it and codesign
# dies with errSecInternalComponent. So probe first, and when this session can't
# sign, hand the whole build to a job inside the signed-in session, where the
# keychain is already open.
if [[ "${UNRAGER_IN_GUI_SESSION:-0}" != "1" ]] && ! session_can_sign; then
  run_in_signed_in_session
fi

echo "==> generating project"
xcodegen generate >/dev/null

echo "==> building Release $VERSION (ad-hoc signed)"
xcodebuild -project Unrager.xcodeproj -scheme Unrager \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath build-device \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM" \
  "CODE_SIGN_IDENTITY=$IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE" \
  MARKETING_VERSION="$VERSION" \
  UNRAGER_DEFAULT_SERVER="$SERVER" \
  build | tail -1

APP="build-device/Build/Products/Release-iphoneos/Unrager.app"


echo "==> installing to $UDID"
xcrun devicectl device install app --device "$UDID" "$APP"

echo "==> launching"
xcrun devicectl device process launch --terminate-existing --device "$UDID" com.guitaripod.unrager
echo "done. Set the server address in Settings if it isn't reachable."
