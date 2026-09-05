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
        settings: any NoteWritingSettings,
        transcriptModel: String,
        sourceURL: String? = nil,
        includeLocalVideo: Bool = true
    ) throws -> NoteWriteResult {
        let existingLibrary = LibraryStore()
        existingLibrary.refresh(settings: settings)
        let existing = existingLibrary.finishedJobs.first { item in
            guard item.source.libraryDirectoryName == source.libraryDirectoryName else { return false }
            if item.mediaID == prepared.mediaID { return true }
            guard source == .url, let sourceURL, !sourceURL.isEmpty,
                  let handle = try? FileHandle(forReadingFrom: item.noteURL) else { return false }
            defer { try? handle.close() }
            let header = (try? handle.read(upToCount: 64 * 1024)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return NoteFrontMatter(header).value("source_url") == sourceURL
        }
        let title = existing?.title ?? title
        let sourceDirectory = existing?.noteURL.deletingLastPathComponent()
            ?? settings.vaultURL.appendingPathComponent(source.libraryDirectoryName)
        guard MVSPaths.isURL(sourceDirectory, inside: settings.vaultURL) else {
            throw MVSError.processFailed("Note directory is outside the MVS library.")
        }
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let mediaID = prepared.mediaID
        let noteName = existing?.noteURL.lastPathComponent ?? "\(MVSPaths.artifactStem(mediaID)).md"
        let noteURL = sourceDirectory.appendingPathComponent(noteName)
        let artifactBaseURL = noteURL.deletingPathExtension()
        let metadataURL = artifactBaseURL.appendingPathExtension("metadata.json")
        let transcriptSRTURL = artifactBaseURL.appendingPathExtension("transcript.srt")
        let transcriptMarkdownURL = artifactBaseURL.appendingPathExtension("transcript.md")
        let summaryJSONURL = artifactBaseURL.appendingPathExtension("summary.json")
        let outlineURL = artifactBaseURL.appendingPathExtension("outline.md")
        let mindmapURL = artifactBaseURL.appendingPathExtension("mindmap.md")

        let relativeVideo = includeLocalVideo
            ? prepared.archivedVideoURL.map { MVSPaths.relativePath(from: noteURL, to: $0) }
            : nil
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
        var metadata = prepared.metadata
        metadata.title = title
        let files: [(URL, Data)] = [
            (metadataURL, try jsonData(metadata)),
            (transcriptSRTURL, Data(renderSRT(transcript).utf8)),
            (transcriptMarkdownURL, Data(renderTranscriptMarkdown(transcript).utf8)),
            (summaryJSONURL, try jsonData(summary)),
            (outlineURL, Data(renderOutline(summary: summary, title: title).utf8)),
            (mindmapURL, Data(renderMindmap(summary: summary, title: title).utf8)),
            (noteURL, Data(markdown.utf8))
        ]
        try ArtifactTransaction.write(files, directory: sourceDirectory)
        var artifacts = [
            JobArtifact(kind: .note, path: noteURL.path),
            JobArtifact(kind: .metadata, path: metadataURL.path),
            JobArtifact(kind: .transcriptSRT, path: transcriptSRTURL.path),
            JobArtifact(kind: .transcriptMarkdown, path: transcriptMarkdownURL.path),
            JobArtifact(kind: .summaryJSON, path: summaryJSONURL.path),
            JobArtifact(kind: .outline, path: outlineURL.path),
            JobArtifact(kind: .mindmap, path: mindmapURL.path)
        ]
        if includeLocalVideo, let videoURL = prepared.archivedVideoURL {
            artifacts.append(JobArtifact(kind: .video, path: videoURL.path))
        }
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
        settings: any NoteWritingSettings,
        transcriptModel: String
    ) -> String {
        let displayTitle = title.isEmpty ? source.fallbackTitle : title
        let created = ISO8601DateFormatter().string(from: Date())
        let durationLine = duration.map { String(format: "%.0f", $0) } ?? ""
        let timeline = summary.timeline.map { "- \($0)" }.joined(separator: "\n")
        let decisions = summary.keyDecisions.map { "- \($0)" }.joined(separator: "\n")
        let actions = summary.actionItems.map { "- \($0)" }.joined(separator: "\n")
        let keywords = summary.keywords.map { MVSPaths.keyword($0) }.filter { !$0.isEmpty }.map { "#\($0)" }.joined(separator: " ")
        let transcriptText = renderTranscript(transcript)
        let escapedSourceURL = sourceURL ?? ""
        let sourceURLBlock = sourceURL.map { "\n## 原始链接\n\($0)\n" } ?? ""
        let videoPathValue = videoPath ?? ""
        let videoBlock = videoPath.map { "\n![](<\($0)>)\n" } ?? ""

        return """
        ---
        source: \(source.rawValue)
        title: \(NoteFrontMatter.quote(displayTitle))
        created: \(created)
        media_id: \(NoteFrontMatter.quote(mediaID))
        source_url: \(NoteFrontMatter.quote(escapedSourceURL))
        duration: \(durationLine)
        video_path: \(NoteFrontMatter.quote(videoPathValue))
        metadata_path: \(NoteFrontMatter.quote(metadataPath))
        transcript_path: \(NoteFrontMatter.quote(transcriptPath))
        transcript_srt_path: \(NoteFrontMatter.quote(transcriptSRTPath))
        summary_json_path: \(NoteFrontMatter.quote(summaryJSONPath))
        outline_path: \(NoteFrontMatter.quote(outlinePath))
        mindmap_path: \(NoteFrontMatter.quote(mindmapPath))
        transcript_model: \(NoteFrontMatter.quote(transcriptModel))
        summary_model: \(NoteFrontMatter.quote(settings.summaryModel))
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

    private func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
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
        TranscriptText.render(transcript)
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
