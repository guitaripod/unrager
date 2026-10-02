#!/usr/bin/env bash
# Builds the unrager iPhone app with your own Apple ID or developer account and
# installs it on an iPhone connected to this Mac.
#
#   cd ios && ./scripts/install.sh
#
# Everything is detected and anything missing is asked for. Set these only to
# skip a question or when a guess is wrong:
#
#   UDID        the iPhone to install on (when more than one is paired)
#   TEAM        your Apple developer team id, ten letters and digits
#   BUNDLE_ID   the app's identifier (default com.unrager.<team id>, which is
#               unique to your team, so no one else's App ID can be in the way)
#   SERVER      where your unrager server is, such as http://100.64.0.1:7777
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH
#               sign in with an App Store Connect API key instead of the Apple
#               ID Xcode is signed in with (for a Mac nobody sits at)
#
# ./scripts/install.sh --check shows what it found and builds nothing.
#
# The maintainer's ad-hoc path with a distribution certificate is
# install-device.sh; this script is for everyone else.
set -euo pipefail
cd "$(dirname "$0")/.."

DEFAULT_PORT=7777
BUILD_DIR="build-device"
LOG="$BUILD_DIR/xcodebuild.log"

say() { printf '==> %s\n' "$*"; }

fail() {
  printf '\nCan'"'"'t go on: %s\n' "$1" >&2
  [[ $# -gt 1 ]] && printf '%s\n' "${@:2}" >&2
  exit 1
}

# True when a person can answer a question; false in a pipe or a CI job.
interactive() { [[ -t 0 && -t 1 ]]; }

# Stops with an install hint unless `$1` is on the PATH.
require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 isn't installed." "$2"
}

# Checks the Mac has what building an iOS 26 app takes.
check_tools() {
  [[ "$(uname)" == "Darwin" ]] || fail "the iPhone app can only be built on a Mac with Xcode."
  require_tool xcodebuild "Install Xcode from the App Store, open it once, and accept the license."
  require_tool xcodegen "Install it with: brew install xcodegen"
  require_tool python3 "Install the command line tools with: xcode-select --install"
  local major
  major="$(xcodebuild -version | sed -n '1s/^Xcode \([0-9]*\).*/\1/p')"
  [[ "${major:-0}" -ge 26 ]] || fail "Xcode ${major:-?} is too old; the app needs Xcode 26 or newer (iOS 26)."
}

# Prints "udid<TAB>name<TAB>developer-mode<TAB>iOS version" for every paired,
# physical iPhone. Reads the new devicectl layout and falls back to the old one.
list_iphones() {
  local json
  json="$(mktemp)"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
  python3 - "$json" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
for device in devices:
    new = device.get("properties", {})
    old = device.get("deviceProperties", {})
    hardware = new.get("hardware") or device.get("hardwareProperties", {})
    connection = new.get("connection") or device.get("connectionProperties", {})
    state = new.get("state") or old
    if hardware.get("deviceType") != "iPhone" or hardware.get("reality") != "physical":
        continue
    if connection.get("pairingState") != "paired":
        continue
    version = new.get("software", {}).get("osVersionNumber") or old.get("osVersionNumber") or ""
    if isinstance(version, dict):
        version = version.get("stringValue", "")
    name = state.get("name") or hardware.get("marketingName", "iPhone")
    print(f"{hardware.get('udid', '')}\t{name}\t{state.get('developerModeStatus', 'unknown')}\t{version}")
PY
  rm -f "$json"
}

# Sets PHONES, UDID and DEVICE_NAME, asking when several iPhones are paired.
find_device() {
  local count phones paired
  paired="$(list_iphones)"
  PHONES="$(awk -F'\t' '{ split($4, v, "."); if ($4 == "" || v[1] >= 26) print }' <<<"$paired")"
  phones="$PHONES"
  if [[ -n "${UDID:-}" ]]; then
    DEVICE_NAME="$(awk -F'\t' -v id="$UDID" '$1 == id { print $2 }' <<<"$phones")"
    DEVICE_NAME="${DEVICE_NAME:-your iPhone}"
    return
  fi
  count="$(grep -c . <<<"$phones" || true)"
  if [[ "$count" -eq 0 && -n "$paired" ]]; then
    fail "the app needs iOS 26 and no paired iPhone has it:" \
      "$(awk -F'\t' '{ printf "  %s (iOS %s)\n", $2, $4 }' <<<"$paired")" \
      "Update the phone in Settings > General > Software Update."
  elif [[ "$count" -eq 0 ]]; then
    fail "no iPhone found." \
      "Plug it into this Mac with a cable, unlock it, and tap Trust on the phone when it asks." \
      "Then run this again."
  elif [[ "$count" -eq 1 ]]; then
    UDID="$(cut -f1 <<<"$phones")"
    DEVICE_NAME="$(cut -f2 <<<"$phones")"
    return
  fi
  if ! interactive; then
    fail "more than one iPhone is paired:" "$(awk -F'\t' '{ printf "  %s  %s\n", $1, $2 }' <<<"$phones")" \
      "Run again with UDID=<one of those>."
  fi
  echo "More than one iPhone is paired:"
  awk -F'\t' '{ printf "  %d) %s\n", NR, $2 }' <<<"$phones"
  local choice
  read -r -p "Install on which one? [1] " choice
  choice="${choice:-1}"
  local line
  line="$(sed -n "${choice}p" <<<"$phones")"
  [[ -n "$line" ]] || fail "'$choice' isn't one of the choices."
  UDID="$(cut -f1 <<<"$line")"
  DEVICE_NAME="$(cut -f2 <<<"$line")"
}

# Stops when the phone says Developer Mode is off, which iOS needs to run any
# app that isn't from the App Store.
check_developer_mode() {
  local mode
  mode="$(awk -F'\t' -v id="$UDID" '$1 == id { print $3 }' <<<"$PHONES")"
  [[ "$mode" == "disabled" ]] || return 0
  fail "Developer Mode is off on $DEVICE_NAME." \
    "On the phone: Settings > Privacy & Security > Developer Mode > turn it on, restart when it asks," \
    "confirm after the restart, then run this again."
}

# Prints "team id<TAB>name<TAB>free" for each team Xcode is signed in to or has
# an Apple Development certificate for.
list_teams() {
  python3 - <<'PY'
import plistlib, re, subprocess

teams = {}
try:
    exported = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"],
                              capture_output=True, check=True).stdout
    for entries in plistlib.loads(exported).get("IDEProvisioningTeamByIdentifier", {}).values():
        for team in entries:
            teams[team["teamID"]] = (team.get("teamName", ""), bool(team.get("isFreeProvisioningTeam")))
except Exception:
    pass

certificates = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
                              capture_output=True, text=True).stdout
