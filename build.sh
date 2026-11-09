#!/bin/zsh
# Compiles the app and installs it to ~/Applications/Now Playing.app
set -euo pipefail
cd "${0:A:h}"

APP="$HOME/Applications/Now Playing.app"
BUILD="build/Now Playing.app"

rm -rf build
mkdir -p "$BUILD/Contents/MacOS"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14" main.swift -o "$BUILD/Contents/MacOS/NowPlaying"

cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.nowplaying.card</string>
    <key>CFBundleName</key><string>Now Playing</string>
    <key>CFBundleExecutable</key><string>NowPlaying</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Now Playing reads the current song from Spotify or Music and sends play, pause and skip commands.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUILD"

pkill -x NowPlaying || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$BUILD" "$APP"
echo "Installed to $APP"
