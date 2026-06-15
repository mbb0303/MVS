import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var jobs: JobStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var recorder: RecordingController
    @Environment(\.openSettings) private var openSettings
    @State private var urlText = ""
    @State private var keepURLDownload = false
    @State private var preferURLSubtitles = true
    @State private var forceURLASR = false
    @State private var pipeline = AnalysisPipeline()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                Text("MVS")
                    .font(.system(size: 28, weight: .semibold))
                Text("Video and meeting summaries stored in the MVS library")
                    .foregroundStyle(.secondary)

                AppLibrarySummaryView()

                Button {
                    openSettings()
                } label: {
                    Label("API Settings", systemImage: "key")
                }
                .buttonStyle(.bordered)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Analyze URL")
                        .font(.headline)
                    HStack {
                        TextField("Paste public video URL", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            pipeline.analyzeURL(
                                urlText,
                                options: URLAnalysisOptions(
                                    keepDownloadedVideo: keepURLDownload,
                                    preferPlatformSubtitles: preferURLSubtitles,
                                    forceASR: forceURLASR
                                ),
                                settings: settings,
                                jobs: jobs,
                                library: library
                            )
                            urlText = ""
                        } label: {
                            Label("Analyze", systemImage: "link")
                        }
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Toggle("Keep downloaded video", isOn: $keepURLDownload)
                        .toggleStyle(.checkbox)
                    Toggle("Prefer platform subtitles", isOn: $preferURLSubtitles)
                        .toggleStyle(.checkbox)
                    Toggle("Force ASR", isOn: $forceURLASR)
                        .toggleStyle(.checkbox)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Import Video")
                        .font(.headline)
                    Button {
                        importVideo()
                    } label: {
                        Label("Choose Video File", systemImage: "film")
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Record Meeting")
                        .font(.headline)
                    Picker("Source", selection: $recorder.meetingSource) {
                        Text("Zoom").tag(VideoSourceKind.zoom)
                        Text("Tencent Meeting").tag(VideoSourceKind.tencentMeeting)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Picker("Target", selection: Binding(
                            get: { recorder.selectedTargetID ?? "" },
                            set: { recorder.selectedTargetID = $0 }
                        )) {
                            ForEach(recorder.targets) { target in
                                Text(target.name).tag(target.id)
                            }
                        }
                        .frame(minWidth: 360)

                        Button {
                            Task { await recorder.refreshTargets() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }

                    HStack {
                        Button {
                            Task { await recorder.startRecording(settings: settings) }
                        } label: {
                            Label("Start", systemImage: "record.circle")
                        }
                        .disabled(recorder.isRecording)

                        Button {
                            Task {
                                if let recording = await recorder.stopRecording() {
                                    pipeline.analyzeRecording(recording, source: recorder.meetingSource, settings: settings, jobs: jobs, library: library)
                                }
                            }
                        } label: {
                            Label("Stop and Analyze", systemImage: "stop.circle")
                        }
                        .disabled(!recorder.isRecording)
                    }
                    Text(recorder.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(24)
            .navigationSplitViewColumnWidth(min: 420, ideal: 460)
        } detail: {
            JobListView()
        }
        .task {
            jobs.configure(settings: settings)
            preferURLSubtitles = settings.preferPlatformSubtitles
            forceURLASR = settings.forceASRForURL
            library.refresh(settings: settings)
        }
        .onChange(of: settings.vaultPath) {
            jobs.configure(settings: settings)
            library.refresh(settings: settings)
        }
        .onChange(of: settings.videoRootPath) {
            library.refresh(settings: settings)
        }
    }

    private func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            pipeline.analyzeLocalFile(url, settings: settings, jobs: jobs, library: library)
        }
    }
}

struct JobListView: View {
    @EnvironmentObject private var jobs: JobStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore
    @State private var pipeline = AnalysisPipeline()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Processing Jobs")
                        .font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button {
                        library.refresh(settings: settings)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                if jobs.jobs.isEmpty && library.pendingVideos.isEmpty {
                    ContentUnavailableView(
                        "No jobs yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Analyze a URL, import a video, or record a meeting.")
                    )
                } else {
                    List {
                        if !library.pendingVideos.isEmpty {
                            Section("Videos without notes") {
                                ForEach(library.pendingVideos) { pending in
                                    PendingVideoRow(pending: pending) {
                                        pipeline.summarizeArchivedVideo(
                                            pending.videoURL,
                                            source: pending.source,
                                            settings: settings,
                                            jobs: jobs,
                                            library: library
                                        )
                                    }
                                }
                            }
                        }

                        if !jobs.jobs.isEmpty {
                            Section("Current jobs") {
                                ForEach(jobs.jobs) { job in
                                    JobRow(job: job) {
                                        retry(job)
                                    }
                                }
                            }
                        }
                    }
                }

