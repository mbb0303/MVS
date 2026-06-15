#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/MVS.app"
DMG_PATH="$ROOT_DIR/dist/MVS.dmg"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/dist/mvs-dmg-staging.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT_DIR/scripts/build-app.sh"
fi

cp -R "$APP_DIR" "$STAGING_DIR/MVS.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "MVS" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "$DMG_PATH"
