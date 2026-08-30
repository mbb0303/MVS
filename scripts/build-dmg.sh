#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_LINK="$ROOT_DIR/dist/MVS.app"
APP_DIR="$APP_LINK"
DMG_PATH="$ROOT_DIR/dist/MVS.dmg"
STAGING_DIR="$(mktemp -d /private/tmp/mvs-dmg-staging.XXXXXX)"
SIGN_IDENTITY="${MVS_SIGN_IDENTITY:-}"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ ! -e "$APP_LINK" ]]; then
  "$ROOT_DIR/scripts/build-app.sh"
fi

if [[ -L "$APP_LINK" ]]; then
  APP_DIR="$(readlink "$APP_LINK")"
fi

ditto --noextattr "$APP_DIR" "$STAGING_DIR/MVS.app"
xattr -cr "$STAGING_DIR/MVS.app"
codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/MVS.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "MVS" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

echo "$DMG_PATH"
