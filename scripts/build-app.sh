#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_OUTPUT_DIR="${MVS_BUILD_OUTPUT_DIR:-$HOME/Library/Caches/MVS/Build}"
APP_DIR="$BUILD_OUTPUT_DIR/MVS.app"
DIST_APP_LINK="$ROOT_DIR/dist/MVS.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$ROOT_DIR/assets/AppIconSource.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
ICNS_PATH="$RESOURCES_DIR/AppIcon.icns"
ENTITLEMENTS_PATH="$ROOT_DIR/config/MVS.entitlements"
SIGN_IDENTITY="${MVS_SIGN_IDENTITY:--}"
APP_VERSION="${MVS_APP_VERSION:-0.2.0}"
BUILD_NUMBER="${MVS_BUILD_NUMBER:-2}"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing icon source: $ICON_SOURCE"
  exit 1
fi

if [[ ! -x "$ROOT_DIR/.tools/yt-dlp" || ! -d "$ROOT_DIR/.tools/dashscope-pkg" ]]; then
  echo "Missing runtime dependencies. Run scripts/setup-dependencies.sh first."
  exit 1
fi

cd "$ROOT_DIR"
env CLANG_MODULE_CACHE_PATH=.build/module-cache SWIFTPM_CACHE_PATH=.build/swiftpm-cache swift build -c release

rm -rf "$APP_DIR" "$DIST_APP_LINK" "$ICONSET_DIR"
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

mkdir -p "$RESOURCES_DIR/scripts"
cp "$ROOT_DIR/scripts/transcribe-bailian-asr.py" "$RESOURCES_DIR/scripts/transcribe-bailian-asr.py"
chmod +x "$RESOURCES_DIR/scripts/transcribe-bailian-asr.py"
cp -R "$ROOT_DIR/.tools" "$RESOURCES_DIR/.tools"
find "$RESOURCES_DIR/.tools" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$RESOURCES_DIR/.tools" -type f -name '*.pyc' -delete
rm -rf "$RESOURCES_DIR/.tools/yt-dlp-pkg/share"

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
    <string>__APP_VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__BUILD_NUMBER__</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MVS records microphone audio while recording online meetings.</string>
    <key>NSScreenCaptureDescription</key>
    <string>MVS records the selected screen or meeting window so it can create a local transcript and summary.</string>
</dict>
</plist>
PLIST

sed -i '' "s/__APP_VERSION__/$APP_VERSION/g; s/__BUILD_NUMBER__/$BUILD_NUMBER/g" "$CONTENTS_DIR/Info.plist"
xattr -cr "$APP_DIR"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
else
  SIGN_ARGS+=(--options runtime)
fi

while IFS= read -r -d '' nested_code; do
  codesign "${SIGN_ARGS[@]}" "$nested_code"
done < <(find "$APP_DIR" -type f \( -name '*.so' -o -name '*.dylib' \) -print0)

xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

mkdir -p "$ROOT_DIR/dist"
ln -s "$APP_DIR" "$DIST_APP_LINK"

echo "$APP_DIR"
