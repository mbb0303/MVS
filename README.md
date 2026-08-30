# MVS

MVS is a native macOS app for analyzing public video URLs, local video files, and manually recorded online meetings. It downloads or records media, transcribes audio, summarizes the content, and stores the generated notes and artifacts in an MVS-owned local library.

The current target is Apple Silicon macOS.

## Features

- Analyze public video URLs with `yt-dlp`.
- Import local `.mp4`, `.mov`, `.mkv`, and `.webm` files.
- Manually record Zoom, Tencent Meeting, or any selected screen/window with ScreenCaptureKit.
- Capture system audio and microphone audio on macOS 15+.
- Use direct Screen mode to record an entire display with computer playback audio; microphone capture is optional and disabled by default in this mode.
- Prefer platform subtitles for URL videos, then fall back to ASR when subtitles are unavailable or incomplete.
- Transcribe audio with Alibaba Bailian ASR or OpenAI transcription.
- Summarize transcripts with DeepSeek, Alibaba Bailian Qwen, or OpenAI.
- Split long transcripts into chunks before summary generation.
- Generate Markdown notes, metadata, SRT transcripts, transcript Markdown, summary JSON, outline, and mindmap files.
- Persist job history in SQLite and show resumable/retryable jobs in the UI.
- Separate New Task, Jobs, and Library workspaces with in-app note and artifact reading.
- Search and filter jobs/library items, inspect per-stage progress, and erase generated history without clearing API keys.
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
- Deno (used by the bundled `yt-dlp-ejs` YouTube challenge solver)
- `yt-dlp`

Install media/runtime dependencies:

```bash
scripts/setup-dependencies.sh
```

This installs `ffmpeg` and Deno with Homebrew, then creates a clean project-local runtime under `.tools/`. Security-sensitive dependencies are constrained to patched versions, and yt-dlp remote component downloads are disabled at runtime.

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

The real signed bundle is built outside iCloud under `~/Library/Caches/MVS/Build/MVS.app`; `dist/MVS.app` is a convenience link. This prevents iCloud File Provider metadata from invalidating the code signature.

Build a DMG installer:

```bash
scripts/build-dmg.sh
open dist/MVS.dmg
```

Install the latest local build to `/Applications`:

```bash
scripts/install-app.sh
```

Local builds receive a sealed ad-hoc signature with Hardened Runtime. For a distributable Developer ID build, first install a `Developer ID Application` certificate and store notary credentials once:

```bash
xcrun notarytool store-credentials MVS_NOTARY
export MVS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
scripts/notarize-release.sh
```

The release script signs all nested native modules, signs the app and DMG with a secure timestamp, submits through `notarytool`, staples the ticket, and runs Gatekeeper validation.

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

Screen recording permission is tied to the installed app's code signature. After replacing a local ad-hoc build, open Meeting capture, click Refresh once, enable the current `MVS.app` in Privacy & Security, then quit and reopen MVS. Repeated Refresh clicks in the same session do not repeatedly request permission. Tencent Meeting windows are matched by bundle identifier `com.tencent.meeting`, with displays available as fallback targets.

Microphone permission is independent from system audio capture. Zoom and Tencent modes enable the microphone option by default, while Screen mode defaults to system audio only. If microphone access is unavailable, turn off the Microphone switch to continue recording the selected window/display and computer playback audio.

## Notes

- Public URL support depends on `yt-dlp` and the target platform.
- Logged-in, paid, private, DRM-protected, or heavily rate-limited links may require cookies or may not work.
- URL videos default to not keeping downloaded video after the note is generated, unless `Keep downloaded video` is enabled.
- When complete platform subtitles are available and video retention is disabled, MVS skips video and audio download entirely. Otherwise it downloads audio-only for ASR unless the user explicitly keeps the video.
- Cancel terminates active yt-dlp, ffmpeg, Python, and network work. Task audio is stored in a temporary workspace and removed on success, failure, or cancellation.
- Meeting recording is manual: choose a capture target, start recording, stop recording, then MVS processes the saved video.