for pem in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.S):
    subject = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
                             input=pem, capture_output=True, text=True).stdout
    team = re.search(r"OU=([A-Z0-9]{10})", subject)
    owner = re.search(r"O=([^,\n]+)", subject)
    if team and team.group(1) not in teams:
        teams[team.group(1)] = (owner.group(1) if owner else "", False)

for team_id, (name, free) in teams.items():
    print(f"{team_id}\t{name}\t{'free' if free else ''}")
PY
}

# Sets TEAM (and FREE_TEAM), asking when Xcode knows several teams.
find_team() {
  local teams count
  teams="$(list_teams)"
  if [[ -n "${TEAM:-}" ]]; then
    FREE_TEAM="$(awk -F'\t' -v id="$TEAM" '$1 == id { print $3 }' <<<"$teams")"
    return
  fi
  count="$(grep -c . <<<"$teams" || true)"
  if [[ "$count" -eq 0 ]]; then
    fail "no Apple developer team found." \
      "Open Xcode > Settings > Accounts, add your Apple ID (a free one works), then run this again." \
      "If you know your team id, run: TEAM=<id> ./scripts/install.sh"
  elif [[ "$count" -eq 1 ]]; then
    TEAM="$(cut -f1 <<<"$teams")"
    FREE_TEAM="$(cut -f3 <<<"$teams")"
    return
  fi
  if ! interactive; then
    fail "more than one team found:" "$(awk -F'\t' '{ printf "  %s  %s\n", $1, $2 }' <<<"$teams")" \
      "Run again with TEAM=<one of those>."
  fi
  echo "More than one team found:"
  awk -F'\t' '{ printf "  %d) %s (%s)\n", NR, $2, $1 }' <<<"$teams"
  local choice line
  read -r -p "Sign with which one? [1] " choice
  line="$(sed -n "${choice:-1}p" <<<"$teams")"
  [[ -n "$line" ]] || fail "'$choice' isn't one of the choices."
  TEAM="$(cut -f1 <<<"$line")"
  FREE_TEAM="$(cut -f3 <<<"$line")"
}

