import Foundation

@MainActor
final class AnalysisPipeline {
    private let mediaProcessor = MediaProcessor()
    private let writer = ObsidianWriter()

    func analyzeURL(_ rawURL: String, options: URLAnalysisOptions = .default, settings: SettingsStore, jobs: JobStore, library: LibraryStore? = nil) {
        var job = AnalysisJob(source: .url, title: "URL Video")
        job.sourceURL = rawURL
        jobs.add(job)
        Task {
            do {
                jobs.update(job.id) {
                    $0.status = .running
                    $0.stage = .metadata
                    $0.progressValue = 0.05
                    $0.progress = "Reading metadata"
                }
                let jobID = job.id
                let prepared = try await mediaProcessor.prepareURLVideo(rawURL, options: options, settings: settings) { message in
                    Task { @MainActor in
                        jobs.update(jobID) {
                            if message.localizedCaseInsensitiveContains("metadata") {
                                $0.stage = .metadata
                            } else if message.localizedCaseInsensitiveContains("subtitle") {
                                $0.stage = .subtitleProbe
                            } else if message.localizedCaseInsensitiveContains("audio") {
                                $0.stage = .audioExtraction
                            } else {
                                $0.stage = .download
                            }
                            $0.progressValue = max($0.progressValue, 0.1)
                            $0.progress = message
                        }
                    }
                }
                job.title = prepared.title
                try await finishAnalysis(
                    jobID: job.id,
                    source: .url,
                    title: prepared.title,
                    prepared: prepared,
                    settings: settings,
                    jobs: jobs,
                    library: library,
                    diarize: false,
                    sourceURL: rawURL,
                    keepLocalVideoInNote: options.keepDownloadedVideo,
                    removeURLDownloadAfterNote: !options.keepDownloadedVideo
                )
            } catch {
                fail(job.id, error: error, jobs: jobs)
                library?.refresh(settings: settings)
            }
        }
    }

    func analyzeLocalFile(_ fileURL: URL, settings: SettingsStore, jobs: JobStore, library: LibraryStore? = nil) {
        let title = fileURL.deletingPathExtension().lastPathComponent
        let job = AnalysisJob(source: .local, title: title)
        jobs.add(job)
        Task {
            do {
                jobs.update(job.id) {
                    $0.status = .running
                    $0.stage = .archive
                    $0.progressValue = 0.1
                    $0.progress = "Archiving local video"
                }
                let jobID = job.id
                let prepared = try await mediaProcessor.prepareExistingVideo(fileURL, source: .local, title: title, settings: settings) { message in
                    Task { @MainActor in
                        jobs.update(jobID) {
                            $0.stage = message.localizedCaseInsensitiveContains("audio") ? .audioExtraction : .archive
                            $0.progressValue = max($0.progressValue, 0.15)
                            $0.progress = message
                        }
                    }
                }
                try await finishAnalysis(jobID: job.id, source: .local, title: title, prepared: prepared, settings: settings, jobs: jobs, library: library, diarize: false)
            } catch {
                fail(job.id, error: error, jobs: jobs)
                library?.refresh(settings: settings)
            }
        }
    }

    func analyzeRecording(_ fileURL: URL, source: VideoSourceKind, settings: SettingsStore, jobs: JobStore, library: LibraryStore? = nil) {
        let title = fileURL.deletingPathExtension().lastPathComponent
        let job = AnalysisJob(source: source, title: title)
        jobs.add(job)
        Task {
            do {
                jobs.update(job.id) {
                    $0.status = .running
                    $0.stage = .archive
                    $0.progressValue = 0.1
                    $0.progress = "Preparing recording"
                }
                let jobID = job.id
                let prepared = try await mediaProcessor.prepareExistingVideo(fileURL, source: source, title: title, settings: settings, moveInsteadOfCopy: false) { message in
                    Task { @MainActor in
                        jobs.update(jobID) {
                            $0.stage = message.localizedCaseInsensitiveContains("audio") ? .audioExtraction : .archive
                            $0.progressValue = max($0.progressValue, 0.15)
                            $0.progress = message
                        }
                    }
                }
                try await finishAnalysis(
                    jobID: job.id,
                    source: source,
                    title: title,
                    prepared: prepared,
                    settings: settings,
                    jobs: jobs,
                    library: library,
                    diarize: settings.enableDiarizationForMeetings,
                    sourceURL: nil,
                    keepLocalVideoInNote: true,
                    removeURLDownloadAfterNote: false
                )
            } catch {
                fail(job.id, error: error, jobs: jobs)
                library?.refresh(settings: settings)
            }
        }
    }

