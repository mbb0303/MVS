import Foundation

struct PreparedMedia {
    let title: String
    let mediaID: String
    let archivedVideoURL: URL
    let audioChunks: [URL]
    let duration: TimeInterval?
    let transcript: TranscriptResult?
    let transcriptModel: String?
    let metadata: MediaMetadataArtifact
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
        guard URL(string: rawURL) != nil else {
            throw MVSError.invalidURL(rawURL)
        }
        let ytDLP = try executable("yt-dlp")
        let tempDir = try makeTempDirectory(prefix: "mvs-url")
        let outputTemplate = tempDir.appendingPathComponent("%(title).200B-%(id)s.%(ext)s").path

        progress?("Reading video metadata")
        let metadata = try await readURLMetadata(rawURL, ytDLP: ytDLP, settings: settings)

        var subtitleTranscript: TranscriptResult?
        if options.preferPlatformSubtitles && !options.forceASR {
            do {
                progress?("Checking platform subtitles")
                _ = try await ShellRunner.runStreaming(ytDLP, ytdlpBaseArguments(settings: settings) + [
                    "--skip-download",
                    "--write-subs",
                    "--write-auto-subs",
                    "--sub-langs", "zh-Hans,zh-CN,zh,zh-TW,zh-Hant,en.*",
                    "--sub-format", "vtt/srt/json3",
                    "-o", outputTemplate,
                    rawURL
                ]) { line in
                    if let message = Self.downloadProgressMessage(from: line) {
                        progress?(message)
                    }
                }
                subtitleTranscript = try parseBestSubtitleTranscript(in: tempDir)
                if subtitleTranscript != nil {
                    progress?("Platform subtitles found")
                }
            } catch {
                progress?("Subtitle probe skipped: \(error.localizedDescription)")
            }
        }

        do {
            _ = try await ShellRunner.runStreaming(ytDLP, ytdlpBaseArguments(settings: settings) + [
            "--newline",
            "--no-playlist",
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

        let downloaded = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.fileSizeKey], options: [])
            .filter { ["mp4", "mov", "mkv", "webm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let videoURL = downloaded.first else {
            throw MVSError.processFailed("yt-dlp did not produce a video file.")
        }
        let title = metadata.title.isEmpty ? videoURL.deletingPathExtension().lastPathComponent : metadata.title
        return try await prepareExistingVideo(
            videoURL,
            source: .url,
            title: title,
            settings: settings,
            moveInsteadOfCopy: true,
            progress: progress,
            transcript: subtitleTranscript,
            transcriptModel: subtitleTranscript == nil ? nil : "yt-dlp subtitles",
            metadata: metadata
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
        if videoURL.standardizedFileURL.path.hasPrefix(settings.videoRootURL.standardizedFileURL.path) {
            archived = videoURL
        } else {
            progress?("Archiving video")
            archived = try archiveVideo(videoURL, source: source, title: title, settings: settings, moveInsteadOfCopy: moveInsteadOfCopy)
        }
        progress?("Extracting audio with ffmpeg")
        let audio = try await extractCompressedAudio(from: archived)
        progress?("Checking audio size")
        let chunks = try await splitAudioIfNeeded(audio) { message in
            progress?(message)
        }
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
        effectiveMetadata.mediaID = archived.deletingPathExtension().lastPathComponent
        effectiveMetadata.duration = effectiveMetadata.duration ?? duration
        return PreparedMedia(
            title: title,
            mediaID: archived.deletingPathExtension().lastPathComponent,
            archivedVideoURL: archived,
            audioChunks: chunks,
            duration: duration,
            transcript: effectiveTranscript,
            transcriptModel: effectiveTranscriptModel,
            metadata: effectiveMetadata
        )
    }

    func archiveRecordingURL(source: VideoSourceKind, title: String, settings: SettingsStore) throws -> URL {
        let directory = assetDirectory(for: source, settings: settings)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(MVSPaths.timestamp())-\(MVSPaths.sanitizeFilename(title.isEmpty ? source.fallbackTitle : title)).mp4"
        return uniqueURL(directory.appendingPathComponent(fileName))
    }

    func removeGeneratedURLAssets(_ prepared: PreparedMedia) throws {
        let candidates = Set(([prepared.archivedVideoURL, prepared.archivedVideoURL.deletingPathExtension().appendingPathExtension("wav")] + prepared.audioChunks).map(\.standardizedFileURL))
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let chunkDirectories = Set(prepared.audioChunks.map { $0.deletingLastPathComponent().standardizedFileURL })
            .filter { $0.lastPathComponent.hasSuffix("-chunks") }
        for directory in chunkDirectories where fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
    }

    private func archiveVideo(_ videoURL: URL, source: VideoSourceKind, title: String, settings: SettingsStore, moveInsteadOfCopy: Bool) throws -> URL {
        let directory = assetDirectory(for: source, settings: settings)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension
        let destination = uniqueURL(directory.appendingPathComponent("\(MVSPaths.timestamp())-\(MVSPaths.sanitizeFilename(title)).\(ext)"))
        if moveInsteadOfCopy {
            try fileManager.moveItem(at: videoURL, to: destination)
        } else {
            try fileManager.copyItem(at: videoURL, to: destination)
        }
        return destination
    }

    private func assetDirectory(for source: VideoSourceKind, settings: SettingsStore) -> URL {
        settings.videoRootURL.appendingPathComponent(source.libraryDirectoryName, isDirectory: true)
    }

    private func parseBestSubtitleTranscript(in directory: URL) throws -> TranscriptResult? {
        let subtitles = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [])
            .filter { ["vtt", "srt"].contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                subtitleRank(lhs.lastPathComponent) < subtitleRank(rhs.lastPathComponent)
            }
        for subtitle in subtitles {
            let result = subtitle.pathExtension.lowercased() == "srt" ? try parseSRTSubtitle(subtitle) : try parseVTTSubtitle(subtitle)
            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return result
            }
        }
        return nil
    }

