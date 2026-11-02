#!/bin/bash
# Builds "Audio Router.app" into ./build — needs only the Xcode command line tools
# (xcode-select --install) and macOS 14.2 or later.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Audio Router.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.2" \
  -framework CoreAudio -framework AppKit -framework SwiftUI -framework ServiceManagement \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/AudioRouter"

cp Info.plist "$APP/Contents/Info.plist"

# App icon: turn Icon/icon.png (1024×1024) into AppIcon.icns
mkdir -p "$APP/Contents/Resources"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Icon/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Icon/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built: $APP"
echo "Run it with:  open \"$APP\"   (or drag it into /Applications first)"
