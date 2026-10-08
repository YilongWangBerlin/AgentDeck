#!/bin/bash
# Builds dist/AgentDeck.app with SwiftPM only (no Xcode needed) and signs it ad hoc for this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AgentDeck

app="dist/AgentDeck.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/AgentDeck "$app/Contents/MacOS/AgentDeck"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp Packaging/AppIcon.icns Packaging/MenuBarIcon.png Packaging/MenuBarIcon@2x.png "$app/Contents/Resources/"
codesign --force --sign - "$app"

echo "$app"
