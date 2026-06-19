#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple, and package the macOS app as a DMG
# for off-App-Store distribution (the app uses your X session, so it can't be
# listed). Requires a "Developer ID Application" cert in the keychain and a
# notarytool keychain profile.
#
# One-time:
#   xcrun notarytool store-credentials unrager-notary \
#     --key "$ASC_PRIVATE_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"
#   brew install create-dmg
#
# Then:
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/release-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:?set IDENTITY to your Developer ID Application cert}"
NOTARY_PROFILE="${NOTARY_PROFILE:-unrager-notary}"
VERSION="${VERSION:-1.0.0}"

echo "==> generate + archive"
xcodegen generate >/dev/null
xcodebuild -project Unrager.xcodeproj -scheme Unrager -configuration Release \
  -derivedDataPath build archive -archivePath build/Unrager.xcarchive \
  CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY"

APP="build/export/Unrager.app"
rm -rf build/export && mkdir -p build/export
cp -R build/Unrager.xcarchive/Products/Applications/Unrager.app "$APP"

echo "==> sign (hardened runtime, inside-out)"
find "$APP/Contents/Frameworks" -type d -name "*.framework" -maxdepth 1 2>/dev/null | while read -r fw; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$fw"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

echo "==> notarize app"
ditto -c -k --keepParent "$APP" build/Unrager.zip
xcrun notarytool submit build/Unrager.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> build + notarize DMG"
DMG="build/Unrager-$VERSION.dmg"
rm -f "$DMG"
create-dmg --volname "Unrager" --window-size 660 420 \
  --icon "Unrager.app" 165 200 --app-drop-link 495 200 \
  --codesign "$IDENTITY" "$DMG" "build/export/" || true
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" && echo "==> done: $DMG (notarized + stapled)"
