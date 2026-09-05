import XCTest
import Darwin
@testable import MVS

final class SecurityRegressionTests: XCTestCase {
    func testFrontMatterDoesNotReadMetadataFromTranscript() {
        let header = NoteFrontMatter("---\ntitle: \"Real\"\nvideo_path: \"\"\n---\nvideo_path: /outside/private.mp4")
        XCTAssertEqual(header.value("video_path"), "")
        XCTAssertNil(header.value("source"))
    }

    func testQuotedMetadataRoundTripAndCRLF() {
        let title = "中文 \"quoted\" \\ path\nvideo_path: /outside"
        let content = NoteFrontMatter("---\r\nsource: URL\r\n---\r\nBody").setting("title", to: title)
        XCTAssertEqual(NoteFrontMatter(content).value("title"), title)
        XCTAssertEqual(NoteFrontMatter(content).body, "Body")
        XCTAssertNil(NoteFrontMatter(content).value("video_path"))
    }

    func testLongAndNonASCIIIDsCannotCollideThroughFilenameSanitization() {
        let prefix = String(repeating: "a", count: 120)
        XCTAssertNotEqual(MVSPaths.artifactStem(prefix + "1"), MVSPaths.artifactStem(prefix + "2"))
        XCTAssertNotEqual(MVSPaths.artifactStem("会议甲"), MVSPaths.artifactStem("会议乙"))
        XCTAssertEqual(MVSPaths.keyword("会议总结"), "会议总结")
    }

    func testDiagnosticRedactsTokensAndProxyCredentials() {
        let raw = "Bearer testtoken012345 sk-example123456 https://user:password@host api_key=testsecret"
        let result = DiagnosticRedactor.redact(raw)
        for secret in ["testtoken012345", "sk-example123456", "password", "testsecret"] {
            XCTAssertFalse(result.contains(secret))
        }
    }

    func testShellOutputDrainsBothPipes() async throws {
        let result = try await ShellRunner.run("/bin/sh", ["-c", "dd if=/dev/zero bs=1024 count=128 2>/dev/null; printf finished >&2"], timeout: 5)
        XCTAssertEqual(result.stdout.utf8.count, 128 * 1024)
        XCTAssertEqual(result.stderr, "finished")
    }

    func testShellPreservesUnicodeAcrossReadBoundaries() async throws {
        let result = try await ShellRunner.run("/bin/sh", ["-c", "printf '\\344\\270'; sleep 0.05; printf '\\255\\346\\226\\207'"], timeout: 5)
        XCTAssertEqual(result.stdout, "中文")
    }

    func testShellArgumentsAreNotEvaluated() async throws {
        let literal = "$(touch /tmp/should-never-exist) ; \" ' \\"
        let result = try await ShellRunner.run("/usr/bin/printf", ["%s", literal])
        XCTAssertEqual(result.stdout, literal)
    }

    func testChildThatClosesStdinDoesNotCrashApp() async throws {
        let result = try await ShellRunner.runWithEnvironment("/usr/bin/true", [], environment: [:],
            standardInput: Data(repeating: 1, count: 1024 * 1024), timeout: 5) { _ in }
        XCTAssertEqual(result.stdout, "")
    }

    func testTimeoutTerminatesTheProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await ShellRunner.run("/bin/sleep", ["20"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(3))
    }

