#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.tools"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required but was not found at brew."
  exit 1
fi

HOMEBREW_NO_INSTALL_CLEANUP=1 brew install ffmpeg deno

rm -rf "$TOOLS_DIR"
mkdir -p "$TOOLS_DIR"

python3 -m pip install \
  --no-cache-dir \
  --target "$TOOLS_DIR/yt-dlp-pkg" \
  "yt-dlp[default]==2026.8.19" \
  "yt-dlp-ejs==0.8.0"

python3 -m pip install \
  --no-cache-dir \
  --target "$TOOLS_DIR/dashscope-pkg" \
  "dashscope==1.27.2" \
  "typing_extensions==4.15.0" \
  "aiohttp>=3.14.3" \
  "cryptography>=50.0.0" \
  "idna>=3.15" \
  "urllib3>=2.7.0"

find "$TOOLS_DIR" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$TOOLS_DIR" -type f -name '*.pyc' -delete

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
PYTHONNOUSERSITE=1 PYTHONPATH="$SCRIPT_DIR/yt-dlp-pkg" exec "$PYTHON" -m yt_dlp "$@"
EOF
chmod +x "$ROOT_DIR/.tools/yt-dlp"

"$ROOT_DIR/.tools/yt-dlp" --version
PYTHONNOUSERSITE=1 PYTHONPATH="$TOOLS_DIR/dashscope-pkg" python3 -c 'import aiohttp, cryptography, dashscope, idna, urllib3; print("dashscope dependencies imported successfully")'
