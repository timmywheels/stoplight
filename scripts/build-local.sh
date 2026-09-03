#!/bin/zsh
# Build Stoplight from source on this Mac and install it to /Applications.
# Ad-hoc signed, no Apple ID or team needed. Locally built apps carry no quarantine flag,
# so Gatekeeper and MDM "identified developers" policies do not apply.
# Needs: Xcode 15+, xcodegen (brew install xcodegen). Usage: scripts/build-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "install xcodegen first: brew install xcodegen"; exit 1; }
BUILD=build/local; rm -rf "$BUILD"

xcodegen generate >/dev/null
xcodebuild -scheme Stoplight -configuration Release -derivedDataPath "$BUILD" build -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGNING_ALLOWED=YES

APP="$BUILD/Build/Products/Release/Stoplight.app"
codesign --verify --deep --strict "$APP"
pkill -x Stoplight 2>/dev/null || true
rm -rf /Applications/Stoplight.app
cp -R "$APP" /Applications/Stoplight.app
open /Applications/Stoplight.app
echo "Installed and launched /Applications/Stoplight.app. Look for three dots in the menu bar."
