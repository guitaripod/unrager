# Unrager for iPhone

A native iPhone app for [unrager](../README.md): your timeline with the rage filter, threads, profiles, notifications, and Ask, Brief and Translate on your own model. It talks to `unrager serve` on your computer, so the app never sees your X login and nothing goes through a server of anyone else's.

It isn't in the App Store (it runs on your X session), so you build it once on a Mac and put it on your phone yourself. It takes about ten minutes, most of it Xcode downloading.

## What you need

- **The computer that runs unrager**, signed in to x.com in a Chromium browser (Chrome, Brave, Edge, Vivaldi or Arc). Linux or macOS; it can be the same Mac you build on.
- **Tailscale** on that computer and on your phone (free, [tailscale.com](https://tailscale.com)), so the phone reaches it from anywhere. On the same Wi-Fi at home, the computer's local address works too.
- **A Mac with Xcode 26 or newer** (App Store, free), and `xcodegen`: `brew install xcodegen`. The Mac is only for building.
- **An iPhone on iOS 26** and a cable to that Mac.
- **An Apple ID.** A free one is enough. (A paid developer account makes the app last a year instead of seven days.)

## 1. Start the server

On the computer that runs unrager:

```sh
unrager setup --apps --bind 0.0.0.0:7777
```

This starts the full server in the background (a systemd user service on Linux, a launch agent on macOS) and, at the end, prints what to type into the app:

```
✓ iphone      in the app, open Settings → Server and enter http://100.64.0.9:7777
```

Keep that address. (Versions before 0.27 don't print it: `tailscale ip -4` gives the same number.) unrager has no login of its own, so `0.0.0.0` belongs on a private network such as Tailscale, not on public Wi-Fi. To check the server from the phone, open that address followed by `/api/health` in Safari (`http://100.64.0.9:7777/api/health`): it answers with a line of JSON.

`unrager doctor` says what's wrong if the server can't read your X login.

## 2. Prepare the phone and the Mac

1. **Developer Mode on the phone.** Settings > Privacy & Security > Developer Mode > on; the phone restarts and asks you to confirm. (If the switch isn't there yet, plug the phone into the Mac with Xcode open once and look again.)
2. **Sign in to Xcode.** Xcode > Settings > Accounts > + > Apple ID.
3. **Plug the phone in**, unlock it, and tap **Trust** when it asks.

## 3. Build and install

```sh
git clone https://github.com/guitaripod/unrager
cd unrager/ios
./scripts/install.sh
```

The script finds your iPhone and your signing team, asks where your server is (enter the address from step 1; it adds `http://` and `:7777` if you leave them out), builds the app, installs it and opens it. It asks only what it can't work out, and names the one thing to fix when something is missing. `./scripts/install.sh --check` shows what it found without building.

To skip a question or override a guess, set it first, for example `SERVER=100.64.0.9 TEAM=ABCDE12345 ./scripts/install.sh`:

| Variable | Meaning |
|---|---|
| `UDID` | the iPhone to use, when more than one is paired |
| `TEAM` | your Apple developer team id (ten letters and digits) |
| `BUNDLE_ID` | the app's identifier; default `com.unrager.<your team id>`, which can't clash with anyone else's |
| `SERVER` | the address the app starts with |

## 4. On the phone

1. If the app says **Untrusted Developer** or won't open: Settings > General > VPN & Device Management > your Apple ID under *Developer App* > **Trust**.
2. Open **Unrager** and tap **Allow** when it asks to find devices on your local network.
3. If you gave the script your server's address, Home fills in. Otherwise: the **Settings** tab > **Server** > enter the address from step 1. The app checks it before saving.

Done. Pull down on Home to refresh; long-press the compose button for more.

## Updating

```sh
git pull
./scripts/install.sh
```

Your login, drafts and settings stay. Settings shows the app's version next to the server's: a mismatch means the phone has an older build. After `unrager update` on the computer, run the script again to match.

With a free Apple ID the app **stops opening after 7 days**; run the script again to renew it. A paid developer account lasts a year.

## When something goes wrong

| What you see | What to do |
|---|---|
| *no iPhone found* | Cable in, phone unlocked, Trust tapped. Unplug and replug it if it still doesn't show. |
| *the app needs iOS 26* | Update the phone: Settings > General > Software Update. |
| *Developer Mode is off* | Step 2.1. |
| *no Apple developer team found* | Xcode > Settings > Accounts: add your Apple ID, then run the script again. |
| *Apple says that app identifier is taken* | `BUNDLE_ID=com.yourname.unrager ./scripts/install.sh`. |
| *the build failed* | The script prints the likely fix; the whole log is `ios/build-device/xcodebuild.log`. |
| Installed, but it won't open | Unlock the phone, then trust yourself (step 4.1). |
| Home says it can't reach the server | Settings > Server: is the address the one step 1 printed? Is Tailscale on, on the phone too? Does `/api/health` open in Safari? Was it `--apps`? A server set up without it answers only the browser extension. |
| Home loads but shows X errors | The computer must be signed in to x.com in a Chromium browser; `unrager doctor` checks. |
| No banners when the app is closed | There's no push server: banners come from the app while it is open and from iOS's occasional background refresh. The badge and the Notifications tab are always right. |

## Doing it by hand in Xcode

```sh
cd ios
UNRAGER_TEAM_ID=ABCDE12345 xcodegen generate
open Unrager.xcodeproj
```

Pick the **Unrager** target > Signing & Capabilities, choose your team and change the bundle identifier to one of your own (`com.yourname.unrager`), select your phone at the top and press Run. To start pointed at your server, set `UNRAGER_DEFAULT_SERVER` (for example `http://100.64.0.9:7777`) as a build setting on the target; otherwise enter it in Settings > Server.

## For the maintainer

- **Simulator**: `xcodegen generate && xcodebuild -scheme Unrager -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`, then `xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Unrager.app`. In a Debug build the `UNRAGER_SCREEN` environment variable deep-navigates for screenshots (`SceneDelegate.handleDebugLaunch` lists the routes) and `UNRAGER_SERVER` points it at a server.
- **Ad-hoc install** with a distribution certificate (what the maintainer's phone uses): once, `python3 scripts/provision.py --udid <UDID> --serial <DIST_CERT_SERIAL>` mints the profile through the App Store Connect API; then `UDID=<UDID> ./scripts/install-device.sh` builds, signs and installs, with `SERVER=` for the address the app starts with.
- **Tests**: `xcodebuild -project Unrager.xcodeproj -scheme Unrager -destination 'platform=iOS Simulator,name=iPhone Air' test`, and `cd ../UnragerKit && swift test`.
- **Demo video**: `../demos/app/` records the app against a mock server with only made-up posts.
