#!/bin/bash
# Builds MetaDrag.app from source into ./release. Pass --install to copy it to /Applications and open it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MetaDrag"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources

APP="release/MetaDrag.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MetaDrag"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# ad-hoc signature: runs locally; no Gatekeeper workarounds needed for a build you made yourself
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "MetaDrag"' >/dev/null 2>&1 || true
  pkill -x MetaDrag 2>/dev/null || true
  rm -rf /Applications/MetaDrag.app
  ditto "$APP" /Applications/MetaDrag.app
  open /Applications/MetaDrag.app
  echo "Installed to /Applications and launched. Look for the ring in the menu bar."
fi
