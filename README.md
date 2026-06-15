# MVS

MVS is a native macOS app for analyzing public video URLs, local video files, and manually recorded online meetings. It downloads or records media, transcribes audio, summarizes the content, and stores the generated notes and artifacts in an MVS-owned local library.

The current target is Apple Silicon macOS.

## Features

- Analyze public video URLs with `yt-dlp`.
- Import local `.mp4`, `.mov`, `.mkv`, and `.webm` files.
- Manually record Zoom, Tencent Meeting, or any selected screen/window with ScreenCaptureKit.
- Capture system audio and microphone audio on macOS 15+.
- Prefer platform subtitles for URL videos, then fall back to ASR when subtitles are unavailable or incomplete.
- Transcribe audio with Alibaba Bailian ASR or OpenAI transcription.
- Summarize transcripts with DeepSeek, Alibaba Bailian Qwen, or OpenAI.
- Split long transcripts into chunks before summary generation.
- Generate Markdown notes, metadata, SRT transcripts, transcript Markdown, summary JSON, outline, and mindmap files.
- Persist job history in SQLite and show resumable/retryable jobs in the UI.
- Package as a macOS `.app` and `.dmg`.

## Default Storage

MVS does not store generated files inside `/Applications/MVS.app`.

By default, all user-generated files are stored in:

```text
~/Library/Application Support/MVS/Library
```

The library structure is:

```text
Library/
  URL/
  Local/
  Meeting/
  assets/
    URL/
    Local/
    Meeting/
  .mvs/
    jobs.sqlite
```

Each completed job may generate:

- `*.md` note
- `*.metadata.json`
- `*.transcript.srt`
- `*.transcript.md`
- `*.summary.json`
- `*.outline.md`
- `*.mindmap.md`
- archived video/audio assets under `assets/`

The library path can be changed in Settings.

## Requirements

- macOS 15 or newer
- Apple Silicon Mac recommended
- Xcode command line tools / Swift 6 toolchain
- Homebrew
- Python 3
- `ffmpeg`
- `yt-dlp`

Install media/runtime dependencies:

```bash
scripts/setup-dependencies.sh
```

This installs `ffmpeg` with Homebrew and project-local Python packages under `.tools/`. The `.tools/` directory is intentionally ignored by git.

## Run From Source

```bash
swift run MVS
```

Run tests:

```bash
env CLANG_MODULE_CACHE_PATH=.build/module-cache \
  SWIFTPM_CACHE_PATH=.build/swiftpm-cache \
  swift test
```

## Build App And DMG

Build the app bundle:

```bash
scripts/build-app.sh
open dist/MVS.app
```

Build a DMG installer:

```bash
scripts/build-dmg.sh
open dist/MVS.dmg
```

Install the latest local build to `/Applications`:

```bash
rsync -a --delete dist/MVS.app/ /Applications/MVS.app/
```

## API Configuration

Open **API Settings** in the app.

MVS stores API keys in macOS Keychain, not in source files or JSON config.

Supported providers:

- Transcription: Alibaba Bailian ASR, OpenAI
- Summary: DeepSeek, Alibaba Bailian Qwen, OpenAI

Recommended current setup:

- Transcription provider: Alibaba Bailian ASR
- Summary provider: DeepSeek

For YouTube downloads, Settings also supports:

- `cookies.txt`
- cookies from browser
- proxy URL
- platform subtitle preference
- force-ASR mode

## Permissions

For meeting recording, macOS may request:

```text
System Settings -> Privacy & Security -> Screen & System Audio Recording
System Settings -> Privacy & Security -> Microphone
```

Enable the app or the terminal host used to launch MVS.

## Notes

- Public URL support depends on `yt-dlp` and the target platform.
- Logged-in, paid, private, DRM-protected, or heavily rate-limited links may require cookies or may not work.
- URL videos default to not keeping downloaded video after the note is generated, unless `Keep downloaded video` is enabled.
- Meeting recording is manual: choose a capture target, start recording, stop recording, then MVS processes the saved video.
