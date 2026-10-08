#!/bin/bash
# Builds dist/AgentDeck.app with SwiftPM only (no Xcode needed) and signs it ad hoc for this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AgentDeck
swift build -c release --product AgentDeckWidget

app="dist/AgentDeck.app"
widget="$app/Contents/PlugIns/AgentDeckWidget.appex"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$widget/Contents/MacOS"
cp .build/release/AgentDeck "$app/Contents/MacOS/AgentDeck"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp Packaging/AppIcon.icns Packaging/MenuBarIcon.png Packaging/MenuBarIcon@2x.png "$app/Contents/Resources/"
cp .build/release/AgentDeckWidget "$widget/Contents/MacOS/AgentDeckWidget"
cp Packaging/Widget/Info.plist "$widget/Contents/Info.plist"

# Inside out: the extension (sandboxed, as macOS requires) first, then the app around it.
codesign --force --sign - --entitlements Packaging/Widget/AgentDeckWidget.entitlements "$widget"
codesign --force --sign - "$app"

echo "$app"
