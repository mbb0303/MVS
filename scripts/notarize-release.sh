#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_IDENTITY="${MVS_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MVS_NOTARY_PROFILE:-MVS_NOTARY}"

if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  echo "Set MVS_SIGN_IDENTITY to a Developer ID Application identity."
  exit 1
fi

MVS_SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT_DIR/scripts/build-app.sh"
MVS_SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT_DIR/scripts/build-dmg.sh"

xcrun notarytool submit "$ROOT_DIR/dist/MVS.dmg" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$ROOT_DIR/dist/MVS.dmg"
xcrun stapler validate "$ROOT_DIR/dist/MVS.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$ROOT_DIR/dist/MVS.dmg"

echo "$ROOT_DIR/dist/MVS.dmg"