    private func subtitleRank(_ filename: String) -> Int {
        let lower = filename.lowercased()
        if lower.contains(".zh") { return 0 }
        if lower.contains(".en") { return 1 }
        return 2
    }

    private func parseVTTSubtitle(_ url: URL) throws -> TranscriptResult {
        let content = try String(contentsOf: url, encoding: .utf8)
        var segments: [TranscriptSegment] = []
        var currentStart: Double?
        var currentEnd: Double?
        var textLines: [String] = []

        func flush() {
            let text = textLines
                .map { cleanSubtitleText($0) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !text.isEmpty {
                segments.append(TranscriptSegment(id: "subtitle-\(segments.count)", start: currentStart, end: currentEnd, speaker: nil, text: text))
            }
            currentStart = nil
            currentEnd = nil
            textLines = []
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flush()
                continue
            }
            if line == "WEBVTT" || line.hasPrefix("NOTE") || Int(line) != nil {
                continue
            }
            if line.contains("-->") {
                flush()
                let parts = line.components(separatedBy: "-->")
                currentStart = parseVTTTime(parts.first?.trimmingCharacters(in: .whitespacesAndNewlines))
                let endPart = parts.dropFirst().first?.components(separatedBy: " ").first
                currentEnd = parseVTTTime(endPart?.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                textLines.append(line)
            }
        }
        flush()

        var deduped: [TranscriptSegment] = []
        for segment in segments {
            if deduped.last?.text == segment.text { continue }
            deduped.append(segment)
        }
        let text = deduped.map(\.text).joined(separator: "\n")
        return TranscriptResult(text: text, segments: deduped)
    }

    private func parseSRTSubtitle(_ url: URL) throws -> TranscriptResult {
        let content = try String(contentsOf: url, encoding: .utf8)
        let blocks = content.components(separatedBy: "\n\n")
        var segments: [TranscriptSegment] = []
        for block in blocks {
            let lines = block.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            let start = parseVTTTime(parts.first?.trimmingCharacters(in: .whitespacesAndNewlines))
            let end = parseVTTTime(parts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines))
            let text = lines.dropFirst(timeIndex + 1).map { cleanSubtitleText($0) }.filter { !$0.isEmpty }.joined(separator: " ")
            if !text.isEmpty {
                segments.append(TranscriptSegment(id: "subtitle-\(segments.count)", start: start, end: end, speaker: nil, text: text))
            }
        }
        return TranscriptResult(text: segments.map(\.text).joined(separator: "\n"), segments: segments)
    }

