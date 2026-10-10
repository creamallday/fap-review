#!/bin/bash
# Builds "FAP Memo Reviewer.app" (universal: Apple silicon + Intel) into dist/ and zips it.
# Requires macOS with Xcode or the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FAP Memo Reviewer"
APP="dist/$APP_NAME.app"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}" --product FAPMemoReviewer
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FAPMemoReviewer" "$APP/Contents/MacOS/FAPMemoReviewer"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
fi
iconutil -c icns Packaging/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles of dependencies, if any.
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

# Ad-hoc signature: required to launch on Apple silicon. Not notarized.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

(cd dist && rm -f FAP-Memo-Reviewer.zip && ditto -c -k --keepParent "$APP_NAME.app" FAP-Memo-Reviewer.zip)
echo "Built $APP and dist/FAP-Memo-Reviewer.zip"
