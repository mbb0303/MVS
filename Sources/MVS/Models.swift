import Foundation

enum VideoSourceKind: String, CaseIterable, Codable, Identifiable {
    case url = "URL"
    case local = "Local"
    case zoom = "Zoom"
    case tencentMeeting = "TencentMeeting"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .url: "URL Video"
        case .local: "Local Video"
        case .zoom: "Zoom"
        case .tencentMeeting: "Tencent Meeting"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .url: "url-video"
        case .local: "local-video"
        case .zoom, .tencentMeeting: "meeting-recording"
        }
    }

    var libraryDirectoryName: String {
        switch self {
        case .url: "URL"
        case .local: "Local"
        case .zoom, .tencentMeeting: "Meeting"
        }
    }
}

struct FinishedJob: Identifiable, Hashable {
    let id: String
    let title: String
    let source: VideoSourceKind
    let noteURL: URL
    let videoURL: URL?
    let mediaID: String
    let createdAt: Date?
}

struct PendingVideoSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let source: VideoSourceKind
    let videoURL: URL
    let mediaID: String
}

struct URLAnalysisOptions: Codable, Hashable {
    var keepDownloadedVideo: Bool
    var preferPlatformSubtitles: Bool
    var forceASR: Bool

    static let `default` = URLAnalysisOptions(
        keepDownloadedVideo: false,
        preferPlatformSubtitles: true,
        forceASR: false
    )
}

enum JobStatus: String, Codable {
    case queued = "Queued"
    case running = "Running"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
}

enum JobStage: String, Codable, CaseIterable {
    case queued
    case metadata
    case subtitleProbe
    case download
    case archive
    case audioExtraction
    case transcription
    case summarization
    case writing
    case cleanup
    case indexing
    case completed
    case failed

    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .metadata: "Reading metadata"
        case .subtitleProbe: "Checking platform subtitles"
        case .download: "Downloading video"
        case .archive: "Archiving media"
        case .audioExtraction: "Extracting audio"
        case .transcription: "Transcribing"
        case .summarization: "Summarizing"
        case .writing: "Writing artifacts"
        case .cleanup: "Cleaning up"
        case .indexing: "Indexing"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

struct JobArtifact: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case video
        case note
        case metadata
        case transcriptSRT
        case transcriptMarkdown
        case summaryJSON
        case outline
        case mindmap
    }

    let kind: Kind
    let path: String

    var id: String { "\(kind.rawValue):\(path)" }
}

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case openAI = "openai"
    case deepSeek = "deepseek"
    case bailianQwen = "bailian-qwen"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .bailianQwen: "Alibaba Bailian Qwen"
        }
    }

    var defaultSummaryModel: String {
        switch self {
        case .openAI: "gpt-5.5"
        case .deepSeek: "deepseek-v4-flash"
        case .bailianQwen: "qwen-plus"
        }
    }
}

enum TranscriptionProvider: String, CaseIterable, Codable, Identifiable {
    case openAI = "openai"
    case bailianASR = "bailian-asr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .bailianASR: "Alibaba Bailian ASR"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-transcribe"
        case .bailianASR: "paraformer-realtime-v2"
        }
    }
}

struct AnalysisJob: Identifiable, Codable {
    let id: UUID
    let source: VideoSourceKind
    var title: String
    var status: JobStatus
    var stage: JobStage
    var progressValue: Double
    var progress: String
    var createdAt: Date
    var updatedAt: Date
    var videoURL: URL?
    var noteURL: URL?
    var errorMessage: String?
    var sourceURL: String?
    var mediaID: String?
    var artifacts: [JobArtifact]
    var canRetry: Bool

    init(source: VideoSourceKind, title: String) {
        self.id = UUID()
        self.source = source
        self.title = title
        self.status = .queued
        self.stage = .queued
        self.progressValue = 0
        self.progress = "Waiting"
        self.createdAt = Date()
        self.updatedAt = Date()
        self.sourceURL = nil
        self.mediaID = nil
        self.artifacts = []
        self.canRetry = false
    }
}

struct TranscriptSegment: Codable, Identifiable {
    let id: String
    let start: Double?
    let end: Double?
    let speaker: String?
    let text: String
}

struct TranscriptResult: Codable {
    let text: String
    let segments: [TranscriptSegment]
}

struct SummaryResult: Codable {
    let summary: String
    let timeline: [String]
    let keyDecisions: [String]
    let actionItems: [String]
    let keywords: [String]
}

struct MediaMetadataArtifact: Codable, Hashable {
    var mediaID: String
    var title: String
    var sourceURL: String?
    var platform: String
    var uploader: String?
    var duration: TimeInterval?
    var webpageURL: String?
    var description: String?
    var chapters: [String]
    var createdAt: Date
}

struct NoteWriteResult: Hashable {
    let noteURL: URL
    let artifacts: [JobArtifact]
}

struct CaptureTarget: Identifiable, Hashable {
    enum Kind: String {
        case display
        case window
    }

    let id: String
    let kind: Kind
    let name: String
}

enum MVSError: LocalizedError {
    case missingExecutable(String)
    case missingAPIKey(String)
    case invalidURL(String)
    case processFailed(String)
    case openAIResponse(String)
    case noCaptureTarget
    case recordingUnavailable

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name):
            "\(name) is not installed. Run scripts/setup-dependencies.sh first."
        case .missingAPIKey(let provider):
            "\(provider) API key is not configured."
        case .invalidURL(let value):
            "Invalid URL: \(value)"
        case .processFailed(let message):
            message
        case .openAIResponse(let message):
            "API error: \(message)"
        case .noCaptureTarget:
            "No screen or window capture target is selected."
        case .recordingUnavailable:
            "Recording requires macOS 15 or newer and Screen Recording permission."
        }
    }
}