    private func parseVTTTime(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard let last = parts.last, let seconds = Double(last) else { return nil }
        if parts.count == 3 {
            return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60 + seconds
        }
        if parts.count == 2 {
            return (Double(parts[0]) ?? 0) * 60 + seconds
        }
        return seconds
    }

    private func cleanSubtitleText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"&amp;"#, with: "&", options: .regularExpression)
            .replacingOccurrences(of: #"&lt;"#, with: "<", options: .regularExpression)
            .replacingOccurrences(of: #"&gt;"#, with: ">", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractCompressedAudio(from videoURL: URL) async throws -> URL {
        let ffmpeg = try executable("ffmpeg")
        let output = videoURL.deletingPathExtension().appendingPathExtension("wav")
        _ = try await ShellRunner.run(ffmpeg, [
            "-nostdin",
            "-y",
            "-i", videoURL.path,
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            output.path
        ])
        return output
    }

    private func splitAudioIfNeeded(_ audioURL: URL, progress: (@Sendable (String) -> Void)? = nil) async throws -> [URL] {
        let size = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size < 24_000_000 {
            return [audioURL]
        }

        let ffmpeg = try executable("ffmpeg")
        let directory = audioURL.deletingLastPathComponent().appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent + "-chunks")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let template = directory.appendingPathComponent("chunk-%03d.wav").path
        progress?("Splitting long audio for transcription")
        _ = try await ShellRunner.run(ffmpeg, [
            "-nostdin",
            "-y",
            "-i", audioURL.path,
            "-f", "segment",
            "-segment_time", "600",
            "-c", "copy",
            template
        ])
        let chunks = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if chunks.isEmpty {
            throw MVSError.processFailed("ffmpeg did not create audio chunks.")
        }
        return chunks
    }

    private func mediaDuration(for url: URL) async throws -> TimeInterval? {
        let ffprobeCandidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        guard let ffprobe = ffprobeCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let result = try await ShellRunner.run(ffprobe, [
            "-v", "error",
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
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard duration > 60 else { return true }
        let latestEnd = transcript.segments.compactMap(\.end).max() ?? 0
        guard latestEnd > 0 else { return false }
        return latestEnd >= duration * 0.85
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
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
            "--no-playlist",
            "--retries", "3",
            "--fragment-retries", "3",
            "--extractor-retries", "3",
            "--socket-timeout", "20",
            "--remote-components", "ejs:github"
        ]
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

    private func readURLMetadata(_ rawURL: String, ytDLP: String, settings: SettingsStore) async throws -> MediaMetadataArtifact {
        let result = try await ShellRunner.run(ytDLP, ytdlpBaseArguments(settings: settings) + [
            "--dump-single-json",
            "--skip-download",
            rawURL
        ])
        guard let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MediaMetadataArtifact(mediaID: UUID().uuidString, title: "url-video", sourceURL: rawURL, platform: platformName(for: rawURL), uploader: nil, duration: nil, webpageURL: rawURL, description: nil, chapters: [], createdAt: Date())
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
        return MediaMetadataArtifact(
            mediaID: MVSPaths.sanitizeFilename("\(title)-\(id)"),
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
    }

    private func platformName(for url: String) -> String {
        let lower = url.lowercased()
        if lower.contains("youtube.com") || lower.contains("youtu.be") { return "youtube" }
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
