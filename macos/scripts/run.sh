#!/usr/bin/env bash
# Build and launch the macOS app locally (unsigned is fine for your own Mac).
# Point it at your server in Settings (defaults to http://localhost:7777).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Unrager.xcodeproj -scheme Unrager -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | tail -1
open build/Build/Products/Debug/Unrager.app
