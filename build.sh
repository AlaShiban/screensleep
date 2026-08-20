#!/bin/bash
# Builds ScreenSleep.app into ./build/. Pass --install to copy it to /Applications,
# and --run to (re)launch it afterwards.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/ScreenSleep.app"

swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN=$(swift build -c release --show-bin-path 2>/dev/null)/ScreenSleep

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenSleep"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built $APP"

if [[ " $* " == *" --install "* ]]; then
	pkill -x ScreenSleep 2>/dev/null || true
	rm -rf /Applications/ScreenSleep.app
	cp -R "$APP" /Applications/
	echo "Installed /Applications/ScreenSleep.app"
	APP=/Applications/ScreenSleep.app
fi

if [[ " $* " == *" --run "* ]]; then
	pkill -x ScreenSleep 2>/dev/null || true
	open "$APP"
	echo "Launched — look for the sun icon in the menu bar."
fi
