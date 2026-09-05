import XCTest
@testable import MVS

final class TranscriptRegressionTests: XCTestCase {
    @MainActor
    func testAudioPreparationProducesOrderedChunksInOnePass() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { throw XCTSkip("ffmpeg is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mvs-audio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        _ = try await ShellRunner.run("/opt/homebrew/bin/ffmpeg",
            ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=3.2", "-c:a", "aac", source.path])
        let chunks = try await MediaProcessor().extractAudioChunks(from: source, outputDirectory: root, segmentSeconds: 1)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("audio.wav").path))
        for chunk in chunks {
            let size = try chunk.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            XCTAssertGreaterThan(size, 44)
            XCTAssertLessThan(size, 25_000_000)
        }
    }
    func testVTTEndTimestampWithLeadingSpaceAndCueSettings() throws {
        let source = "WEBVTT\n\n00:00:00.000 --> 00:00:05.500 align:start\n2026\n\n00:00:05.500 --> 00:00:10.000\n中文 English\n"
        let result = try SubtitleParser.parse(source, format: "vtt")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].end, 5.5)
        XCTAssertEqual(result.segments[0].text, "2026")
        XCTAssertTrue(SubtitleParser.covers(result, duration: 10))
    }

    func testSRTWithWindowsLineEndings() throws {
        let result = try SubtitleParser.parse("1\r\n00:00:00,100 --> 00:00:01,200\r\nFirst\r\n\r\n2\r\n00:00:01,200 --> 00:00:02,500\r\nSecond\r\n", format: "srt")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[1].end, 2.5)
    }

    func testJSON3AndSparseSubtitles() throws {
        let result = try SubtitleParser.parse(#"{"events":[{"tStartMs":119000,"dDurationMs":1000,"segs":[{"utf8":"last second"}]}]}"#, format: "json3")
        XCTAssertEqual(result.segments.first?.start, 119)
        XCTAssertFalse(SubtitleParser.covers(result, duration: 120))
    }

    func testOversizedSingleSegmentAndIncompleteSegmentsKeepAllText() {
        let text = String(repeating: "中文English ", count: 8000)
        let result = TranscriptResult(text: text, segments: [
            TranscriptSegment(id: "one", start: 0, end: 1, speaker: nil, text: "partial")
        ])
        let chunks = TranscriptText.chunks(TranscriptText.render(result), limit: 18000)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 18000 })
        XCTAssertEqual(chunks.joined(), text)
    }

    func testSummaryPromptTextKeepsTimestamps() {
        let result = TranscriptResult(text: "Hello", segments: [
            TranscriptSegment(id: "one", start: 600, end: 601, speaker: nil, text: "Hello")
        ])
        XCTAssertEqual(TranscriptText.render(result), "[00:10:00] Hello")
    }

    func testPartialSummaryIsNotAcceptedAsComplete() {
        XCTAssertThrowsError(try SummaryJSONDecoder.decodeComplete(from: #"{"summary":"partial","timeline":[]}"#))
        XCTAssertNoThrow(try SummaryJSONDecoder.decodeComplete(from: #"{"summary":"complete","timeline":[],"keyDecisions":[],"actionItems":[],"keywords":[]}"#))
    }

    func testCheckpointRoundTripPreservesTranscriptAndURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mvs-checkpoint-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let metadata = MediaMetadataArtifact(mediaID: "youtube-demo", title: "Demo", sourceURL: "https://example.com/video",
            platform: "youtube", uploader: nil, duration: 2200, webpageURL: nil, description: nil, chapters: [], createdAt: Date())
        let checkpoint = AnalysisCheckpoint(jobID: id, source: .url, title: "Demo", metadata: metadata,
            videoURL: nil, duration: 2200, transcript: TranscriptResult(text: "Complete transcript", segments: []),
            transcriptModel: "asr", sourceURL: metadata.sourceURL, keepVideo: false)
        try checkpoint.save(vault: root)
        let restored = try XCTUnwrap(AnalysisCheckpoint.load(jobID: id, vault: root))
        XCTAssertEqual(restored.transcript.text, checkpoint.transcript.text)
        XCTAssertEqual(restored.sourceURL, metadata.sourceURL)
        XCTAssertFalse(restored.keepVideo)
    }
}
