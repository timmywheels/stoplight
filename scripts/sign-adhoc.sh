#!/bin/zsh
# Ad-hoc sign a built Stoplight.app (app + widget) with the App Group entitlements and no profile.
# Usage: scripts/sign-adhoc.sh path/to/Stoplight.app
set -euo pipefail
APP="$1"; APPEX="$APP/Contents/PlugIns/StoplightWidget.appex"
TMP=$(mktemp -d)
rm -f "$APP/Contents/embedded.provisionprofile" "$APPEX/Contents/embedded.provisionprofile"
cat > "$TMP/widget.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.application-groups</key><array><string>group.com.timwheeler.stoplight</string></array>
</dict></plist>
PLIST
cat > "$TMP/app.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.application-groups</key><array><string>group.com.timwheeler.stoplight</string></array>
</dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$TMP/widget.entitlements" "$APPEX"
codesign --force --sign - --options runtime --entitlements "$TMP/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
rm -rf "$TMP"
