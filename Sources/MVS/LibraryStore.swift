import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var finishedJobs: [FinishedJob] = []
    @Published private(set) var pendingVideos: [PendingVideoSummary] = []
    @Published private(set) var lastScanError: String?

    private let fileManager = FileManager.default
    private let videoExtensions = Set(["mp4", "mov", "mkv", "webm"])

    func refresh(settings: SettingsStore) {
        do {
            try ensureLibraryDirectories(settings: settings)
            let finished = try scanFinishedJobs(settings: settings)
            let referencedVideos = Set(finished.compactMap { $0.videoURL?.standardizedFileURL.path })
            let pending = try scanPendingVideos(
                settings: settings,
                referencedVideos: referencedVideos,
                referencedMediaIDs: Set(finished.map(\.mediaID))
            )

            finishedJobs = finished
            pendingVideos = pending
            lastScanError = nil
        } catch {
            lastScanError = error.localizedDescription
        }
    }

    private func ensureLibraryDirectories(settings: SettingsStore) throws {
        try fileManager.createDirectory(at: settings.vaultURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: settings.videoRootURL, withIntermediateDirectories: true)

        for name in ["URL", "Local", "Meeting"] {
            try fileManager.createDirectory(at: settings.vaultURL.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: settings.videoRootURL.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }

        try migrateAssetDirectory(from: "from URL", to: "URL", settings: settings)
        try migrateAssetDirectory(from: "from Meeting", to: "Meeting", settings: settings)
        try updateLegacyNoteReferences(settings: settings)
    }

    private func migrateAssetDirectory(from oldName: String, to newName: String, settings: SettingsStore) throws {
        let oldURL = settings.videoRootURL.appendingPathComponent(oldName, isDirectory: true)
        guard fileManager.fileExists(atPath: oldURL.path) else { return }

        let newURL = settings.videoRootURL.appendingPathComponent(newName, isDirectory: true)
        try fileManager.createDirectory(at: newURL, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(at: oldURL, includingPropertiesForKeys: nil)
        for child in children {
            let destination = uniqueURL(newURL.appendingPathComponent(child.lastPathComponent))
            try fileManager.moveItem(at: child, to: destination)
        }
        try? fileManager.removeItem(at: oldURL)
    }

    private func updateLegacyNoteReferences(settings: SettingsStore) throws {
        for (directoryName, _) in noteDirectories {
            let directory = settings.vaultURL.appendingPathComponent(directoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let notes = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "md" }
            for note in notes {
                var content = try String(contentsOf: note, encoding: .utf8)
                let updated = content
                    .replacingOccurrences(of: "assets/from URL", with: "assets/URL")
                    .replacingOccurrences(of: "assets/from Meeting", with: "assets/Meeting")
                if updated != content {
                    content = updated
                    try content.write(to: note, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private func scanFinishedJobs(settings: SettingsStore) throws -> [FinishedJob] {
        var items: [FinishedJob] = []
        for (directoryName, source) in noteDirectories {
            let directory = settings.vaultURL.appendingPathComponent(directoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            let notes = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension.lowercased() == "md" }
            for note in notes {
            let content = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
            let title = extractYAMLValue("title", from: content) ?? note.deletingPathExtension().lastPathComponent
            let videoURL = resolveVideoPath(from: content, noteURL: note)
            let mediaID = extractYAMLValue("media_id", from: content)
            let created = try? note.resourceValues(forKeys: [.creationDateKey]).creationDate
            items.append(
                FinishedJob(
                    id: note.standardizedFileURL.path,
                    title: title,
                    source: source,
                    noteURL: note,
                    videoURL: videoURL,
                    mediaID: mediaID ?? inferredMediaID(noteURL: note, title: title, videoURL: videoURL),
                    createdAt: created
                )
            )
        }
        }

        return items.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }

    private func scanPendingVideos(
        settings: SettingsStore,
        referencedVideos: Set<String>,
        referencedMediaIDs: Set<String>
    ) throws -> [PendingVideoSummary] {
        var items: [PendingVideoSummary] = []
        let referencedMediaIDs = referencedMediaIDs.union(referencedVideos.map { mediaID(fromPath: $0) })
        for (directoryName, source) in assetDirectories {
            let directory = settings.videoRootURL.appendingPathComponent(directoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            let videos = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            for video in videos {
                let path = video.standardizedFileURL.path
                let mediaID = mediaID(from: video)
                guard !referencedVideos.contains(path), !referencedMediaIDs.contains(mediaID) else { continue }
                items.append(
                    PendingVideoSummary(
                        id: path,
                        title: video.deletingPathExtension().lastPathComponent,
                        source: source,
                        videoURL: video,
                        mediaID: mediaID
                    )
                )
            }
        }

        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var noteDirectories: [(String, VideoSourceKind)] {
        [
            ("URL", .url),
            ("Local", .local),
            ("Meeting", .zoom)
        ]
    }

    private var assetDirectories: [(String, VideoSourceKind)] {
        [
            ("URL", .url),
            ("Local", .local),
            ("Meeting", .zoom)
        ]
    }

    private func extractYAMLValue(_ key: String, from content: String) -> String? {
        let pattern = #"(?m)^\#(NSRegularExpression.escapedPattern(for: key)):\s*"?([^"\n]+)"?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)),
              match.numberOfRanges > 2,
              let range = Range(match.range(at: 2), in: content) else {
            return nil
        }
        return String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveVideoPath(from content: String, noteURL: URL) -> URL? {
        guard let value = extractYAMLValue("video_path", from: content), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        return noteURL
            .deletingLastPathComponent()
            .appendingPathComponent(value)
            .standardizedFileURL
    }

    private func inferredMediaID(noteURL: URL, title: String, videoURL: URL?) -> String {
        if let videoURL {
            return mediaID(from: videoURL)
        }
        let noteID = Self.normalizedMediaID(noteURL.deletingPathExtension().lastPathComponent)
        if !noteID.isEmpty {
            return noteID
        }
        return Self.normalizedMediaID(title)
    }

    private func mediaID(from url: URL) -> String {
        Self.normalizedMediaID(url.deletingPathExtension().lastPathComponent)
    }

    private func mediaID(fromPath path: String) -> String {
        Self.normalizedMediaID(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }

    nonisolated static func normalizedMediaID(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:\d{4}-\d{2}-\d{2}-\d{4}-)+"#, with: "", options: .regularExpression)
            .lowercased()
        result = MVSPaths.sanitizeFilename(result)
        return result
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
