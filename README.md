# Stoplight

macOS menu bar app + widget showing CI status for your open pull requests as three dots: red, yellow, green. Nothing else.

Spec: [tasks/prd-stoplight.md](tasks/prd-stoplight.md)

## Install

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/timmywheels/stoplight/main/install.sh)"
```

One command. Downloads the latest release, Developer ID signed and notarized by Apple, installs to `/Applications`, makes sure the GitHub CLI is installed and signed in, and launches. No Xcode, no security prompts, works on managed Macs.

Re-run the same command to update. Prefer building from source? `STOPLIGHT_FROM_SOURCE=1` in front of the command (needs Xcode and xcodegen).

## Build from a checkout

```bash
brew install xcodegen
xcodegen generate
open Stoplight.xcodeproj      # or: scripts/build-local.sh to build + install
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

Releases are Developer ID signed and notarized. The script archives, exports with the Developer ID profile, submits to Apple's notary service, staples the ticket, and packages a DMG and zip. Falls back to ad-hoc signing when no Developer ID certificate is in the keychain. One-time setup is in the script header.

## Signing

Set your team in Xcode (or `DEVELOPMENT_TEAM` in `project.yml`) before running. The App Group entitlement needs a real team id to work at runtime.
