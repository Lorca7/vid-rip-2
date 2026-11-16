#!/usr/bin/env bash
# Builds VidRip.app (universal: Apple Silicon + Intel) and a VidRip.dmg installer in dist/.
# Needs macOS with Xcode or the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="dist/VidRip.app"

echo "== Fetching bundled tools"
./scripts/fetch_tools.sh

echo "== Compiling"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "== Assembling $APP"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/VidRip" "$APP/Contents/MacOS/VidRip"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp build/tools/yt-dlp build/tools/ffmpeg build/tools/deno "$APP/Contents/Resources/bin/"
chmod +x "$APP/Contents/Resources/bin/"*

echo "== Icon"
rm -rf build/AppIcon.iconset
swift scripts/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "== Signing (ad-hoc)"
# lipo-merged tools need a fresh signature; leave yt-dlp's own signature alone if it is valid.
codesign --force --sign - "$APP/Contents/Resources/bin/ffmpeg"
codesign --force --sign - "$APP/Contents/Resources/bin/deno"
codesign --verify "$APP/Contents/Resources/bin/yt-dlp" 2>/dev/null || codesign --force --sign - "$APP/Contents/Resources/bin/yt-dlp"
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"

echo "== Disk image"
STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "VidRip" -srcfolder "$STAGE" -ov -format UDZO "dist/VidRip.dmg" >/dev/null

echo "Done:"
ls -lh dist
