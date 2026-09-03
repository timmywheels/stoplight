# Stoplight

macOS menu bar app + widget showing CI status for your open pull requests as three dots: red, yellow, green. Nothing else.

Spec: [tasks/prd-stoplight.md](tasks/prd-stoplight.md)

## Build

```bash
brew install xcodegen   # once
xcodegen generate
open Stoplight.xcodeproj
```

Or from the terminal:

```bash
xcodegen generate
xcodebuild -scheme Stoplight -configuration Debug build
```

Core logic tests:

```bash
cd StoplightCore && swift test
```

## Layout

- `Stoplight/` — menu bar app (SwiftUI `MenuBarExtra`)
- `StoplightWidget/` — WidgetKit extension, reads `prs.json` from the App Group
- `StoplightCore/` — Swift package: models, GitHub provider, rollup logic, tests
- `project.yml` — XcodeGen spec. The `.xcodeproj` is generated and gitignored.

## Auth

Stoplight runs `gh auth token` at launch and holds the token in memory. If `gh` isn't installed, paste a fine-grained PAT in the popover; it's stored in Keychain.

## Release

```bash
scripts/release.sh          # → dist/Stoplight-<version>.dmg and .zip, ad-hoc signed
```

Builds are ad-hoc signed (no Developer ID yet), so macOS shows "Apple could not verify" on first launch. Click Done, then System Settings → Privacy & Security → Open Anyway. Development-signed builds from Xcode only run on Macs registered to the team; the release script strips the profile so the app runs anywhere.

## Signing

Set your team in Xcode (or `DEVELOPMENT_TEAM` in `project.yml`) before running. The App Group entitlement needs a real team id to work at runtime.
