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

rm -rf /Applications/MVS.app
ditto --noextattr "$APP_SOURCE" /Applications/MVS.app
xattr -cr /Applications/MVS.app
codesign --verify --deep --strict --verbose=2 /Applications/MVS.app

echo /Applications/MVS.app
