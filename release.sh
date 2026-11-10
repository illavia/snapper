#!/bin/bash
# Builds a copy of Snapper that can be given to other people: runs on Apple silicon and Intel,
# signed with the Developer ID certificate and notarised by Apple so it opens without warnings.
#
# One-time setup (stores a login for Apple's notary service in your keychain):
#   xcrun notarytool store-credentials snapper-notary --apple-id <your Apple ID> --team-id K9MT44M2RM
# It asks for an app-specific password, made at account.apple.com > Sign-In and Security.
#
# Usage: ./release.sh            build, sign, notarise, staple, zip
#        ./release.sh --no-notarise   stop after signing (for checking the build)
set -euo pipefail
cd "$(dirname "$0")"
PROFILE="snapper-notary"

IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then echo "No Developer ID Application certificate in the keychain." >&2; exit 1; fi

swift build -c release --arch arm64 --arch x86_64 --product Snapper
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Snapper"

OUT="build/release"
APP="$OUT/Snapper.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snapper"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/Snapper"

ZIP="$OUT/Snapper-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${1:-}" = "--no-notarise" ]; then echo "Signed, not notarised: $ZIP"; exit 0; fi

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Ready to share: $ZIP"
