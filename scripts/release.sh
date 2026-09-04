#!/bin/zsh
# Build, sign, notarize, and package Stoplight into ./dist. Usage: scripts/release.sh [version]
#
# With a "Developer ID Application" certificate in the keychain:
#   archive → export (developer-id, Xcode-managed profile) → notarize (keychain profile "stoplight") → staple → zip + DMG
# Without one: ad-hoc signed zip + DMG (runs only after "Open Anyway"; blocked by MDM).
#
# One-time setup for the notarized path:
#   1. Xcode → Settings → Accounts → your team → Manage Certificates → + → Developer ID Application
#   2. xcrun notarytool store-credentials stoplight --apple-id <apple id> --team-id S3RY6Q3EW2
#      (asks for an app-specific password from appleid.apple.com → Sign-In and Security → App-Specific Passwords)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-$(grep MARKETING_VERSION project.yml | head -1 | awk '{print $2}')}
TEAM=$(grep DEVELOPMENT_TEAM project.yml | head -1 | awk '{print $2}')
DIST=dist; rm -rf "$DIST"; mkdir -p "$DIST"
say() { printf '\033[1;32m▸\033[0m %s\n' "$*"; }

xcodegen generate >/dev/null
say "Archiving $VERSION"
xcodebuild archive -scheme Stoplight -configuration Release -archivePath "$DIST/Stoplight.xcarchive" \
  -derivedDataPath "$DIST/dd" -allowProvisioningUpdates -quiet

APP="$DIST/Stoplight.app"
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  say "Developer ID found: exporting a notarizable build"
  cat > "$DIST/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$DIST/Stoplight.xcarchive" -exportOptionsPlist "$DIST/export.plist" \
    -exportPath "$DIST/export" -allowProvisioningUpdates -quiet
  cp -R "$DIST/export/Stoplight.app" "$APP"

  say "Notarizing (usually 1–5 minutes)"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile stoplight --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute -v "$APP"
  SIGNED="Developer ID signed and notarized"
else
  say "No Developer ID certificate: ad-hoc signing (see header for the one-time setup)"
  cp -R "$DIST/Stoplight.xcarchive/Products/Applications/Stoplight.app" "$APP"
  scripts/sign-adhoc.sh "$APP" >/dev/null 2>&1
  SIGNED="ad-hoc signed (not notarized)"
fi

say "Packaging"
ditto -c -k --keepParent "$APP" "$DIST/Stoplight-$VERSION.zip"
rm -rf "$DIST/dmgroot"; mkdir "$DIST/dmgroot"; cp -R "$APP" "$DIST/dmgroot/"; ln -s /Applications "$DIST/dmgroot/Applications"
hdiutil create -volname Stoplight -srcfolder "$DIST/dmgroot" -ov -format UDZO "$DIST/Stoplight-$VERSION.dmg" -quiet
if [[ "$SIGNED" == Developer* ]]; then
  codesign --force --sign "Developer ID Application" --timestamp "$DIST/Stoplight-$VERSION.dmg"
  xcrun notarytool submit "$DIST/Stoplight-$VERSION.dmg" --keychain-profile stoplight --wait >/dev/null
  xcrun stapler staple "$DIST/Stoplight-$VERSION.dmg"
fi
say "Built $DIST/Stoplight-$VERSION.dmg and .zip ($SIGNED)"
echo "sha256 (dmg): $(shasum -a 256 "$DIST/Stoplight-$VERSION.dmg" | cut -c1-64)"
echo "publish: gh release create v$VERSION $DIST/Stoplight-$VERSION.dmg $DIST/Stoplight-$VERSION.zip --title 'Stoplight $VERSION' --notes-file NOTES.md"
