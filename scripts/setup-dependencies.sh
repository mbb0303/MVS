#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.tools"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required but was not found at brew."
  exit 1
fi

PYTHON_VERSION="$(cat "$ROOT_DIR/config/python-version")"
HOMEBREW_NO_INSTALL_CLEANUP=1 brew install ffmpeg deno "python@$PYTHON_VERSION"
PYTHON="$(brew --prefix)/bin/python$PYTHON_VERSION"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/.tools-staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

"$PYTHON" -m pip install \
  --no-cache-dir \
  --constraint "$ROOT_DIR/config/runtime-constraints.txt" \
  --target "$STAGING_DIR/yt-dlp-pkg" \
  "yt-dlp[default]==2026.8.19" \
  "yt-dlp-ejs==0.8.0"

"$PYTHON" -m pip install \
  --no-cache-dir \
  --constraint "$ROOT_DIR/config/runtime-constraints.txt" \
  --target "$STAGING_DIR/dashscope-pkg" \
  "dashscope==1.27.2" \
  "typing_extensions==4.15.0" \
  "aiohttp>=3.14.3" \
  "cryptography>=50.0.0" \
  "idna>=3.15" \
  "urllib3>=2.7.0"

find "$STAGING_DIR" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$STAGING_DIR" -type f -name '*.pyc' -delete
cp "$ROOT_DIR/scripts/yt-dlp-launcher.sh" "$STAGING_DIR/yt-dlp"
cp "$ROOT_DIR/config/python-version" "$STAGING_DIR/python-version"
chmod +x "$STAGING_DIR/yt-dlp"
"$STAGING_DIR/yt-dlp" --version
PYTHONNOUSERSITE=1 PYTHONPATH="$STAGING_DIR/dashscope-pkg" "$PYTHON" -s -P -B -c 'from dashscope.audio.asr import Recognition; print("Bailian ASR runtime imported successfully")'
# Promote only after installation and import checks complete.
BACKUP_DIR="$(mktemp -d "$ROOT_DIR/.tools-backup.XXXXXX")"
if [[ -d "$TOOLS_DIR" ]]; then mv "$TOOLS_DIR" "$BACKUP_DIR/previous"; fi
if ! mv "$STAGING_DIR" "$TOOLS_DIR"; then
  if [[ -d "$BACKUP_DIR/previous" ]]; then mv "$BACKUP_DIR/previous" "$TOOLS_DIR"; fi
  exit 1
fi
rm -rf "$BACKUP_DIR"
