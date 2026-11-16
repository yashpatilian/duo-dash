#!/bin/bash
# Duo Dash setup: signing, optional extras, then build and install on your iPhone or iPad.
#
#   scripts/setup.sh                       # interactive
#   scripts/setup.sh --team ABCDE12345 --bundle-id com.you.duodash [--icons] [--install]
#   scripts/setup.sh --install             # rebuild + install with the saved settings
#
# Writes git-ignored Config/Local.xcconfig (and Config/Secrets.xcconfig if you give a
# Spotify client ID). Nothing personal is ever written to tracked files.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM="" BUNDLE="" SPOTIFY="" ICONS=0 INSTALL=0 DEVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --bundle-id) BUNDLE="$2"; shift 2 ;;
    --spotify-client-id) SPOTIFY="$2"; shift 2 ;;
    --icons) ICONS=1; shift ;;
    --install) INSTALL=1; shift ;;
    --device) DEVICE="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*"; exit 1; }

# 1. Xcode 27.1 or later (iPhone Duo SDK).
say "Checking Xcode"
command -v xcodebuild >/dev/null || fail "Xcode isn't installed. Install Xcode 27.1 or later from the App Store."
VERSION_TEXT=$(xcodebuild -version 2>/dev/null || true)   # read fully: piping into head can SIGPIPE under pipefail
XC=$(printf '%s\n' "$VERSION_TEXT" | sed -n '1s/^Xcode //p')
[ -n "$XC" ] || fail "Couldn't read the Xcode version. Run: sudo xcode-select -s /Applications/Xcode.app"
MAJOR=${XC%%.*}; MINOR=$(echo "$XC" | cut -d. -f2); MINOR=${MINOR:-0}
if [ "$MAJOR" -lt 27 ] || { [ "$MAJOR" -eq 27 ] && [ "$MINOR" -lt 1 ]; }; then
  fail "Found Xcode $XC. Duo Dash needs Xcode 27.1 or later."
fi
echo "Xcode $XC"

# 2. Signing (kept in git-ignored Config/Local.xcconfig).
LOCAL=Config/Local.xcconfig
current() { [ -f "$LOCAL" ] && grep -E "^$1 *=" "$LOCAL" | tail -1 | sed -E 's/^[^=]*= *//' || true; }
[ -z "$TEAM" ] && TEAM=$(current DEVELOPMENT_TEAM)
[ -z "$BUNDLE" ] && BUNDLE=$(current DUODASH_BUNDLE_ID)
if [ -z "$TEAM" ]; then
  say "Your Apple Developer Team ID"
  echo "Find it in Xcode → Settings → Accounts (or developer.apple.com → Membership). 10 characters."
  FOUND=$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p' | sort -u | tr '\n' ' ')
  [ -n "$FOUND" ] && echo "Teams with signing certificates on this Mac: $FOUND"
  read -r -p "Team ID: " TEAM
fi
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail "That doesn't look like a Team ID (10 letters/digits)."
if [ -z "$BUNDLE" ]; then
  read -r -p "Bundle ID [com.$(whoami | tr -cd 'a-z0-9').duodash]: " BUNDLE
  BUNDLE=${BUNDLE:-com.$(whoami | tr -cd 'a-z0-9').duodash}
fi
[[ "$BUNDLE" =~ ^[A-Za-z0-9.-]+\.[A-Za-z0-9.-]+$ ]] || fail "That doesn't look like a bundle ID (e.g. com.you.duodash)."

# Keep any branding lines already there (scripts/local-branding.swift), replace signing.
TMP=$(mktemp)
[ -f "$LOCAL" ] && grep -vE "^(DEVELOPMENT_TEAM|DUODASH_BUNDLE_ID) *=|^// Signing" "$LOCAL" > "$TMP" || true
{ cat "$TMP"; echo "// Signing (scripts/setup.sh). Git-ignored."; echo "DEVELOPMENT_TEAM = $TEAM"; echo "DUODASH_BUNDLE_ID = $BUNDLE"; } > "$LOCAL"
rm -f "$TMP"
echo "Saved signing to $LOCAL"

# 3. Optional: Spotify client ID (see docs/SPOTIFY_SETUP.md).
if [ -n "$SPOTIFY" ]; then
  [[ "$SPOTIFY" =~ ^[0-9a-f]{32}$ ]] || fail "A Spotify client ID is 32 hex characters."
  printf '// Git-ignored. Spotify developer app client ID.\nSPOTIFY_CLIENT_ID = %s\n' "$SPOTIFY" > Config/Secrets.xcconfig
  echo "Saved Spotify client ID to Config/Secrets.xcconfig"
fi

# 4. Optional: refresh the dock's official app icons from the apps on this Mac.
if [ "$ICONS" -eq 1 ]; then
  say "Rendering dock icons from the apps installed on this Mac"
  swift scripts/extract-app-icons.swift
fi

# 5. Optional: build and install on a connected iPhone or iPad.
if [ "$INSTALL" -eq 1 ]; then
  if [ -z "$DEVICE" ]; then
    # Physical devices that are reachable right now: "<name>|<udid>".
    LIST=$(xcrun devicectl list devices 2>/dev/null | grep -E "[[:space:]](available|connected)" | grep -E "[[:space:]]physical[[:space:]]*$" \
      | sed -E 's/^(.*[^ ]) +([0-9A-F]{8}-[0-9A-F]{16}) \(UDID\).*/\1|\2/' | sed -E 's/ {2,}.*\|/|/' || true)
    COUNT=$(printf '%s' "$LIST" | grep -c '|' || true)
    if [ "$COUNT" -eq 1 ]; then
      DEVICE=${LIST##*|}
    elif [ "$COUNT" -gt 1 ]; then
      say "More than one device is connected"
      i=0; while IFS='|' read -r name udid; do i=$((i+1)); echo "  $i) $name ($udid)"; done <<< "$LIST"
      read -r -p "Install on which one? [1-$COUNT]: " PICK
      DEVICE=$(printf '%s\n' "$LIST" | sed -n "${PICK}p" | cut -d'|' -f2)
    fi
  fi
  [ -n "$DEVICE" ] || fail "No iPhone or iPad found. Connect it (cable or same Wi-Fi), unlock it, trust this Mac and turn on Developer Mode (Settings → Privacy & Security), then run: scripts/setup.sh --install"
  say "Building for device $DEVICE"
  DD=build/DerivedData
  xcodebuild build -project DuoDash.xcodeproj -scheme DuoDash -destination "id=$DEVICE" \
    -derivedDataPath "$DD" -allowProvisioningUpdates -quiet || fail "Build failed. Check that you're signed in to Xcode (Settings → Accounts) with the account for team $TEAM."
  say "Installing"
  xcrun devicectl device install app --device "$DEVICE" "$DD/Build/Products/Debug-iphoneos/DuoDash.app"
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" || echo "Installed. Unlock the phone and open the app."
fi

say "Done"
echo "Open DuoDash.xcodeproj in Xcode, pick your iPhone or iPad and press Run, or run: scripts/setup.sh --install"
