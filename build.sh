#!/bin/zsh
# Bouwt BLE Proximity.app (release) en ondertekent ad-hoc.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/BLE Proximity.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/BLEProximity "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Klaar: $APP"
[[ "$1" == "--run" ]] && open "$APP"
exit 0
