#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/MVS.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$ROOT_DIR/assets/AppIconSource.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
ICNS_PATH="$RESOURCES_DIR/AppIcon.icns"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing icon source: $ICON_SOURCE"
  exit 1
fi

cd "$ROOT_DIR"
env CLANG_MODULE_CACHE_PATH=.build/module-cache SWIFTPM_CACHE_PATH=.build/swiftpm-cache swift build -c release

rm -rf "$APP_DIR" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

cp "$ROOT_DIR/.build/release/MVS" "$MACOS_DIR/MVS"
chmod +x "$MACOS_DIR/MVS"

cp -R "$ROOT_DIR/scripts" "$RESOURCES_DIR/scripts"
if [[ -d "$ROOT_DIR/.tools" ]]; then
  cp -R "$ROOT_DIR/.tools" "$RESOURCES_DIR/.tools"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MVS</string>
    <key>CFBundleIdentifier</key>
    <string>local.mbb.mvs</string>
    <key>CFBundleName</key>
    <string>MVS</string>
    <key>CFBundleDisplayName</key>
    <string>MVS</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MVS records microphone audio while recording online meetings.</string>
    <key>NSScreenCaptureDescription</key>
    <string>MVS records the selected screen or meeting window so it can summarize the meeting into Obsidian.</string>
</dict>
</plist>
PLIST

echo "$APP_DIR"
