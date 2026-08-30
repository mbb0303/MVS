import XCTest
@testable import MVS

final class MVSPathsTests: XCTestCase {
    func testSanitizeFilenameRemovesUnsafeCharacters() {
        XCTAssertEqual(MVSPaths.sanitizeFilename("A/B:C  demo"), "A-B-C-demo")
    }

    func testRelativePathFromNoteToVideo() {
        let note = URL(fileURLWithPath: "/vault/URL/2026-04-28-demo.md")
        let video = URL(fileURLWithPath: "/vault/assets/URL/demo.mp4")
        XCTAssertEqual(MVSPaths.relativePath(from: note, to: video), "../assets/URL/demo.mp4")
    }

    func testPathContainmentUsesComponentBoundaries() {
        let root = URL(fileURLWithPath: "/tmp/mvs/assets", isDirectory: true)
        XCTAssertTrue(MVSPaths.isURL(URL(fileURLWithPath: "/tmp/mvs/assets/URL/video.mp4"), inside: root))
        XCTAssertFalse(MVSPaths.isURL(URL(fileURLWithPath: "/tmp/mvs/assets-other/video.mp4"), inside: root))
    }

    func testSourceLibraryDirectoryNames() {
        XCTAssertEqual(VideoSourceKind.url.libraryDirectoryName, "URL")
        XCTAssertEqual(VideoSourceKind.local.libraryDirectoryName, "Local")
        XCTAssertEqual(VideoSourceKind.zoom.libraryDirectoryName, "Meeting")
        XCTAssertEqual(VideoSourceKind.tencentMeeting.libraryDirectoryName, "Meeting")
        XCTAssertEqual(VideoSourceKind.screenRecording.libraryDirectoryName, "Meeting")
    }

    func testDefaultLibraryPathIsAppOwned() {
        XCTAssertTrue(MVSPaths.defaultLibraryPath.contains("/Library/Application Support/MVS/Library"))
    }

    func testLegacyObsidianDefaultPathIsMigrated() {
        XCTAssertTrue(MVSPaths.shouldMoveLegacyDefaultPath(MVSPaths.legacyObsidianVaultPath))
        XCTAssertFalse(MVSPaths.shouldMoveLegacyDefaultPath("/tmp/custom-mvs-library"))
        XCTAssertTrue(MVSPaths.isInsideLegacyObsidianStorage(MVSPaths.legacyObsidianVaultPath + "/assets"))
    }

    func testMediaIDMatchesVideoAndRepeatedTimestampNoteNames() {
        let video = "2026-04-29-0058-GPTcodeX-EP01-GPT-CodeX-_-Claude-Code-GPT-CodeX-0IKrl7nNIM0"
        let note = "2026-04-29-0946-2026-04-29-0058-GPTcodeX-EP01-GPT-CodeX-_-Claude-Code-GPT-CodeX-0IKrl7nNIM0"

        XCTAssertEqual(LibraryStore.normalizedMediaID(video), LibraryStore.normalizedMediaID(note))
    }

    func testMediaIDIgnoresUniqueFileSuffix() {
        XCTAssertEqual(
            LibraryStore.normalizedMediaID("2026-04-29-1013-Claude-Code-AI-rwueq7n_3yA.1"),
            LibraryStore.normalizedMediaID("2026-04-29-1013-Claude-Code-AI-rwueq7n_3yA")
        )
    }

    func testYTDLPProgressLineIsReadable() {
        let line = "[download]  42.1% of   18.20MiB at    1.30MiB/s ETA 00:07"
        XCTAssertEqual(
            MediaProcessor.downloadProgressMessage(from: line),
            "Downloading video · 42.1% of 18.20MiB at 1.30MiB/s ETA 00:07"
        )
    }

    func testShortSubtitleCoverageIsRejectedForLongVideo() {
        let transcript = TranscriptResult(
            text: "partial",
            segments: [
                TranscriptSegment(id: "1", start: 0, end: 780, speaker: nil, text: "partial")
            ]
        )

        XCTAssertFalse(MediaProcessor.transcriptCoversMedia(transcript, duration: 2220))
    }

    func testHighSubtitleCoverageIsAcceptedForLongVideo() {
        let transcript = TranscriptResult(
            text: "complete",
            segments: [
                TranscriptSegment(id: "1", start: 0, end: 2050, speaker: nil, text: "complete")
            ]
        )

        XCTAssertTrue(MediaProcessor.transcriptCoversMedia(transcript, duration: 2220))
    }

    func testTraditionalChineseTranscriptIsConvertedToSimplified() {
        let transcript = TranscriptResult(
            text: "這是一個測試 with English",
            segments: [
                TranscriptSegment(id: "1", start: nil, end: nil, speaker: nil, text: "下載完成後")
            ]
        )

        let converted = transcript.convertedTraditionalChineseToSimplified()

        XCTAssertEqual(converted.text, "这是一个测试 with English")
        XCTAssertEqual(converted.segments.first?.text, "下载完成后")
    }

    func testMalformedSummaryJSONCanBePartiallyRecovered() throws {
        let text = """
        {
          "summary": "这是一段总结",
          "timeline": [
            "0:00 - 开始",
            "1:00 - 设置"
          ],
          "keyDecisions": [
            "使用 DeepSeek 总结"
        """

        let result = try SummaryJSONDecoder.decode(from: text)

        XCTAssertEqual(result.summary, "这是一段总结")
        XCTAssertEqual(result.timeline, ["0:00 - 开始", "1:00 - 设置"])
        XCTAssertEqual(result.keyDecisions, ["使用 DeepSeek 总结"])
    }

