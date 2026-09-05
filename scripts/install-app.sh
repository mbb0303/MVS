#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_LINK="$ROOT_DIR/dist/MVS.app"

if [[ ! -e "$APP_LINK" ]]; then
  "$ROOT_DIR/scripts/build-app.sh"
fi

APP_SOURCE="$APP_LINK"
if [[ -L "$APP_LINK" ]]; then
  APP_SOURCE="$(readlink "$APP_LINK")"
fi

STAGING_DIR="$(mktemp -d /Applications/.MVS-install.XXXXXX)"
cleanup() {
  if [[ ! -e /Applications/MVS.app && -d "$STAGING_DIR/previous.app" ]]; then
    mv "$STAGING_DIR/previous.app" /Applications/MVS.app
  fi
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
ditto --noextattr "$APP_SOURCE" "$STAGING_DIR/MVS.app"
xattr -cr "$STAGING_DIR/MVS.app"
codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/MVS.app"
if [[ -e /Applications/MVS.app ]]; then
  mv /Applications/MVS.app "$STAGING_DIR/previous.app"
fi
mv "$STAGING_DIR/MVS.app" /Applications/MVS.app

echo /Applications/MVS.app