# This Mac's Tailscale address, when this Mac is the one running the server.
local_server_suggestion() {
  curl -fsS --max-time 1 "http://localhost:$DEFAULT_PORT/api/health" >/dev/null 2>&1 || return 0
  local ip
  for tailscale in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    ip="$("$tailscale" ip -4 2>/dev/null | head -1 || true)"
    [[ -n "$ip" ]] && { echo "http://$ip:$DEFAULT_PORT"; return; }
  done
}

# Turns what was typed into a full address: http:// and :7777 are added when
# left out, and a trailing slash is dropped.
normalize_server() {
  local address="${1//[[:space:]]/}"
  [[ -n "$address" ]] || return 0
  [[ "$address" == *"://"* ]] || address="http://$address"
  [[ "${address#*://}" == *:* ]] || address="${address%/}:$DEFAULT_PORT"
  echo "${address%/}"
}

# Sets SERVER to the address the app starts with, which may stay empty: the app
# then asks for it in Settings.
find_server() {
  if [[ -z "${SERVER+x}" ]] && interactive; then
    local suggestion typed
    suggestion="$(local_server_suggestion)"
    echo
    echo "Where is your unrager server? That is the computer you ran 'unrager setup --apps --bind 0.0.0.0:$DEFAULT_PORT' on."
    echo "Enter its Tailscale address (100.x.y.z or its name), or leave empty to type it in the app instead."
    read -r -p "Server address${suggestion:+ [$suggestion]}: " typed
    SERVER="${typed:-$suggestion}"
  fi
  SERVER="$(normalize_server "${SERVER:-}")"
}

