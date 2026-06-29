#!/usr/bin/env bash
# Package CC Usage.app into a drag-to-install .dmg.
# Builds the app first if needed. Produces CC-Usage.dmg in the repo root.
#
# NOTE: the app is ad-hoc signed (not notarized), so on another Mac the first
# launch is blocked by Gatekeeper. Users either right-click the app ▸ Open, or:
#   xattr -dr com.apple.quarantine "/Applications/CC Usage.app"
# For zero-friction installs you need a Developer ID cert + notarization (see README).
set -euo pipefail
cd "$(dirname "$0")"

APP="CC Usage.app"
VOLNAME="CC Usage"
DMG="CC-Usage.dmg"

[[ -d "$APP" ]] || ./build-app.sh

echo "▸ Staging…"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag target

echo "▸ Creating ${DMG}…"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

rm -rf "$STAGING"
SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "✓ Built ./$DMG ($SIZE)"
echo "  Distribute via a GitHub Release (not committed to the repo)."
