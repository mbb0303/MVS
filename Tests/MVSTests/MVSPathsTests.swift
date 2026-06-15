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

    func testSourceLibraryDirectoryNames() {
        XCTAssertEqual(VideoSourceKind.url.libraryDirectoryName, "URL")
        XCTAssertEqual(VideoSourceKind.local.libraryDirectoryName, "Local")
        XCTAssertEqual(VideoSourceKind.zoom.libraryDirectoryName, "Meeting")
        XCTAssertEqual(VideoSourceKind.tencentMeeting.libraryDirectoryName, "Meeting")
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
}
