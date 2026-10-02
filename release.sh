#!/bin/zsh
# Bouwt een universele (arm64 + x86_64) release, ondertekent met Developer ID,
# laat Apple notariseren, staplet het ticket en maakt een zip in dist/.
#
# Eenmalig instellen (app-specifiek wachtwoord via appleid.apple.com):
#   xcrun notarytool store-credentials bleproximity --apple-id <apple-id> --team-id VP782V5ARX
#
# Gebruik: ./release.sh [versie]      bv. ./release.sh 1.0
set -e
cd "$(dirname "$0")"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Gerben Hoogendam (VP782V5ARX)}"
PROFILE="${NOTARY_PROFILE:-bleproximity}"
APP="dist/BLE Proximity.app"
ZIP="dist/BLE-Proximity-$VERSION.zip"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/BLEProximity"

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Klaar: $ZIP"
