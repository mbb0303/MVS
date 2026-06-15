#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required but was not found at brew."
  exit 1
fi

brew install ffmpeg

python3 -m pip install --upgrade --target "$ROOT_DIR/.tools/yt-dlp-pkg" yt-dlp
python3 -m pip install --upgrade --target "$ROOT_DIR/.tools/dashscope-pkg" dashscope typing_extensions

cat > "$ROOT_DIR/.tools/yt-dlp" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MVS_PYTHON:-}" && -x "$MVS_PYTHON" ]]; then
  PYTHON="$MVS_PYTHON"
elif [[ -x /opt/homebrew/bin/python3 ]]; then
  PYTHON="/opt/homebrew/bin/python3"
elif [[ -x /usr/local/bin/python3 ]]; then
  PYTHON="/usr/local/bin/python3"
else
  PYTHON="/usr/bin/python3"
fi
PYTHONPATH="$SCRIPT_DIR/yt-dlp-pkg${PYTHONPATH:+:$PYTHONPATH}" exec "$PYTHON" -m yt_dlp "$@"
EOF
chmod +x "$ROOT_DIR/.tools/yt-dlp"

"$ROOT_DIR/.tools/yt-dlp" --version
