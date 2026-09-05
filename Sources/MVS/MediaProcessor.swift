import Foundation
import Darwin

struct PreparedMedia {
    let title: String
    let mediaID: String
    let archivedVideoURL: URL?
    let audioChunks: [URL]
    let duration: TimeInterval?
    let transcript: TranscriptResult?
    let transcriptModel: String?
    let metadata: MediaMetadataArtifact
    let workingDirectoryURL: URL?
}

@MainActor
final class MediaProcessor {
    private let fileManager = FileManager.default

    func prepareURLVideo(
        _ rawURL: String,
        options: URLAnalysisOptions = .default,
        settings: SettingsStore,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> PreparedMedia {
        guard let sourceURL = URL(string: rawURL),
              let scheme = sourceURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              sourceURL.host != nil else {
            throw MVSError.invalidURL(rawURL)
        }
        let ytDLP = try executable("yt-dlp")
        let tempDir = try makeTempDirectory(prefix: "mvs-url")
        defer { try? fileManager.removeItem(at: tempDir) }
        let outputTemplate = tempDir.appendingPathComponent("%(title).200B-%(id)s.%(ext)s").path

        progress?("Reading video metadata")
        let (metadata, subtitleLanguage) = try await readURLMetadata(rawURL, ytDLP: ytDLP, settings: settings)

        var subtitleTranscript: TranscriptResult?
        if options.preferPlatformSubtitles && !options.forceASR, let subtitleLanguage {
            do {
                progress?("Checking platform subtitles")
                _ = try await ShellRunner.runStreaming(ytDLP, ytdlpBaseArguments(settings: settings) + [
                    "--skip-download",
                    "--ignore-errors",
                    "--write-subs",
                    "--write-auto-subs",
                    "--sub-langs", NSRegularExpression.escapedPattern(for: subtitleLanguage),
                    "--sub-format", "vtt/srt/json3",
                    "-o", outputTemplate,
                    rawURL
                ]) { line in
                    if let message = Self.downloadProgressMessage(from: line) {
                        progress?(message)
                    }
                }
                subtitleTranscript = try parseBestSubtitleTranscript(in: tempDir, duration: metadata.duration)
                if subtitleTranscript != nil {
                    progress?("Platform subtitles found")
                }
            } catch {
                try Task.checkCancellation()
                progress?("Subtitle probe skipped: \(error.localizedDescription)")
            }
        }

        if let subtitleTranscript,
           SubtitleParser.covers(subtitleTranscript, duration: metadata.duration) {
            let archivedVideo: URL?
            if options.keepDownloadedVideo {
                try await downloadVideo(rawURL, ytDLP: ytDLP, outputTemplate: outputTemplate, settings: settings, progress: progress)
                let downloaded = try downloadedMedia(in: tempDir, extensions: ["mp4", "mov", "mkv", "webm"])
                guard let videoURL = downloaded.first else {
                    throw MVSError.processFailed("yt-dlp did not produce a video file.")
                }
                archivedVideo = try await archiveVideo(videoURL, source: .url, title: metadata.title, settings: settings, moveInsteadOfCopy: true)
            } else {
                archivedVideo = nil
            }
            return PreparedMedia(
                title: metadata.title,
                mediaID: metadata.mediaID,
                archivedVideoURL: archivedVideo,
                audioChunks: [],
                duration: metadata.duration,
                transcript: subtitleTranscript,
                transcriptModel: "yt-dlp subtitles",
                metadata: metadata,
                workingDirectoryURL: nil
            )
        }

        if options.keepDownloadedVideo {
            try await downloadVideo(rawURL, ytDLP: ytDLP, outputTemplate: outputTemplate, settings: settings, progress: progress)
            let downloaded = try downloadedMedia(in: tempDir, extensions: ["mp4", "mov", "mkv", "webm"])
            guard let videoURL = downloaded.first else {
                throw MVSError.processFailed("yt-dlp did not produce a video file.")
            }
            return try await prepareExistingVideo(
                videoURL,
                source: .url,
                title: metadata.title,
                settings: settings,
                moveInsteadOfCopy: true,
                progress: progress,
                metadata: metadata
            )
        }

        progress?("Downloading audio for transcription")
        do {
            _ = try await ShellRunner.runStreaming(ytDLP, ytdlpBaseArguments(settings: settings) + [
                "--format", "bestaudio/best",
                "-o", outputTemplate,
                rawURL
            ]) { line in
                if let message = Self.downloadProgressMessage(from: line) {
                    progress?(message.replacingOccurrences(of: "Downloading video", with: "Downloading audio"))
                }
            }
        } catch {
            throw Self.humanizedYTDLPError(error, rawURL: rawURL)
        }
        let audioSources = try downloadedMedia(in: tempDir, extensions: ["m4a", "webm", "opus", "mp3", "aac", "wav", "ogg", "mp4", "mkv"])
        guard let audioSource = audioSources.first else {
            throw MVSError.processFailed("yt-dlp did not produce an audio file.")
        }
        return try await prepareAudioOnly(
            audioSource,
            title: metadata.title,
            metadata: metadata,
            progress: progress
        )
    }

    func prepareExistingVideo(
        _ videoURL: URL,
        source: VideoSourceKind,
        title: String,
        settings: SettingsStore,
        moveInsteadOfCopy: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil,
        transcript: TranscriptResult? = nil,
        transcriptModel: String? = nil,
        metadata: MediaMetadataArtifact? = nil
    ) async throws -> PreparedMedia {
        let archived: URL
        if MVSPaths.isURL(videoURL, inside: settings.videoRootURL) {
            archived = videoURL
        } else {
            progress?("Archiving video")
            archived = try await archiveVideo(videoURL, source: source, title: title, settings: settings, moveInsteadOfCopy: moveInsteadOfCopy)
        }
        let workDirectory = try makeTempDirectory(prefix: "mvs-audio")
        do {
            progress?("Extracting audio with ffmpeg")
            let chunks = try await extractAudioChunks(from: archived, outputDirectory: workDirectory)
            let duration = try? await mediaDuration(for: archived)
            let effectiveTranscript: TranscriptResult?
            let effectiveTranscriptModel: String?
            if let transcript, let duration, !Self.transcriptCoversMedia(transcript, duration: duration) {
                progress?("Downloaded subtitles are incomplete; transcribing audio instead")
                effectiveTranscript = nil
                effectiveTranscriptModel = nil
            } else {
                effectiveTranscript = transcript
                effectiveTranscriptModel = transcriptModel
            }
            var effectiveMetadata = metadata ?? MediaMetadataArtifact(
                mediaID: archived.deletingPathExtension().lastPathComponent,
                title: title,
                sourceURL: nil,
                platform: source.libraryDirectoryName,
                uploader: nil,
                duration: duration,
                webpageURL: nil,
                description: nil,
                chapters: [],
                createdAt: Date()
            )
            effectiveMetadata.duration = effectiveMetadata.duration ?? duration
            return PreparedMedia(
                title: title,
                mediaID: effectiveMetadata.mediaID,
                archivedVideoURL: archived,
                audioChunks: chunks,
                duration: duration,
                transcript: effectiveTranscript,
                transcriptModel: effectiveTranscriptModel,
                metadata: effectiveMetadata,
                workingDirectoryURL: workDirectory
            )
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }
    }

    private func prepareAudioOnly(
        _ sourceURL: URL,
        title: String,
        metadata: MediaMetadataArtifact,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> PreparedMedia {
        let workDirectory = try makeTempDirectory(prefix: "mvs-audio")
        do {
            progress?("Extracting audio with ffmpeg")
            let chunks = try await extractAudioChunks(from: sourceURL, outputDirectory: workDirectory)
            return PreparedMedia(
                title: title,
                mediaID: metadata.mediaID,
                archivedVideoURL: nil,
                audioChunks: chunks,
                duration: metadata.duration,
                transcript: nil,
                transcriptModel: nil,
                metadata: metadata,
                workingDirectoryURL: workDirectory
            )
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }
    }

    func archiveRecordingURL(source: VideoSourceKind, title: String, settings: SettingsStore) throws -> URL {
        let directory = assetDirectory(for: source, settings: settings)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(MVSPaths.timestamp())-\(MVSPaths.sanitizeFilename(title.isEmpty ? source.fallbackTitle : title)).mp4"
        return uniqueURL(directory.appendingPathComponent(fileName))
    }

    func removeGeneratedURLAssets(_ prepared: PreparedMedia) throws {
        guard let archivedVideoURL = prepared.archivedVideoURL else { return }
        let candidates = Set([archivedVideoURL.standardizedFileURL])
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func cleanupWorkingFiles(_ prepared: PreparedMedia) {
        guard let directory = prepared.workingDirectoryURL,
              fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.removeItem(at: directory)
    }

    static func cleanupStaleTemporaryDirectories(olderThan age: TimeInterval = 24 * 60 * 60) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for child in children where child.lastPathComponent.hasPrefix("mvs-url-") || child.lastPathComponent.hasPrefix("mvs-audio-") {
            guard (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let owner = try? String(contentsOf: child.appendingPathComponent(".mvs-owner"), encoding: .utf8),
                  let pid = Int32(owner), pid > 0 else { continue }
            if kill(pid, 0) == 0 || errno == EPERM { continue }
            let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified.map({ $0 < cutoff }) ?? false {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    private func archiveVideo(_ videoURL: URL, source: VideoSourceKind, title: String, settings: SettingsStore, moveInsteadOfCopy: Bool) async throws -> URL {
        let directory = assetDirectory(for: source, settings: settings)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension
        let destination = uniqueURL(directory.appendingPathComponent("\(MVSPaths.timestamp())-\(MVSPaths.sanitizeFilename(title)).\(ext)"))
        try Task.checkCancellation()
        if moveInsteadOfCopy {
            try fileManager.moveItem(at: videoURL, to: destination)
        } else {
            do {
                try await copyFileCancellable(from: videoURL, to: destination)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
        return destination
    }

    private nonisolated func copyFileCancellable(from source: URL, to destination: URL) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let input = try FileHandle(forReadingFrom: source)
                let output = try FileHandle(forWritingTo: destination)
                defer {
                    try? input.close()
                    try? output.close()
                }
                while true {
                    try Task.checkCancellation()
                    guard let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else {
                        break
                    }
                    try output.write(contentsOf: data)
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func assetDirectory(for source: VideoSourceKind, settings: SettingsStore) -> URL {
        settings.videoRootURL.appendingPathComponent(source.libraryDirectoryName, isDirectory: true)
    }

    private func parseBestSubtitleTranscript(in directory: URL, duration: Double?) throws -> TranscriptResult? {
        let subtitles = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["vtt", "srt", "json3"].contains($0.pathExtension.lowercased()) }
            .sorted { SubtitleParser.rank($0.lastPathComponent) < SubtitleParser.rank($1.lastPathComponent) }
        for subtitle in subtitles {
            let content = try String(contentsOf: subtitle, encoding: .utf8)
            if let result = try? SubtitleParser.parse(content, format: subtitle.pathExtension),
               SubtitleParser.covers(result, duration: duration) {
                return result
            }
        }
        return nil
    }

    func extractAudioChunks(from videoURL: URL, outputDirectory: URL, segmentSeconds: Int = 600) async throws -> [URL] {
        let ffmpeg = try executable("ffmpeg")
        let seconds = min(600, max(1, segmentSeconds))
        let template = outputDirectory.appendingPathComponent("chunk-%06d.wav").path
        _ = try await ShellRunner.run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-protocol_whitelist", "file,pipe",
            "-format_whitelist", "mov,matroska,webm,wav,mp3,ogg,flac,aac",
            "-i", videoURL.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
            "-f", "segment", "-segment_time", String(seconds), "-reset_timestamps", "1", template
        ])
        let chunks = try fileManager.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("chunk-") && $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !chunks.isEmpty else { throw MVSError.processFailed("ffmpeg did not create audio chunks.") }
        for chunk in chunks {
            guard let size = try chunk.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 44, size < 25_000_000 else {
                throw MVSError.processFailed("Invalid audio chunk size.")
            }
        }
        return chunks
    }

    private func mediaDuration(for url: URL) async throws -> TimeInterval? {
        let ffprobe = try executable("ffprobe")
        let result = try await ShellRunner.run(ffprobe, [
            "-v", "error",
            "-protocol_whitelist", "file,pipe",
            "-format_whitelist", "mov,matroska,webm,wav,mp3,ogg,flac,aac",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ])
        return TimeInterval(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func executable(_ name: String) throws -> String {
        let candidates = RuntimePaths.toolCandidates(named: name) + [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MVS/bin/\(name)").path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw MVSError.missingExecutable(name)
        }
        return path
    }

    nonisolated static func downloadProgressMessage(from line: String) -> String? {
        let trimmed = DiagnosticRedactor.redact(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[download]") {
            let normalized = trimmed
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: "[download] ", with: "")
            if normalized.contains("%") {
                return "Downloading video · \(normalized)"
            }
            if normalized.localizedCaseInsensitiveContains("destination") {
                return "Downloading video · destination selected"
            }
            if normalized.localizedCaseInsensitiveContains("has already been downloaded") {
                return "Downloading video · already downloaded"
            }
            return "Downloading video · \(normalized)"
        }

        if trimmed.hasPrefix("[Merger]") || trimmed.hasPrefix("[Fixup") || trimmed.hasPrefix("[MoveFiles]") {
            return trimmed
        }

        if trimmed.hasPrefix("ERROR:") || trimmed.hasPrefix("WARNING:") {
            return trimmed
        }

        return nil
    }

    nonisolated static func transcriptCoversMedia(_ transcript: TranscriptResult, duration: TimeInterval) -> Bool {
        SubtitleParser.covers(transcript, duration: duration)
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try String(ProcessInfo.processInfo.processIdentifier).write(to: url.appendingPathComponent(".mvs-owner"), atomically: true, encoding: .utf8)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
        return url
    }

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = url.deletingPathExtension()
                .appendingPathExtension("\(counter)")
                .appendingPathExtension(url.pathExtension)
            counter += 1
        }
        return candidate
    }

    private func ytdlpBaseArguments(settings: SettingsStore) -> [String] {
        var args = [
            "--newline",
            "--ignore-config",
            "--no-update",
            "--no-remote-components",
            "--restrict-filenames",
            "--no-playlist",
            "--retries", "3",
            "--fragment-retries", "3",
            "--extractor-retries", "3",
            "--socket-timeout", "20"
        ]
        if let deno = ["/opt/homebrew/bin/deno", "/usr/local/bin/deno"]
            .first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            args += ["--js-runtimes", "deno:\(deno)"]
        }
        let cookiesFile = settings.youtubeCookiesFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookiesBrowser = settings.youtubeCookiesBrowser.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cookiesFile.isEmpty {
            args += ["--cookies", cookiesFile]
        } else if !cookiesBrowser.isEmpty {
            args += ["--cookies-from-browser", cookiesBrowser]
        }
        let proxy = settings.youtubeProxy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxy.isEmpty {
            if ["direct", "none", "off"].contains(proxy.lowercased()) {
                args += ["--proxy", ""]
            } else {
                args += ["--proxy", proxy.contains("://") ? proxy : "http://\(proxy)"]
            }
        }
        return args
    }

    private func downloadVideo(
        _ rawURL: String,
        ytDLP: String,
        outputTemplate: String,
        settings: SettingsStore,
        progress: (@Sendable (String) -> Void)?
    ) async throws {
        do {
            _ = try await ShellRunner.runStreaming(ytDLP, ytdlpBaseArguments(settings: settings) + [
                "--format", "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best",
                "--merge-output-format", "mp4",
                "-o", outputTemplate,
                rawURL
            ]) { line in
                if let message = Self.downloadProgressMessage(from: line) {
                    progress?(message)
                }
            }
        } catch {
            throw Self.humanizedYTDLPError(error, rawURL: rawURL)
        }
    }

    private func downloadedMedia(in directory: URL, extensions: Set<String>) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { extensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readURLMetadata(_ rawURL: String, ytDLP: String, settings: SettingsStore) async throws -> (MediaMetadataArtifact, String?) {
        let result = try await ShellRunner.run(ytDLP, ytdlpBaseArguments(settings: settings) + [
            "--dump-single-json",
            "--skip-download",
            rawURL
        ], timeout: 120)
        guard let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MVSError.processFailed("yt-dlp returned invalid metadata. Retry after checking the downloader.")
        }
        let title = object["title"] as? String ?? "url-video"
        let id = object["id"] as? String ?? MVSPaths.sanitizeFilename(title)
        let duration = object["duration"] as? Double
        let chapters = (object["chapters"] as? [[String: Any]])?.compactMap { chapter -> String? in
            guard let title = chapter["title"] as? String else { return nil }
            if let start = chapter["start_time"] as? Double {
                return "\(Self.formatSeconds(start)) \(title)"
            }
            return title
        } ?? []
        let artifact = MediaMetadataArtifact(
            mediaID: "\(platformName(for: rawURL))-\(MVSPaths.sanitizeFilename(id))",
            title: title,
            sourceURL: rawURL,
            platform: platformName(for: rawURL),
            uploader: object["uploader"] as? String,
            duration: duration,
            webpageURL: object["webpage_url"] as? String,
            description: object["description"] as? String,
            chapters: chapters,
            createdAt: Date()
        )
        let manual = object["subtitles"] as? [String: Any] ?? [:]
        let automatic = object["automatic_captions"] as? [String: Any] ?? [:]
        let languages = Set(manual.keys).union(automatic.keys).filter { $0 != "live_chat" }
        let language = languages.sorted {
            let left = SubtitleParser.rank($0)
            let right = SubtitleParser.rank($1)
            if left != right { return left < right }
            if (manual[$0] != nil) != (manual[$1] != nil) { return manual[$0] != nil }
            return $0 < $1
        }.first
        return (artifact, language)
    }

    private func platformName(for url: String) -> String {
        let lower = URL(string: url)?.host?.lowercased() ?? ""
        if lower == "youtube.com" || lower.hasSuffix(".youtube.com") || lower == "youtu.be" { return "youtube" }
        if lower.contains("bilibili.com") || lower.contains("b23.tv") { return "bilibili" }
        if lower.contains("xiaoyuzhoufm.com") { return "xiaoyuzhou" }
        if lower.contains("podcasts.apple.com") { return "apple-podcast" }
        return "url"
    }

    nonisolated private static func formatSeconds(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    nonisolated private static func humanizedYTDLPError(_ error: Error, rawURL: String) -> Error {
        let message = error.localizedDescription
        let lower = message.lowercased()
        guard rawURL.lowercased().contains("youtube") || rawURL.lowercased().contains("youtu.be") else {
            return error
        }
        if lower.contains("429") || lower.contains("too many requests") {
            return MVSError.processFailed("YouTube rate limited this request (HTTP 429). Configure YouTube cookies and proxy in Settings, then retry. Original error: \(message)")
        }
        if lower.contains("403") || lower.contains("forbidden") || lower.contains("sign in") || lower.contains("bot") {
            return MVSError.processFailed("YouTube blocked the unauthenticated download. Configure cookies.txt or cookies-from-browser in Settings, then retry. Original error: \(message)")
        }
        return error
    }
}