                if let error = library.lastScanError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(minWidth: 430)

            Divider()

            FinishedJobsView()
                .frame(minWidth: 320, idealWidth: 360)
        }
    }

    private func retry(_ job: AnalysisJob) {
        if job.source == .url, let sourceURL = job.sourceURL {
            pipeline.analyzeURL(
                sourceURL,
                options: URLAnalysisOptions(
                    keepDownloadedVideo: false,
                    preferPlatformSubtitles: settings.preferPlatformSubtitles,
                    forceASR: settings.forceASRForURL
                ),
                settings: settings,
                jobs: jobs,
                library: library
            )
            return
        }
        if let videoURL = job.videoURL {
            pipeline.summarizeArchivedVideo(
                videoURL,
                source: job.source,
                settings: settings,
                jobs: jobs,
                library: library
            )
        }
    }
}

struct PendingVideoRow: View {
    let pending: PendingVideoSummary
    let summarize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(pending.title) + notes not generated")
                .font(.headline)
            Text(pending.source.libraryDirectoryName)
                .foregroundStyle(.secondary)
            HStack {
                Button("Summarize", action: summarize)
                Button("Open Video") { NSWorkspace.shared.open(pending.videoURL) }
            }
        }
        .padding(.vertical, 8)
    }
}

struct JobRow: View {
    @EnvironmentObject private var jobs: JobStore
    let job: AnalysisJob
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.title)
                    .font(.headline)
                Spacer()
                Text(job.status.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(job.status).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text("\(job.source.displayName) · \(job.progress)")
                .foregroundStyle(.secondary)
            if job.status == .running {
                ProgressView(value: job.progressValue)
                    .controlSize(.small)
                Text(job.stage.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = job.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
            HStack {
                if let video = job.videoURL {
                    Button("Open Video") { NSWorkspace.shared.open(video) }
                }
                if let note = job.noteURL {
                    Button("Open Note") { NSWorkspace.shared.open(note) }
                }
                if job.status == .running || job.status == .queued {
                    Button("Cancel") { jobs.cancel(job.id) }
                }
                if job.canRetry {
                    Button("Retry", action: retry)
                        .disabled(job.sourceURL == nil && job.videoURL == nil)
                }
            }
            if !job.artifacts.isEmpty {
                HStack {
                    ForEach(job.artifacts.filter { $0.kind != .video && $0.kind != .note }.prefix(4)) { artifact in
                        Button(artifact.kind.rawValue) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: artifact.path))
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 8)
    }

    private func statusColor(_ status: JobStatus) -> Color {
        switch status {
        case .queued: .gray
        case .running: .blue
        case .completed: .green
                case .failed: .red
                case .cancelled: .orange
                }
    }
}

struct FinishedJobsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MVS Library")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Finished notes and archived media")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(settings.vaultURL)
                } label: {
                    Label("Open", systemImage: "folder")
                }
            }

            if library.finishedJobs.isEmpty {
                ContentUnavailableView(
                    "No finished notes",
                    systemImage: "checklist",
                    description: Text("Generated MVS notes will appear here.")
                )
            } else {
                List(library.finishedJobs) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(item.source.libraryDirectoryName)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open Note") { NSWorkspace.shared.open(item.noteURL) }
                            if let video = item.videoURL {
                                Button("Open Video") { NSWorkspace.shared.open(video) }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(24)
    }
}

struct AppLibrarySummaryView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("App Library", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.open(settings.vaultURL)
                } label: {
                    Label("Open Library", systemImage: "folder")
                }
                Button {
                    NSWorkspace.shared.open(settings.videoRootURL)
                } label: {
                    Label("Open Assets", systemImage: "film.stack")
                }
            }
            Text("All generated notes, transcripts, summaries, job history, and videos are stored in MVS-owned app storage, not inside /Applications/MVS.app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(settings.vaultPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