    func testURLAnalysisOptionsDefaultDoesNotKeepDownloadedVideo() {
        XCTAssertFalse(URLAnalysisOptions.default.keepDownloadedVideo)
        XCTAssertTrue(URLAnalysisOptions.default.preferPlatformSubtitles)
        XCTAssertFalse(URLAnalysisOptions.default.forceASR)
    }

    func testJobArtifactIdentifiersIncludeKindAndPath() {
        let artifact = JobArtifact(kind: .summaryJSON, path: "/tmp/summary.json")
        XCTAssertEqual(artifact.id, "summaryJSON:/tmp/summary.json")
    }

    func testMeetingBundleIdentifiersAreRecognized() {
        XCTAssertTrue(RecordingController.isMeetingBundleIdentifier("com.tencent.meeting", source: .tencentMeeting))
        XCTAssertTrue(RecordingController.isMeetingBundleIdentifier("com.tencent.wemeet.helper", source: .tencentMeeting))
        XCTAssertTrue(RecordingController.isMeetingBundleIdentifier("us.zoom.xos", source: .zoom))
        XCTAssertFalse(RecordingController.isMeetingBundleIdentifier("com.apple.Safari", source: .tencentMeeting))
        XCTAssertFalse(RecordingController.isMeetingBundleIdentifier("com.tencent.meeting", source: .screenRecording))
    }


    func testShellRunnerCancellationTerminatesProcess() async throws {
        let task = Task {
            try await ShellRunner.run("/bin/sleep", ["10"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the process task to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
    }

    @MainActor
    func testLibraryProjectCanBeMovedIntoFolderAndRenamed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvs-library-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = root.appendingPathComponent("Library", isDirectory: true)
        let assets = vault.appendingPathComponent("assets", isDirectory: true)
        let locations = TestLibraryLocations(vaultURL: vault, videoRootURL: assets)
        let noteDirectory = vault.appendingPathComponent("Meeting", isDirectory: true)
        let videoDirectory = assets.appendingPathComponent("Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)

        let noteURL = noteDirectory.appendingPathComponent("demo.md")
        let videoURL = videoDirectory.appendingPathComponent("demo.mp4")
        try Data([0, 1, 2]).write(to: videoURL)
        let videoPath = MVSPaths.relativePath(from: noteURL, to: videoURL)
        let markdown = """
        ---
        source: TencentMeeting
        title: "Original Title"
        media_id: "demo-media"
        video_path: "\(videoPath)"
        ---

        # Original Title

        ## Summary
        Test content.
        """
        try markdown.write(to: noteURL, atomically: true, encoding: .utf8)
        try "# Transcript".write(
            to: noteDirectory.appendingPathComponent("demo.transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        try JSONSerialization.data(
            withJSONObject: ["title": "Original Title", "mediaID": "demo-media"],
            options: [.prettyPrinted]
        ).write(to: noteDirectory.appendingPathComponent("demo.metadata.json"))

        let store = LibraryStore()
        store.refresh(settings: locations)
        let original = try XCTUnwrap(store.finishedJobs.first)
        XCTAssertEqual(original.folderPath, "")

        let folder = try store.createFolder(
            named: "研究项目",
            parentPath: nil,
            sourceDirectoryName: "Meeting",
            settings: locations
        )
        let mapping = try store.moveProject(original, toFolderPath: folder, settings: locations)
        XCTAssertEqual(mapping.count, 3)

        let moved = try XCTUnwrap(store.finishedJobs.first)
        XCTAssertEqual(moved.folderPath, "研究项目")
        XCTAssertEqual(moved.videoURL?.standardizedFileURL, videoURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.noteURL.path))

        try store.renameProject(moved, to: "Renamed Project", settings: locations)
        let renamed = try XCTUnwrap(store.finishedJobs.first)
        XCTAssertEqual(renamed.title, "Renamed Project")
        let updatedMarkdown = try String(contentsOf: renamed.noteURL, encoding: .utf8)
        XCTAssertTrue(updatedMarkdown.contains("title: \"Renamed Project\""))
        XCTAssertTrue(updatedMarkdown.contains("# Renamed Project"))
    }

    @MainActor
    func testLibraryDeletionPreflightsEveryPathBeforeTrashing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvs-delete-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = root.appendingPathComponent("Library", isDirectory: true)
        let assets = vault.appendingPathComponent("assets", isDirectory: true)
        let noteDirectory = vault.appendingPathComponent("Local", isDirectory: true)
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        let noteURL = noteDirectory.appendingPathComponent("safe-project.md")
        let outsideVideoURL = root.appendingPathComponent("outside.mp4")
        try "# Safe Project".write(to: noteURL, atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: outsideVideoURL)

        let item = FinishedJob(
            id: noteURL.path,
            title: "Safe Project",
            source: .local,
            noteURL: noteURL,
            videoURL: outsideVideoURL,
            mediaID: "safe-project",
            createdAt: nil,
            folderPath: ""
        )
        let store = LibraryStore()
        let locations = TestLibraryLocations(vaultURL: vault, videoRootURL: assets)

        XCTAssertThrowsError(try store.deleteProject(item, settings: locations))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideVideoURL.path))
    }
}

private struct TestLibraryLocations: LibraryLocationProviding {
    let vaultURL: URL
    let videoRootURL: URL
}