# The crate version, so Settings shows which release the phone has.
app_version() {
  local crate
  crate="$(sed -n '/^\[workspace\.package\]/,/^\[/s/^version *= *"\([^"]*\)".*/\1/p' ../Cargo.toml | head -1)"
  echo "${crate%%-*}"
}

# Writes the Xcode project for this team and server.
generate_project() {
  UNRAGER_TEAM_ID="$TEAM" xcodegen generate >/dev/null
}

# Builds a Release app signed by Xcode for this team and phone, registering the
# phone and creating the provisioning profile on the way.
build_app() {
  local auth=()
  if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_PRIVATE_KEY_PATH:-}" ]]; then
    auth=(-authenticationKeyPath "${ASC_PRIVATE_KEY_PATH/#\~/$HOME}"
          -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  fi
  mkdir -p "$BUILD_DIR"
  say "building unrager $VERSION for $DEVICE_NAME (a few minutes the first time)"
  if ! xcodebuild -project Unrager.xcodeproj -scheme Unrager -configuration Release \
      -destination "id=$UDID" -derivedDataPath "$BUILD_DIR" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration "${auth[@]}" \
      CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
      PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" MARKETING_VERSION="$VERSION" \
      UNRAGER_DEFAULT_SERVER="$SERVER" build >"$LOG" 2>&1; then
    explain_build_failure
  fi
}

# Turns the usual xcodebuild failures into the one thing to do about each.
explain_build_failure() {
  local hint="The last lines of the build log ($LOG) say why."
  if grep -qiE "no account|add a new account|no accounts" "$LOG"; then
    hint="Xcode isn't signed in: open Xcode > Settings > Accounts and add your Apple ID."
  elif grep -qiE "not available to you|failed to register bundle identifier|already (been )?registered" "$LOG"; then
    hint="Apple says that app identifier is taken. Pick your own: BUNDLE_ID=com.yourname.unrager ./scripts/install.sh"
  elif grep -qiE "maximum number of|too many (app )?ids|registered [0-9]+ app ids" "$LOG"; then
    hint="A free Apple ID can register only 10 new app identifiers a week. Wait, or reuse an earlier BUNDLE_ID."
  elif grep -qiE "developer mode" "$LOG"; then
    hint="Turn on Developer Mode on the phone: Settings > Privacy & Security > Developer Mode."
  elif grep -qiE "unable to find a destination|device is (not|un)available|is locked" "$LOG"; then
    hint="Xcode can't see the phone: unlock it, plug it in with a cable and tap Trust."
  elif grep -qiE "provisioning profile|signing certificate|code signing" "$LOG"; then
    hint="Signing failed. Open ios/Unrager.xcodeproj in Xcode, pick the Unrager target, Signing & Capabilities, choose your team, and see what it says."
  fi
  echo >&2
  grep -E "error:" "$LOG" | sort -u | head -8 >&2 || true
  fail "the build failed." "$hint"
}

# Copies the app to the phone and opens it.
install_app() {
  local app="$BUILD_DIR/Build/Products/Release-iphoneos/Unrager.app"
  [[ -d "$app" ]] || fail "the build finished but $app isn't there."
  say "installing on $DEVICE_NAME"
  xcrun devicectl device install app --device "$UDID" "$app" >"$BUILD_DIR/install.log" 2>&1 \
    || { tail -5 "$BUILD_DIR/install.log" >&2; fail "installing failed." \
         "Unlock the phone and keep it near the cable, then run this again."; }
  say "opening it"
  if ! xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE_ID" \
      >"$BUILD_DIR/launch.log" 2>&1; then
    echo "    It's installed, but the phone wouldn't open it (usually because it is locked or you haven't trusted yourself yet)."
  fi
}

# What to do on the phone, in order.
print_next_steps() {
  echo
  echo "Unrager $VERSION is on $DEVICE_NAME."
  echo
  echo "On the phone:"
  echo "  1. If it says \"Untrusted Developer\" or won't open: Settings > General > VPN & Device Management,"
  echo "     tap your Apple ID under Developer App, then Trust."
  echo "  2. Open Unrager. Tap Allow when it asks to find devices on your local network."
  if [[ -n "$SERVER" ]]; then
    echo "  3. It already points at $SERVER. If Home stays empty, open the Settings tab and check Server."
  else
    echo "  3. Open the Settings tab, tap Server and enter your unrager server's address (for example 100.64.0.1:7777)."
  fi
  if [[ -n "$FREE_TEAM" ]]; then
    echo
    echo "With a free Apple ID the app stops opening after 7 days. Run this script again to renew it;"
    echo "your login and settings stay."
  fi
}

check_tools
find_device
check_developer_mode
find_team
BUNDLE_ID="${BUNDLE_ID:-com.unrager.$(tr '[:upper:]' '[:lower:]' <<<"$TEAM")}"
find_server
VERSION="$(app_version)"

if [[ "${1:-}" == "--check" ]]; then
  echo "iPhone:     $DEVICE_NAME ($UDID)"
  echo "Team:       $TEAM${FREE_TEAM:+ (free Apple ID)}"
  echo "Identifier: $BUNDLE_ID"
  echo "Server:     ${SERVER:-none, set in the app}"
  echo "Version:    $VERSION"
  exit 0
fi

say "signing as team $TEAM, app identifier $BUNDLE_ID"
generate_project
build_app
install_app
print_next_steps
