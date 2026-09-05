#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Native wheels in the runtime are built for this Python minor version.
PYTHON_VERSION="$(cat "$SCRIPT_DIR/python-version")"
PYTHON=""
for candidate in "/opt/homebrew/bin/python$PYTHON_VERSION" "/opt/homebrew/opt/python@$PYTHON_VERSION/bin/python$PYTHON_VERSION" "/usr/local/bin/python$PYTHON_VERSION"; do
  if [[ -x "$candidate" ]]; then
    PYTHON="$candidate"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  echo "MVS requires Python $PYTHON_VERSION. Install it with: brew install python@$PYTHON_VERSION" >&2
  exit 1
fi
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$SCRIPT_DIR/yt-dlp-pkg" exec "$PYTHON" -s -P -B -m yt_dlp "$@"