    func summarizeArchivedVideo(_ fileURL: URL, source: VideoSourceKind, settings: SettingsStore, jobs: JobStore, library: LibraryStore? = nil) {
        let title = fileURL.deletingPathExtension().lastPathComponent
        let job = AnalysisJob(source: source, title: title)
        jobs.add(job)
        Task {
            do {
                jobs.update(job.id) {
                    $0.status = .running
                    $0.stage = .archive
                    $0.progressValue = 0.1
                    $0.progress = "Preparing archived video"
                    $0.videoURL = fileURL
                }
                let jobID = job.id
                let prepared = try await mediaProcessor.prepareExistingVideo(fileURL, source: source, title: title, settings: settings, moveInsteadOfCopy: false) { message in
                    Task { @MainActor in
                        jobs.update(jobID) {
                            $0.stage = message.localizedCaseInsensitiveContains("audio") ? .audioExtraction : .archive
                            $0.progressValue = max($0.progressValue, 0.15)
                            $0.progress = message
                        }
                    }
                }
                try await finishAnalysis(
                    jobID: job.id,
                    source: source,
                    title: title,
                    prepared: prepared,
                    settings: settings,
                    jobs: jobs,
                    library: library,
                    diarize: source == .zoom || source == .tencentMeeting ? settings.enableDiarizationForMeetings : false,
                    sourceURL: nil,
                    keepLocalVideoInNote: true,
                    removeURLDownloadAfterNote: false
                )
            } catch {
                fail(job.id, error: error, jobs: jobs)
                library?.refresh(settings: settings)
            }
        }
    }

    private func finishAnalysis(
        jobID: AnalysisJob.ID,
        source: VideoSourceKind,
        title: String,
        prepared: PreparedMedia,
        settings: SettingsStore,
        jobs: JobStore,
        library: LibraryStore?,
        diarize: Bool,
        sourceURL: String? = nil,
        keepLocalVideoInNote: Bool = true,
        removeURLDownloadAfterNote: Bool = false
    ) async throws {
        jobs.update(jobID) {
            $0.title = title
            $0.videoURL = prepared.archivedVideoURL
            $0.mediaID = prepared.mediaID
            $0.stage = prepared.transcript == nil ? .transcription : .subtitleProbe
            $0.progressValue = 0.35
            $0.progress = prepared.transcript == nil ? "Transcribing audio" : "Using downloaded subtitles"
        }
        let rawTranscript: TranscriptResult
        let transcriptModel: String
        if let preparedTranscript = prepared.transcript {
            rawTranscript = preparedTranscript
            transcriptModel = prepared.transcriptModel ?? "subtitles"
        } else {
            switch settings.transcriptionProvider {
            case .openAI:
                let openAIKey = try settings.loadTranscriptionAPIKey(provider: .openAI)
                let transcriptionClient = OpenAIClient(apiKey: openAIKey)
                rawTranscript = try await transcriptionClient.transcribe(chunks: prepared.audioChunks, diarize: diarize)
                transcriptModel = diarize ? "gpt-4o-transcribe-diarize" : "gpt-4o-transcribe"
            case .bailianASR:
                let bailianKey = try settings.loadTranscriptionAPIKey(provider: .bailianASR)
                let transcriptionClient = BailianASRClient(apiKey: bailianKey, model: settings.transcriptionModel)
                let jobID = jobID
                rawTranscript = try await transcriptionClient.transcribe(chunks: prepared.audioChunks) { message in
                    Task { @MainActor in
                        jobs.update(jobID) {
                            $0.stage = .transcription
                            $0.progressValue = max($0.progressValue, 0.35)
                            $0.progress = message
                        }
                    }
                }
                transcriptModel = settings.transcriptionModel
            }
        }
        let transcript = rawTranscript.convertedTraditionalChineseToSimplified()

        jobs.update(jobID) {
            $0.stage = .summarization
            $0.progressValue = 0.7
            $0.progress = "Summarizing transcript"
        }
        let summaryKey = try settings.loadAPIKey(provider: settings.summaryProvider)
        let summaryClient = SummaryClient(apiKey: summaryKey)
        let summary = try await summaryClient.summarize(transcript: transcript, title: title, source: source, settings: settings)

        jobs.update(jobID) {
            $0.stage = .writing
            $0.progressValue = 0.88
            $0.progress = "Writing MVS note"
        }
        let written = try writer.writeNote(
            source: source,
            title: title,
            prepared: prepared,
            transcript: transcript,
            summary: summary,
            settings: settings,
            transcriptModel: transcriptModel,
            sourceURL: sourceURL,
            includeLocalVideo: keepLocalVideoInNote
        )

        if removeURLDownloadAfterNote {
            jobs.update(jobID) {
                $0.stage = .cleanup
                $0.progressValue = 0.95
                $0.progress = "Removing downloaded video"
            }
            try mediaProcessor.removeGeneratedURLAssets(prepared)
        }

        jobs.update(jobID) {
            $0.status = .completed
            $0.stage = .completed
            $0.progressValue = 1.0
            $0.progress = "Done"
            $0.noteURL = written.noteURL
            $0.artifacts = written.artifacts
            if removeURLDownloadAfterNote {
                $0.videoURL = nil
            }
        }
        library?.refresh(settings: settings)
    }

    private func fail(_ id: AnalysisJob.ID, error: Error, jobs: JobStore) {
        jobs.update(id) {
            $0.status = .failed
            $0.stage = .failed
            $0.progressValue = 1.0
            $0.progress = "Failed"
            $0.errorMessage = error.localizedDescription
            $0.canRetry = true
        }
    }
}