    func testCancellationStopsGrandchildren() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let task = Task {
            try await ShellRunner.run("/bin/sh", ["-c", "sleep 20 & echo $! > \"$1\"; wait", "--", pidFile.path], timeout: 5)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let childPID = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let pid = try XCTUnwrap(childPID)
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    @MainActor
    func testMovingProjectDoesNotMovePrefixNeighborAndUpdatesVideoLink() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = TestLocations(vaultURL: root, videoRootURL: root.appendingPathComponent("assets"))
        let library = LibraryStore()
        library.refresh(settings: locations)
        let note = root.appendingPathComponent("Local/demo.md")
        let neighbor = root.appendingPathComponent("Local/demo.other.md")
        let video = root.appendingPathComponent("assets/Local/demo.mp4")
        try Data([0]).write(to: video)
        try "---\nsource: Local\nmedia_id: demo\nvideo_path: \"../assets/Local/demo.mp4\"\n---\n# Title\n![](../assets/Local/demo.mp4)"
            .write(to: note, atomically: true, encoding: .utf8)
        try "# Unrelated".write(to: neighbor, atomically: true, encoding: .utf8)
        library.refresh(settings: locations)
        let item = try XCTUnwrap(library.finishedJobs.first { $0.noteURL.standardizedFileURL.path == note.standardizedFileURL.path },
            "Scanned notes: \(library.finishedJobs.map { $0.noteURL.path }); error: \(library.lastScanError ?? "none")")
        let mapping = try library.moveProject(item, toFolderPath: "Folder/Nested", settings: locations)
        XCTAssertEqual(mapping.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))
        let moved = try XCTUnwrap(library.finishedJobs.first { $0.mediaID == "demo" })
        XCTAssertEqual(moved.videoURL?.standardizedFileURL.path, video.standardizedFileURL.path)
        XCTAssertTrue(try String(contentsOf: moved.noteURL, encoding: .utf8).contains("![](<../../../assets/Local/demo.mp4>)"))
    }

    @MainActor
    func testLibraryRefusesSymlinkArtifactAndDoesNotReadOutsideNotes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Library")
        let locations = TestLocations(vaultURL: vault, videoRootURL: vault.appendingPathComponent("assets"))
        let library = LibraryStore()
        library.refresh(settings: locations)
        let outside = root.appendingPathComponent("private.md")
        try "# Private".write(to: outside, atomically: true, encoding: .utf8)
        let link = vault.appendingPathComponent("Local/private.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        library.refresh(settings: locations)
        XCTAssertTrue(library.finishedJobs.isEmpty)
        let item = FinishedJob(id: link.path, title: "Private", source: .local, noteURL: link,
            videoURL: nil, mediaID: "private", createdAt: nil, folderPath: "")
        XCTAssertThrowsError(try library.renameProject(item, to: "Changed", settings: locations))
        XCTAssertThrowsError(try library.deleteProject(item, settings: locations))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "# Private")
    }

    func testArtifactTransactionRollsBackEarlierWritesOnFailure() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.md")
        let blocked = root.appendingPathComponent("blocked.md")
        try Data("original".utf8).write(to: first)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ArtifactTransaction.write([(first, Data("new".utf8)), (blocked, Data())], directory: root))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original")
    }

    @MainActor
    func testWriterKeepsRenamedFolderAndFullTranscriptOnRegeneration() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = TestLocations(vaultURL: root, videoRootURL: root.appendingPathComponent("assets"))
        let metadata = MediaMetadataArtifact(mediaID: "video-id", title: "Title", sourceURL: "https://example.com/video",
            platform: "url", uploader: nil, duration: 60, webpageURL: nil, description: nil, chapters: [], createdAt: Date())
        let prepared = PreparedMedia(title: "Title", mediaID: metadata.mediaID, archivedVideoURL: nil,
            audioChunks: [], duration: 60, transcript: nil, transcriptModel: nil, metadata: metadata, workingDirectoryURL: nil)
        let transcript = TranscriptResult(text: "First. Remaining content.", segments: [
            TranscriptSegment(id: "partial", start: 0, end: 1, speaker: nil, text: "First.")
        ])
        let summary = SummaryResult(summary: "Summary", timeline: [], keyDecisions: [], actionItems: [], keywords: ["会议总结"])
        let writer = ObsidianWriter()
        let first = try writer.writeNote(source: .url, title: "Title", prepared: prepared, transcript: transcript,
            summary: summary, settings: locations, transcriptModel: "test", sourceURL: metadata.sourceURL, includeLocalVideo: false)
        let library = LibraryStore()
        library.refresh(settings: locations)
        let item = try XCTUnwrap(library.finishedJobs.first)
        _ = try library.moveProject(item, toFolderPath: "Folder", settings: locations)
        let moved = try XCTUnwrap(library.finishedJobs.first)
        try library.renameProject(moved, to: "Renamed", settings: locations)
        let second = try writer.writeNote(source: .url, title: "Title", prepared: prepared, transcript: transcript,
            summary: summary, settings: locations, transcriptModel: "test", sourceURL: metadata.sourceURL, includeLocalVideo: false)
        XCTAssertNotEqual(first.noteURL.path, second.noteURL.path)
        XCTAssertEqual(second.noteURL.path, moved.noteURL.path)
        let text = try String(contentsOf: second.noteURL, encoding: .utf8)
        XCTAssertEqual(NoteFrontMatter(text).value("title"), "Renamed")
        XCTAssertTrue(text.contains("Remaining content."))
        XCTAssertTrue(text.contains("#会议总结"))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mvs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

@MainActor
struct TestLocations: NoteWritingSettings {
    let vaultURL: URL
    let videoRootURL: URL
    let summaryModel = "test-model"
}
