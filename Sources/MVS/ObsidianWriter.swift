import Foundation

@MainActor
final class ObsidianWriter {
    private let fileManager = FileManager.default

    func writeNote(
        source: VideoSourceKind,
        title: String,
        prepared: PreparedMedia,
        transcript: TranscriptResult,
        summary: SummaryResult,
        settings: SettingsStore,
        transcriptModel: String,
        sourceURL: String? = nil,
        includeLocalVideo: Bool = true
    ) throws -> NoteWriteResult {
        let sourceDirectory = settings.vaultURL.appendingPathComponent(source.libraryDirectoryName)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let mediaID = prepared.mediaID
        let noteName = "\(MVSPaths.sanitizeFilename(mediaID)).md"
        let noteURL = sourceDirectory.appendingPathComponent(noteName)
        let artifactBaseURL = sourceDirectory.appendingPathComponent(MVSPaths.sanitizeFilename(mediaID))
        let metadataURL = artifactBaseURL.appendingPathExtension("metadata.json")
        let transcriptSRTURL = artifactBaseURL.appendingPathExtension("transcript.srt")
        let transcriptMarkdownURL = artifactBaseURL.appendingPathExtension("transcript.md")
        let summaryJSONURL = artifactBaseURL.appendingPathExtension("summary.json")
        let outlineURL = artifactBaseURL.appendingPathExtension("outline.md")
        let mindmapURL = artifactBaseURL.appendingPathExtension("mindmap.md")

        try writeJSON(prepared.metadata, to: metadataURL)
        try renderSRT(transcript).write(to: transcriptSRTURL, atomically: true, encoding: .utf8)
        try renderTranscriptMarkdown(transcript).write(to: transcriptMarkdownURL, atomically: true, encoding: .utf8)
        try writeJSON(summary, to: summaryJSONURL)
        try renderOutline(summary: summary, title: title).write(to: outlineURL, atomically: true, encoding: .utf8)
        try renderMindmap(summary: summary, title: title).write(to: mindmapURL, atomically: true, encoding: .utf8)

        let relativeVideo = includeLocalVideo ? MVSPaths.relativePath(from: noteURL, to: prepared.archivedVideoURL) : nil
        let markdown = renderMarkdown(
            source: source,
            title: title,
            mediaID: mediaID,
            videoPath: relativeVideo,
            sourceURL: sourceURL,
            duration: prepared.duration,
            metadataPath: MVSPaths.relativePath(from: noteURL, to: metadataURL),
            transcriptPath: MVSPaths.relativePath(from: noteURL, to: transcriptMarkdownURL),
            transcriptSRTPath: MVSPaths.relativePath(from: noteURL, to: transcriptSRTURL),
            summaryJSONPath: MVSPaths.relativePath(from: noteURL, to: summaryJSONURL),
            outlinePath: MVSPaths.relativePath(from: noteURL, to: outlineURL),
            mindmapPath: MVSPaths.relativePath(from: noteURL, to: mindmapURL),
            transcript: transcript,
            summary: summary,
            settings: settings,
            transcriptModel: transcriptModel
        )
        try markdown.write(to: noteURL, atomically: true, encoding: .utf8)
        let artifacts = [
            JobArtifact(kind: .note, path: noteURL.path),
            JobArtifact(kind: .video, path: prepared.archivedVideoURL.path),
            JobArtifact(kind: .metadata, path: metadataURL.path),
            JobArtifact(kind: .transcriptSRT, path: transcriptSRTURL.path),
            JobArtifact(kind: .transcriptMarkdown, path: transcriptMarkdownURL.path),
            JobArtifact(kind: .summaryJSON, path: summaryJSONURL.path),
            JobArtifact(kind: .outline, path: outlineURL.path),
            JobArtifact(kind: .mindmap, path: mindmapURL.path)
        ]
        return NoteWriteResult(noteURL: noteURL, artifacts: artifacts)
    }

