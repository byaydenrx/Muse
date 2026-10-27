#!/bin/zsh
# Builds Muse.app into ./build and signs it ad hoc for local use.
set -e
cd "$(dirname "$0")"
ARCHS=(--arch arm64 --arch x86_64)  # universal: Apple silicon and Intel
swift build -c release $ARCHS
BIN=$(swift build -c release $ARCHS --show-bin-path)
APP=build/Muse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Muse" "$APP/Contents/MacOS/Muse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
