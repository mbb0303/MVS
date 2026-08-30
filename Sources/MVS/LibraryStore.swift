import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var finishedJobs: [FinishedJob] = []
    @Published private(set) var pendingVideos: [PendingVideoSummary] = []
    @Published private(set) var folders: [LibraryFolder] = []
    @Published private(set) var lastScanError: String?

    private let fileManager = FileManager.default
    private let videoExtensions = Set(["mp4", "mov", "mkv", "webm"])
    private let sourceDirectoryNames = ["URL", "Local", "Meeting"]

    func refresh(settings: any LibraryLocationProviding) {
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
            folders = try scanFolders(settings: settings)
            lastScanError = nil
        } catch {
            lastScanError = error.localizedDescription
        }
    }

    func folderPaths(for source: VideoSourceKind) -> [String] {
        folders
            .filter { $0.sourceDirectoryName == source.libraryDirectoryName }
            .map(\.path)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @discardableResult
    func createFolder(
        named rawName: String,
        parentPath: String?,
        sourceDirectoryName: String,
        settings: any LibraryLocationProviding
    ) throws -> String {
        guard sourceDirectoryNames.contains(sourceDirectoryName) else {
            throw MVSError.processFailed("Unsupported library source folder.")
        }
        let name = try normalizedFolderComponent(rawName)
        let parent = normalizedRelativeFolderPath(parentPath ?? "")
        let relativePath = parent.isEmpty ? name : "\(parent)/\(name)"
        let root = settings.vaultURL.appendingPathComponent(sourceDirectoryName, isDirectory: true)
        let destination = root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
        guard MVSPaths.isURL(destination, inside: root) else {
            throw MVSError.processFailed("Folder must remain inside the MVS library.")
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MVSError.processFailed("A folder with this name already exists.")
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        refresh(settings: settings)
        return relativePath
    }

    func renameProject(_ item: FinishedJob, to rawTitle: String, settings: any LibraryLocationProviding) throws {
        let title = rawTitle
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MVSError.processFailed("Project title cannot be empty.")
        }

        var markdown = try String(contentsOf: item.noteURL, encoding: .utf8)
        markdown = replaceYAMLValue("title", value: title, in: markdown)
        markdown = replaceFirstHeading(with: title, in: markdown)
        try markdown.write(to: item.noteURL, atomically: true, encoding: .utf8)

        let metadataURL = item.noteURL
            .deletingPathExtension()
            .appendingPathExtension("metadata.json")
        if let data = try? Data(contentsOf: metadataURL),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object["title"] = title
            let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try updated.write(to: metadataURL, options: .atomic)
        }
        refresh(settings: settings)
    }

    @discardableResult
    func moveProject(
        _ item: FinishedJob,
        toFolderPath rawFolderPath: String?,
        settings: any LibraryLocationProviding
    ) throws -> [String: String] {
        let root = sourceRoot(for: item.source, settings: settings)
        let folderPath = normalizedRelativeFolderPath(rawFolderPath ?? "")
        let destinationDirectory = folderPath.isEmpty
            ? root
            : root.appendingPathComponent(folderPath, isDirectory: true).standardizedFileURL
        guard MVSPaths.isURL(destinationDirectory, inside: root) else {
            throw MVSError.processFailed("Destination must remain inside the source library.")
        }
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let currentDirectory = item.noteURL.deletingLastPathComponent().standardizedFileURL
        guard currentDirectory.path != destinationDirectory.path else { return [:] }
        let files = try projectFiles(for: item)
        let destinations = files.map { destinationDirectory.appendingPathComponent($0.lastPathComponent) }
        guard !destinations.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw MVSError.processFailed("The destination folder already contains this project.")
        }

        var moved: [(source: URL, destination: URL)] = []
        do {
            for (source, destination) in zip(files, destinations) {
                try fileManager.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
        } catch {
            for pair in moved.reversed() where fileManager.fileExists(atPath: pair.destination.path) {
                try? fileManager.moveItem(at: pair.destination, to: pair.source)
            }
            throw error
        }

        let mapping = Dictionary(uniqueKeysWithValues: moved.map {
            ($0.source.standardizedFileURL.path, $0.destination.standardizedFileURL.path)
        })
        if let newNotePath = mapping[item.noteURL.standardizedFileURL.path] {
            let newNoteURL = URL(fileURLWithPath: newNotePath)
            try updateVideoPath(in: newNoteURL, videoURL: item.videoURL)
        }
        removeEmptyParentFolders(startingAt: currentDirectory, stoppingAt: root)
        refresh(settings: settings)
        return mapping
    }

    func deleteProject(_ item: FinishedJob, settings: any LibraryLocationProviding) throws {
        let root = sourceRoot(for: item.source, settings: settings)
        let currentDirectory = item.noteURL.deletingLastPathComponent()
        var targets = try projectFiles(for: item)
        if let videoURL = item.videoURL { targets.append(videoURL) }
        try trashSafely(targets, settings: settings)
        removeEmptyParentFolders(startingAt: currentDirectory, stoppingAt: root)
        refresh(settings: settings)
    }

    func deletePendingVideo(_ item: PendingVideoSummary, settings: any LibraryLocationProviding) throws {
        try trashSafely([item.videoURL], settings: settings)
        refresh(settings: settings)
    }

    func deleteArtifacts(for job: AnalysisJob, settings: any LibraryLocationProviding) throws {
        var targets = job.artifacts.map { URL(fileURLWithPath: $0.path) }
        if let noteURL = job.noteURL { targets.append(noteURL) }
        if let videoURL = job.videoURL { targets.append(videoURL) }
        let unique = Dictionary(grouping: targets, by: { $0.standardizedFileURL.path })
            .compactMap { $0.value.first }
        try trashSafely(unique, settings: settings)
        refresh(settings: settings)
    }

    func eraseAllGeneratedData(settings: any LibraryLocationProviding) throws {
        let targets = sourceDirectoryNames.flatMap { name in
            [
                settings.vaultURL.appendingPathComponent(name, isDirectory: true),
                settings.videoRootURL.appendingPathComponent(name, isDirectory: true),
            ]
        }
        try trashSafely(targets, settings: settings)
        try ensureLibraryDirectories(settings: settings)
        finishedJobs = []
        pendingVideos = []
        folders = []
        lastScanError = nil
    }

    private func ensureLibraryDirectories(settings: any LibraryLocationProviding) throws {
        try fileManager.createDirectory(at: settings.vaultURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: settings.videoRootURL, withIntermediateDirectories: true)
        for name in sourceDirectoryNames {
            try fileManager.createDirectory(
                at: settings.vaultURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: settings.videoRootURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try migrateAssetDirectory(from: "from URL", to: "URL", settings: settings)
        try migrateAssetDirectory(from: "from Meeting", to: "Meeting", settings: settings)
        try updateLegacyNoteReferences(settings: settings)
    }

    private func migrateAssetDirectory(from oldName: String, to newName: String, settings: any LibraryLocationProviding) throws {
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

    private func updateLegacyNoteReferences(settings: any LibraryLocationProviding) throws {
        for directoryName in sourceDirectoryNames {
            let directory = settings.vaultURL.appendingPathComponent(directoryName, isDirectory: true)
            for note in recursiveFiles(in: directory) where note.pathExtension.lowercased() == "md" {
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

    private func scanFinishedJobs(settings: any LibraryLocationProviding) throws -> [FinishedJob] {
        var items: [FinishedJob] = []
        for (directoryName, source) in noteDirectories {
            let root = settings.vaultURL.appendingPathComponent(directoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            for note in recursiveFiles(in: root).filter({ isPrimaryNoteURL($0) }) {
                let content = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
                let title = extractYAMLValue("title", from: content)
                    ?? note.deletingPathExtension().lastPathComponent
                let storedSource = extractYAMLValue("source", from: content)
                    .flatMap(VideoSourceKind.init(rawValue:))
                    ?? source
                let videoURL = resolveVideoPath(from: content, noteURL: note)
                let mediaID = extractYAMLValue("media_id", from: content)
                let created = try? note.resourceValues(forKeys: [.creationDateKey]).creationDate
                items.append(FinishedJob(
                    id: note.standardizedFileURL.path,
                    title: title,
                    source: storedSource,
                    noteURL: note,
                    videoURL: videoURL,
                    mediaID: mediaID ?? inferredMediaID(noteURL: note, title: title, videoURL: videoURL),
                    createdAt: created,
                    folderPath: relativeFolderPath(from: root, to: note.deletingLastPathComponent())
                ))
            }
        }
        let sorted = items.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        var seen = Set<String>()
        return sorted.filter { item in
            guard !seen.contains(item.mediaID) else { return false }
            seen.insert(item.mediaID)
            return true
        }
    }

    private func scanPendingVideos(
        settings: any LibraryLocationProviding,
        referencedVideos: Set<String>,
        referencedMediaIDs: Set<String>
    ) throws -> [PendingVideoSummary] {
        var items: [PendingVideoSummary] = []
        let referencedMediaIDs = referencedMediaIDs.union(referencedVideos.map { mediaID(fromPath: $0) })
        for (directoryName, source) in assetDirectories {
            let directory = settings.videoRootURL.appendingPathComponent(directoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            for video in recursiveFiles(in: directory).filter({ videoExtensions.contains($0.pathExtension.lowercased()) }) {
                let path = video.standardizedFileURL.path
                let mediaID = mediaID(from: video)
                let inferredSource: VideoSourceKind = directoryName == "Meeting"
                    && video.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains("screen-recording")
                    ? .screenRecording
                    : source
                guard !referencedVideos.contains(path), !referencedMediaIDs.contains(mediaID) else { continue }
                items.append(PendingVideoSummary(
                    id: path,
                    title: video.deletingPathExtension().lastPathComponent,
                    source: inferredSource,
                    videoURL: video,
                    mediaID: mediaID
                ))
            }
        }
        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func scanFolders(settings: any LibraryLocationProviding) throws -> [LibraryFolder] {
        var results: [LibraryFolder] = []
        for sourceDirectoryName in sourceDirectoryNames {
            let root = settings.vaultURL.appendingPathComponent(sourceDirectoryName, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
                guard isDirectory else { continue }
                results.append(LibraryFolder(
                    sourceDirectoryName: sourceDirectoryName,
                    path: relativeFolderPath(from: root, to: url)
                ))
            }
        }
        return results.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private var noteDirectories: [(String, VideoSourceKind)] {
        [("URL", .url), ("Local", .local), ("Meeting", .zoom)]
    }

    private var assetDirectories: [(String, VideoSourceKind)] {
        [("URL", .url), ("Local", .local), ("Meeting", .zoom)]
    }

    private func sourceRoot(for source: VideoSourceKind, settings: any LibraryLocationProviding) -> URL {
        settings.vaultURL.appendingPathComponent(source.libraryDirectoryName, isDirectory: true)
    }

    private func projectFiles(for item: FinishedJob) throws -> [URL] {
        let directory = item.noteURL.deletingLastPathComponent()
        let stem = item.noteURL.deletingPathExtension().lastPathComponent
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let name = url.lastPathComponent
            return name == "\(stem).md" || name.hasPrefix("\(stem).")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func trashSafely(_ urls: [URL], settings: any LibraryLocationProviding) throws {
        var seen = Set<String>()
        let targets = urls.compactMap { url -> URL? in
            let standardized = url.standardizedFileURL
            let path = standardized.path
            guard seen.insert(path).inserted, fileManager.fileExists(atPath: path) else { return nil }
            return standardized
        }

        for target in targets {
            let path = target.path
            guard MVSPaths.isURL(target, inside: settings.vaultURL)
                    || MVSPaths.isURL(target, inside: settings.videoRootURL) else {
                throw MVSError.processFailed("Refusing to delete a file outside the MVS library: \(path)")
            }
        }

        for target in targets {
            var trashedURL: NSURL?
            try fileManager.trashItem(at: target, resultingItemURL: &trashedURL)
        }
    }

    private func recursiveFiles(in root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        return files
    }

    private func extractYAMLValue(_ key: String, from content: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?m)^\(escapedKey):\\s*\"?([^\"\\n]+)\"?\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: content,
                range: NSRange(content.startIndex..<content.endIndex, in: content)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replaceYAMLValue(_ key: String, value: String, in content: String) -> String {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let replacement = "\(key): \"\(escapedValue)\""
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?m)^\(escapedKey):\\s*.*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        if regex.firstMatch(in: content, range: range) != nil {
            return regex.stringByReplacingMatches(
                in: content,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }
        guard let opening = content.range(of: "---\n") else { return content }
        return content.replacingCharacters(in: opening, with: "---\n\(replacement)\n")
    }

    private func replaceFirstHeading(with title: String, in content: String) -> String {
        let replacement = "# \(title)"
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^# .*$"#) else { return content }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range) else { return content }
        return regex.stringByReplacingMatches(
            in: content,
            range: match.range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    private func updateVideoPath(in noteURL: URL, videoURL: URL?) throws {
        guard let videoURL else { return }
        var content = try String(contentsOf: noteURL, encoding: .utf8)
        content = replaceYAMLValue(
            "video_path",
            value: MVSPaths.relativePath(from: noteURL, to: videoURL),
            in: content
        )
        try content.write(to: noteURL, atomically: true, encoding: .utf8)
    }

    private func isPrimaryNoteURL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "md" else { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return !name.hasSuffix(".transcript")
            && !name.hasSuffix(".outline")
            && !name.hasSuffix(".mindmap")
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
        if let videoURL { return mediaID(from: videoURL) }
        let noteID = Self.normalizedMediaID(noteURL.deletingPathExtension().lastPathComponent)
        return noteID.isEmpty ? Self.normalizedMediaID(title) : noteID
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

    private func normalizedFolderComponent(_ rawName: String) throws -> String {
        let value = rawName
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix(".") else {
            throw MVSError.processFailed("Folder name is not valid.")
        }
        return String(value.prefix(80))
    }

    private func normalizedRelativeFolderPath(_ rawPath: String) -> String {
        rawPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    private func relativeFolderPath(from root: URL, to directory: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = directory.standardizedFileURL.pathComponents
        guard targetComponents.starts(with: rootComponents) else { return "" }
        return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func removeEmptyParentFolders(startingAt directory: URL, stoppingAt root: URL) {
        var candidate = directory.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while candidate.path != rootPath, MVSPaths.isURL(candidate, inside: root) {
            guard let children = try? fileManager.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil),
                  children.isEmpty else { break }
            try? fileManager.removeItem(at: candidate)
            candidate.deleteLastPathComponent()
        }
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