    private func renderMarkdown(
        source: VideoSourceKind,
        title: String,
        mediaID: String,
        videoPath: String?,
        sourceURL: String?,
        duration: TimeInterval?,
        metadataPath: String,
        transcriptPath: String,
        transcriptSRTPath: String,
        summaryJSONPath: String,
        outlinePath: String,
        mindmapPath: String,
        transcript: TranscriptResult,
        summary: SummaryResult,
        settings: SettingsStore,
        transcriptModel: String
    ) -> String {
        let displayTitle = title.isEmpty ? source.fallbackTitle : title
        let created = ISO8601DateFormatter().string(from: Date())
        let durationLine = duration.map { String(format: "%.0f", $0) } ?? ""
        let timeline = summary.timeline.map { "- \($0)" }.joined(separator: "\n")
        let decisions = summary.keyDecisions.map { "- \($0)" }.joined(separator: "\n")
        let actions = summary.actionItems.map { "- \($0)" }.joined(separator: "\n")
        let keywords = summary.keywords.map { "#\(MVSPaths.sanitizeFilename($0))" }.joined(separator: " ")
        let transcriptText = renderTranscript(transcript)
        let escapedSourceURL = sourceURL?.replacingOccurrences(of: "\"", with: "\\\"") ?? ""
        let sourceURLBlock = sourceURL.map { "\n## 原始链接\n\($0)\n" } ?? ""
        let videoPathValue = videoPath ?? ""
        let videoBlock = videoPath.map { "\n![](\($0))\n" } ?? ""

        return """
        ---
        source: \(source.rawValue)
        title: "\(displayTitle.replacingOccurrences(of: "\"", with: "\\\""))"
        created: \(created)
        media_id: "\(mediaID.replacingOccurrences(of: "\"", with: "\\\""))"
        source_url: "\(escapedSourceURL)"
        duration: \(durationLine)
        video_path: "\(videoPathValue)"
        metadata_path: "\(metadataPath)"
        transcript_path: "\(transcriptPath)"
        transcript_srt_path: "\(transcriptSRTPath)"
        summary_json_path: "\(summaryJSONPath)"
        outline_path: "\(outlinePath)"
        mindmap_path: "\(mindmapPath)"
        transcript_model: "\(transcriptModel)"
        summary_model: "\(settings.summaryModel)"
        ---

        # \(displayTitle)
        \(videoBlock)\(sourceURLBlock)

        ## 摘要
        \(summary.summary)

        ## 章节时间线
        \(timeline.isEmpty ? "- No timeline extracted." : timeline)

        ## 关键结论
        \(decisions.isEmpty ? "- No key decisions extracted." : decisions)

        ## 待办事项
        \(actions.isEmpty ? "- No action items extracted." : actions)

        ## 关键词
        \(keywords.isEmpty ? "No keywords extracted." : keywords)

        ## 完整逐字稿
        \(transcriptText)
        """
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func renderTranscriptMarkdown(_ transcript: TranscriptResult) -> String {
        """
        # Transcript

        \(renderTranscript(transcript))
        """
    }

    private func renderSRT(_ transcript: TranscriptResult) -> String {
        let segments: [TranscriptSegment]
        if transcript.segments.isEmpty {
            segments = [TranscriptSegment(id: "text", start: 0, end: 1, speaker: nil, text: transcript.text)]
        } else {
            segments = transcript.segments
        }
        return segments.enumerated().map { index, segment in
            let start = segment.start ?? Double(index)
            let end = max(segment.end ?? (start + 1), start + 0.5)
            let speaker = segment.speaker.map { "\($0): " } ?? ""
            return """
            \(index + 1)
            \(formatSRTTime(start)) --> \(formatSRTTime(end))
            \(speaker)\(segment.text)
            """
        }.joined(separator: "\n\n")
    }

    private func renderOutline(summary: SummaryResult, title: String) -> String {
        let timeline = summary.timeline.map { "- \($0)" }.joined(separator: "\n")
        let decisions = summary.keyDecisions.map { "- \($0)" }.joined(separator: "\n")
        let actions = summary.actionItems.map { "- \($0)" }.joined(separator: "\n")
        return """
        # \(title)

        ## Timeline
        \(timeline.isEmpty ? "- No timeline extracted." : timeline)

        ## Key Decisions
        \(decisions.isEmpty ? "- No key decisions extracted." : decisions)

        ## Action Items
        \(actions.isEmpty ? "- No action items extracted." : actions)
        """
    }

    private func renderMindmap(summary: SummaryResult, title: String) -> String {
        let keywords = summary.keywords.map { "  - \($0)" }.joined(separator: "\n")
        let timeline = summary.timeline.map { "  - \($0)" }.joined(separator: "\n")
        return """
        - \(title)
          - 摘要
            - \(summary.summary.replacingOccurrences(of: "\n", with: " "))
          - 章节
        \(timeline.isEmpty ? "  - No timeline extracted." : timeline)
          - 关键词
        \(keywords.isEmpty ? "  - No keywords extracted." : keywords)
        """
    }

    private func renderTranscript(_ transcript: TranscriptResult) -> String {
        guard !transcript.segments.isEmpty else {
            return transcript.text
        }
        return transcript.segments.map { segment in
            var prefix = ""
            if let start = segment.start {
                prefix += "[\(formatTime(start))]"
            }
            if let speaker = segment.speaker, !speaker.isEmpty {
                prefix += prefix.isEmpty ? "\(speaker):" : " \(speaker):"
            }
            return prefix.isEmpty ? segment.text : "\(prefix) \(segment.text)"
        }.joined(separator: "\n\n")
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func formatSRTTime(_ seconds: Double) -> String {
        let totalMS = Int((seconds * 1000).rounded())
        let ms = totalMS % 1000
        let totalSeconds = totalMS / 1000
        return String(format: "%02d:%02d:%02d,%03d", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60, ms)
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
}
