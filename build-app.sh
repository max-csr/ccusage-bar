#!/usr/bin/env bash
# Build CC Usage as a proper .app bundle and ad-hoc codesign it.
# CLT-only friendly (no Xcode project). Idempotent, no sudo.
set -euo pipefail
cd "$(dirname "$0")"

BIN_NAME="ClaudeUsage"          # SwiftPM product / executable name (no spaces)
APP_NAME="CC Usage"             # user-facing app name
BUNDLE_ID="com.maxcerisier.ccusagebar"
APP="${APP_NAME}.app"

echo "▸ Building (release, arm64)…"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/${BIN_NAME}"
if [[ ! -f "$BIN" ]]; then
  echo "✗ Built binary not found at $BIN" >&2
  exit 1
fi

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${BIN_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

echo "▸ Ad-hoc codesigning (stable identifier ${BUNDLE_ID})…"
# Stable --identifier keeps the Keychain "Always Allow" ACL across rebuilds
# and is required for SMAppService launch-at-login to work on an unsigned-for-distribution app.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /' || true

echo ""
echo "✓ Built ./$APP"
echo "  Install:  cp -R \"$APP\" ~/Applications/ && open \"~/Applications/$APP\""
echo "  Run it from ~/Applications or /Applications — not from this iCloud/dev path."
