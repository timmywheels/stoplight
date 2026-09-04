#!/bin/bash
# Stoplight installer. One line:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/timmywheels/stoplight/main/install.sh)"
#
# With Xcode:    clones, builds from source, ad-hoc signs, installs to /Applications. Works on managed Macs.
# Without Xcode: downloads the latest release DMG. Needs "Open Anyway" once unless MDM blocks it.
# Then makes sure `gh` is installed and signed in, and launches the app.
#
# Env overrides: STOPLIGHT_SRC_DIR, STOPLIGHT_INSTALL_DIR, STOPLIGHT_NO_LAUNCH=1, STOPLIGHT_FROM_RELEASE=1
set -euo pipefail

REPO="timmywheels/stoplight"
SRC="${STOPLIGHT_SRC_DIR:-$HOME/.stoplight/src}"
APPS="${STOPLIGHT_INSTALL_DIR:-/Applications}"
[ -w "$APPS" ] || APPS="$HOME/Applications"
mkdir -p "$APPS"
APP="$APPS/Stoplight.app"

say()  { printf '\033[1;32m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Stoplight is a macOS app."
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MACOS_MAJOR" -ge 14 ] || die "Stoplight needs macOS 14 or newer."

have_xcode() {
  [ -z "${STOPLIGHT_FROM_RELEASE:-}" ] && command -v xcodebuild >/dev/null 2>&1 \
    && xcodebuild -version >/dev/null 2>&1 && [ -d "$(xcode-select -p 2>/dev/null)/Platforms" ]
}

ensure_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  warn "Homebrew not found. Install it from https://brew.sh then re-run, or install $1 yourself."
  return 1
}

install_from_source() {
  say "Xcode found. Building from source (about 2 minutes, no Apple ID needed)."
  if ! command -v xcodegen >/dev/null 2>&1; then
    ensure_brew xcodegen && { say "Installing xcodegen…"; brew install -q xcodegen; }
  fi
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen is required to build. brew install xcodegen"
  if [ -d "$SRC/.git" ]; then
    say "Updating $SRC"; git -C "$SRC" pull -q --ff-only
  else
    say "Cloning to $SRC"; mkdir -p "$(dirname "$SRC")"; git clone -q "https://github.com/$REPO.git" "$SRC"
  fi
  cd "$SRC"
  xcodegen generate >/dev/null
  xcodebuild -scheme Stoplight -configuration Release -destination "platform=macOS" -derivedDataPath build/local build -quiet \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
  scripts/sign-adhoc.sh build/local/Build/Products/Release/Stoplight.app >/dev/null 2>&1
  pkill -x Stoplight 2>/dev/null || true
  rm -rf "$APP"; cp -R build/local/Build/Products/Release/Stoplight.app "$APP"
  rm -rf build/local
}

install_from_release() {
  say "No Xcode. Downloading the latest release."
  local url tmp
  url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o 'https://[^"]*Stoplight-[^"]*\.zip' | head -1)
  [ -n "$url" ] || die "Couldn't find a release zip at https://github.com/$REPO/releases"
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/Stoplight.zip"
  ditto -x -k "$tmp/Stoplight.zip" "$tmp"
  pkill -x Stoplight 2>/dev/null || true
  rm -rf "$APP"; cp -R "$tmp/Stoplight.app" "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  rm -rf "$tmp"
  warn "This build is not notarized. If macOS refuses to open it: System Settings → Privacy & Security → Open Anyway."
  warn "If that button never appears, your Mac's policy requires notarized apps. Install Xcode and re-run to build locally."
}

ensure_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    if ensure_brew gh; then say "Installing GitHub CLI…"; brew install -q gh; fi
  fi
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      say "GitHub CLI is signed in. Stoplight will use that token."
    elif [ -t 0 ]; then
      say "Signing in to GitHub (Stoplight reads your PRs through the GitHub CLI)…"
      gh auth login || warn "Sign in later with: gh auth login"
    else
      warn "Run: gh auth login   (Stoplight uses the GitHub CLI token; or paste a token in the app)"
    fi
  else
    warn "GitHub CLI not installed. In the app, paste a fine-grained token instead."
  fi
}

if have_xcode; then install_from_source; else install_from_release; fi
ensure_gh
say "Installed $APP"
if [ -z "${STOPLIGHT_NO_LAUNCH:-}" ]; then
  open "$APP" && say "Launched. Look for three dots in your menu bar."
fi
