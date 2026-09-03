#!/bin/zsh
# Build a Release archive, ad-hoc sign it (no provisioning profile, runs on any Mac after
# "Open Anyway"), and package zip + DMG into ./dist. Usage: scripts/release.sh [version]
# Once a Developer ID cert exists, replace `--sign -` with the identity and add notarytool.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-$(grep MARKETING_VERSION project.yml | head -1 | awk '{print $2}')}
DIST=dist; rm -rf "$DIST"; mkdir -p "$DIST"

xcodegen generate >/dev/null
xcodebuild archive -scheme Stoplight -configuration Release -archivePath "$DIST/Stoplight.xcarchive" \
  -derivedDataPath "$DIST/dd" -allowProvisioningUpdates -quiet
APP="$DIST/Stoplight.app"; cp -R "$DIST/Stoplight.xcarchive/Products/Applications/Stoplight.app" "$APP"
APPEX="$APP/Contents/PlugIns/StoplightWidget.appex"
rm -f "$APP/Contents/embedded.provisionprofile" "$APPEX/Contents/embedded.provisionprofile"

cat > "$DIST/widget.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.application-groups</key><array><string>group.com.timwheeler.stoplight</string></array>
</dict></plist>
PLIST
cat > "$DIST/app.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.application-groups</key><array><string>group.com.timwheeler.stoplight</string></array>
</dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$DIST/widget.entitlements" "$APPEX"
codesign --force --sign - --options runtime --entitlements "$DIST/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

ditto -c -k --keepParent "$APP" "$DIST/Stoplight-$VERSION.zip"
rm -rf "$DIST/dmgroot"; mkdir "$DIST/dmgroot"; cp -R "$APP" "$DIST/dmgroot/"; ln -s /Applications "$DIST/dmgroot/Applications"
hdiutil create -volname Stoplight -srcfolder "$DIST/dmgroot" -ov -format UDZO "$DIST/Stoplight-$VERSION.dmg" -quiet
echo "sha256 (dmg): $(shasum -a 256 "$DIST/Stoplight-$VERSION.dmg" | cut -c1-64)"
echo "publish: gh release create v$VERSION $DIST/Stoplight-$VERSION.dmg $DIST/Stoplight-$VERSION.zip --title 'Stoplight $VERSION' --notes-file NOTES.md"
