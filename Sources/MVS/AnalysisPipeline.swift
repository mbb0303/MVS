import Foundation

@MainActor
final class AnalysisPipeline {
    private let mediaProcessor = MediaProcessor()
    private let writer = ObsidianWriter()

    func analyzeURL(_ rawURL: String, options: URLAnalysisOptions = .default, settings: SettingsStore, jobs: JobStore, library: LibraryStore? = nil) {
        var job = AnalysisJob(source: .url, title: "URL Video")
        job.sourceURL = rawURL
        job.urlOptions = options
        jobs.add(job)
        let task = Task {
            defer { jobs.detachTask(for: job.id) }
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
                            guard $0.status == .running else { return }
                            if message.localizedCaseInsensitiveContains("metadata") {
                                $0.stage = .metadata
                            } else if message.localizedCaseInsensitiveContains("subtitle") {
                                $0.stage = .subtitleProbe
                            } else if message.localizedCaseInsensitiveContains("downloading audio") {
                                $0.stage = .audioDownload
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
                Task.isCancelled ? cancelled(job.id, jobs: jobs) : fail(job.id, error: error, jobs: jobs)
                library?.refresh(settings: settings)
            }
        }
        jobs.attach(task, to: job.id)
    }

    func analyzeLocalFile(_ fileURL: URL, settings: SettingsStore, jobs: JobStore, library: LibraryStore? = nil) {
        let title = fileURL.deletingPathExtension().lastPathComponent
        var job = AnalysisJob(source: .local, title: title)
        job.originalFileURL = fileURL
        jobs.add(job)
        let task = Task {
            defer { jobs.detachTask(for: job.id) }
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
                            guard $0.status == .running else { return }
                            $0.stage = message.localizedCaseInsensitiveContains("audio") ? .audioExtraction : .archive
                            $0.progressValue = max($0.progressValue, 0.15)
                            $0.progress = message
                        }
                    }
                }
                try await finishAnalysis(jobID: job.id, source: .local, title: title, prepared: prepared, settings: settings, jobs: jobs, library: library, diarize: false)
            } catch {
                Task.isCancelled ? cancelled(job.id, jobs: jobs) : fail(job.id, error: error, jobs: jobs)
                library?.refresh(settings: settings)
            }
        }
        jobs.attach(task, to: job.id)
    }

    func analyzeRecording(_ fileURL: URL, source: VideoSourceKind, settings: SettingsStore, jobs: JobStore, library: LibraryStore? = nil) {
        let title = fileURL.deletingPathExtension().lastPathComponent
        let job = AnalysisJob(source: source, title: title)
        jobs.add(job)
        let task = Task {
            defer { jobs.detachTask(for: job.id) }
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
                            guard $0.status == .running else { return }
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
                Task.isCancelled ? cancelled(job.id, jobs: jobs) : fail(job.id, error: error, jobs: jobs)
                library?.refresh(settings: settings)
            }
        }
        jobs.attach(task, to: job.id)
    }

    func summarizeArchivedVideo(_ fileURL: URL, source: VideoSourceKind, settings: SettingsStore, jobs: JobStore, library: LibraryStore? = nil) {
        let title = fileURL.deletingPathExtension().lastPathComponent
        let job = AnalysisJob(source: source, title: title)
        jobs.add(job)
        let task = Task {
            defer { jobs.detachTask(for: job.id) }
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
                            guard $0.status == .running else { return }
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
                    diarize: source == .zoom || source == .tencentMeeting || source == .screenRecording
                        ? settings.enableDiarizationForMeetings
                        : false,
                    sourceURL: nil,
                    keepLocalVideoInNote: true,
                    removeURLDownloadAfterNote: false
                )
            } catch {
                Task.isCancelled ? cancelled(job.id, jobs: jobs) : fail(job.id, error: error, jobs: jobs)
                library?.refresh(settings: settings)
            }
        }
        jobs.attach(task, to: job.id)
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
        defer { mediaProcessor.cleanupWorkingFiles(prepared) }
        try Task.checkCancellation()
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
                let openAIKey = try await settings.loadTranscriptionAPIKey(provider: .openAI)
                let transcriptionClient = OpenAIClient(apiKey: openAIKey)
                rawTranscript = try await transcriptionClient.transcribe(chunks: prepared.audioChunks, diarize: diarize)
                transcriptModel = diarize ? "gpt-4o-transcribe-diarize" : "gpt-4o-transcribe"
            case .bailianASR:
                let bailianKey = try await settings.loadTranscriptionAPIKey(provider: .bailianASR)
                let transcriptionClient = BailianASRClient(apiKey: bailianKey, model: settings.transcriptionModel)
                let jobID = jobID
                rawTranscript = try await transcriptionClient.transcribe(chunks: prepared.audioChunks) { message in
                    Task { @MainActor in
                        jobs.update(jobID) {
                            guard $0.status == .running else { return }
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
        try AnalysisCheckpoint(jobID: jobID, source: source, title: title, metadata: prepared.metadata,
            videoURL: prepared.archivedVideoURL, duration: prepared.duration, transcript: transcript,
            transcriptModel: transcriptModel, sourceURL: sourceURL, keepVideo: keepLocalVideoInNote)
            .save(vault: settings.vaultURL)

        try Task.checkCancellation()
        jobs.update(jobID) {
            $0.stage = .summarization
            $0.progressValue = 0.7
            $0.progress = "Summarizing transcript"
        }
        let summaryKey = try await settings.loadAPIKey(provider: settings.summaryProvider)
        let summaryClient = SummaryClient(apiKey: summaryKey)
        let summary = try await summaryClient.summarize(transcript: transcript, title: title, source: source, settings: settings)

        try Task.checkCancellation()
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

        try Task.checkCancellation()
        jobs.update(jobID) {
            $0.status = .completed
            $0.stage = .completed
            $0.progressValue = 1.0
            $0.progress = "Done"
            $0.noteURL = written.noteURL
            $0.artifacts = written.artifacts
            $0.canRetry = false
            if removeURLDownloadAfterNote {
                $0.videoURL = nil
            }
        }
        let checkpoint = AnalysisCheckpoint.url(jobID: jobID, vault: settings.vaultURL)
        if MVSPaths.isURL(checkpoint, inside: settings.vaultURL) {
            try? FileManager.default.removeItem(at: checkpoint)
        }
        library?.refresh(settings: settings)
    }

    func retry(_ job: AnalysisJob, settings: SettingsStore, jobs: JobStore, library: LibraryStore) {
        guard !jobs.isTaskRunning(job.id) else { return }
        do {
            if let checkpoint = try AnalysisCheckpoint.load(jobID: job.id, vault: settings.vaultURL) {
                if let video = checkpoint.videoURL, !MVSPaths.isURL(video, inside: settings.videoRootURL) {
                    throw MVSError.processFailed("Checkpoint media is outside the configured library.")
                }
                jobs.update(job.id) {
                    $0.status = .running
                    $0.stage = .summarization
                    $0.canRetry = false
                    $0.errorMessage = nil
                    $0.progress = "Resuming from saved transcript"
                }
                let task = Task {
                    defer { jobs.detachTask(for: job.id) }
                    do {
                        let prepared = PreparedMedia(title: checkpoint.title, mediaID: checkpoint.metadata.mediaID,
                            archivedVideoURL: checkpoint.videoURL, audioChunks: [], duration: checkpoint.duration,
                            transcript: checkpoint.transcript, transcriptModel: checkpoint.transcriptModel,
                            metadata: checkpoint.metadata, workingDirectoryURL: nil)
                        try await finishAnalysis(jobID: job.id, source: checkpoint.source, title: checkpoint.title,
                            prepared: prepared, settings: settings, jobs: jobs, library: library, diarize: false,
                            sourceURL: checkpoint.sourceURL, keepLocalVideoInNote: checkpoint.keepVideo,
                            removeURLDownloadAfterNote: checkpoint.source == .url && !checkpoint.keepVideo)
                    } catch {
                        Task.isCancelled ? cancelled(job.id, jobs: jobs) : fail(job.id, error: error, jobs: jobs)
                    }
                }
                jobs.attach(task, to: job.id)
                return
            }
            if job.source == .url, let url = job.sourceURL {
                jobs.remove(job.id)
                analyzeURL(url, options: job.urlOptions ?? .default, settings: settings, jobs: jobs, library: library)
            } else if let video = job.videoURL {
                jobs.remove(job.id)
                summarizeArchivedVideo(video, source: job.source, settings: settings, jobs: jobs, library: library)
            } else if let original = job.originalFileURL {
                jobs.remove(job.id)
                analyzeLocalFile(original, settings: settings, jobs: jobs, library: library)
            } else {
                throw MVSError.processFailed("The original source is unavailable. Import the media again.")
            }
        } catch {
            fail(job.id, error: error, jobs: jobs)
        }
    }

    private func fail(_ id: AnalysisJob.ID, error: Error, jobs: JobStore) {
        jobs.update(id) {
            $0.status = .failed
            $0.stage = .failed
            $0.progressValue = 1.0
            $0.progress = "Failed"
            $0.errorMessage = DiagnosticRedactor.redact(error.localizedDescription)
            $0.canRetry = true
        }
    }

    private func cancelled(_ id: AnalysisJob.ID, jobs: JobStore) {
        jobs.update(id) {
            $0.status = .cancelled
            $0.stage = .failed
            $0.progressValue = 1.0
            $0.progress = "Cancelled"
            $0.errorMessage = nil
            $0.canRetry = true
        }
    }
}
