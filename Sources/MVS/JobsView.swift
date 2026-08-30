import AppKit
import SwiftUI

enum JobFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case attention = "Attention"
    case completed = "Completed"

    var id: String { rawValue }
}

struct JobsView: View {
    let pipeline: AnalysisPipeline

    @EnvironmentObject private var jobs: JobStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore

    @State private var selection: AnalysisJob.ID?
    @State private var filter: JobFilter = .all
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            MVSPageHeader(
                title: "Jobs",
                eyebrow: "Processing queue",
                trailing: AnyView(filterControls)
            )
            .padding(.horizontal, 24)
            .padding(.top, 24)

            HSplitView {
                jobList
                    .frame(minWidth: 310, idealWidth: 350, maxWidth: 430)
                    .frame(maxHeight: .infinity)
                    .background(MVSTheme.surface)
                detail
                    .frame(minWidth: 480)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .mvsPage()
        .onAppear {
            if selection == nil {
                selection = filteredJobs.first?.id
            }
        }
        .onChange(of: jobs.jobs.map(\.id)) {
            if let selection, jobs.job(with: selection) == nil {
                self.selection = filteredJobs.first?.id
            } else if selection == nil {
                selection = filteredJobs.first?.id
            }
        }
    }

    private var filterControls: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(JobFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }

    private var jobList: some View {
        Group {
            if filteredJobs.isEmpty {
                ContentUnavailableView("No matching jobs", systemImage: "tray")
            } else {
                List(filteredJobs, selection: $selection) { job in
                    JobListRow(job: job)
                        .tag(job.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(selection == job.id ? MVSTheme.periwinkle.opacity(0.20) : Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(MVSTheme.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(MVSTheme.line).frame(width: 1)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let job = jobs.job(with: selection) {
            JobDetailView(
                job: job,
                cancel: { jobs.cancel(job.id) },
                retry: { retry(job) },
                remove: {
                    jobs.remove(job.id)
                    self.selection = filteredJobs.first?.id
                }
            )
        } else {
            ContentUnavailableView("Select a job", systemImage: "list.bullet.rectangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filteredJobs: [AnalysisJob] {
        jobs.jobs.filter { job in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .active: matchesFilter = job.status == .queued || job.status == .running
            case .attention: matchesFilter = job.status == .failed || job.status == .cancelled
            case .completed: matchesFilter = job.status == .completed
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || job.title.localizedCaseInsensitiveContains(query)
                || job.source.displayName.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesSearch
        }
    }

    private func retry(_ job: AnalysisJob) {
        jobs.remove(job.id)
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
        } else if let videoURL = job.videoURL {
            pipeline.summarizeArchivedVideo(
                videoURL,
                source: job.source,
                settings: settings,
                jobs: jobs,
                library: library
            )
        }
        selection = jobs.jobs.first?.id
    }
}

private struct JobListRow: View {
    let job: AnalysisJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MVSEnergyCore(active: job.status == .running)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MVSTheme.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(job.source.displayName)
                    Text("·")
                    Text(job.status == .running ? job.stage.displayName : job.status.rawValue)
                }
                .font(.system(size: 10))
                .foregroundStyle(MVSTheme.muted)
                Text(job.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(MVSTheme.muted.opacity(0.8))
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 8)
    }
}

private struct JobDetailView: View {
    let job: AnalysisJob
    let cancel: () -> Void
    let retry: () -> Void
    let remove: () -> Void

    @State private var markdownDocument: MarkdownDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if job.status == .running || job.status == .queued {
                    ProgressView(value: job.progressValue)
                        .tint(MVSTheme.cyan)
                }

                processTimeline

                if let error = job.errorMessage, !error.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Error", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(MVSTheme.danger)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(MVSTheme.danger)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MVSTheme.danger.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                actions
                artifacts
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(MVSTheme.canvas)
        .sheet(item: $markdownDocument) { document in
            MarkdownReaderView(document: document)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.source.displayName.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MVSTheme.gold)
                    Text(job.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MVSTheme.ink)
                        .textSelection(.enabled)
                }
                Spacer()
                MVSStatusBadge(status: job.status)
            }
            Text(job.progress)
                .font(.system(size: 12))
                .foregroundStyle(MVSTheme.muted)
        }
    }

    private var processTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PROCESS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(MVSTheme.indigo)
                .padding(.bottom, 10)
            ForEach(processStages, id: \.self) { stage in
                HStack(spacing: 10) {
                    Circle()
                        .fill(stageColor(stage))
                        .frame(width: 8, height: 8)
                    Text(stage.displayName)
                        .font(.system(size: 12, weight: stage == job.stage ? .semibold : .regular))
                        .foregroundStyle(stage == job.stage ? MVSTheme.ink : MVSTheme.muted)
                    Spacer()
                }
                .frame(height: 28)
                .overlay(alignment: .leading) {
                    if stage != processStages.last {
                        Rectangle()
                            .fill(MVSTheme.line)
                            .frame(width: 1, height: 20)
                            .offset(x: 3.5, y: 20)
                    }
                }
            }
        }
        .padding(16)
        .background(MVSTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(MVSTheme.line, lineWidth: 1) }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if job.status == .running || job.status == .queued {
                Button(action: cancel) { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(MVSSecondaryButtonStyle())
            }
            if job.canRetry {
                Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(MVSPrimaryButtonStyle())
                    .disabled(job.sourceURL == nil && job.videoURL == nil)
            }
            if let note = job.noteURL {
                Button {
                    markdownDocument = MarkdownDocument(url: note)
                } label: {
                    Label("Read Note", systemImage: "doc.text")
                }
                .buttonStyle(MVSPrimaryButtonStyle())
            }
            if let video = job.videoURL {
                Button {
                    NSWorkspace.shared.open(video)
                } label: {
                    Label("Open Video", systemImage: "play.rectangle")
                }
                .buttonStyle(MVSSecondaryButtonStyle())
            }
            Spacer()
            if job.status == .failed || job.status == .cancelled || job.status == .completed {
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(MVSTheme.muted)
                .help("Remove from job history")
            }
        }
    }

    @ViewBuilder
    private var artifacts: some View {
        if !job.artifacts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("OUTPUTS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MVSTheme.indigo)
                ForEach(job.artifacts) { artifact in
                    Button {
                        openArtifact(artifact)
                    } label: {
                        HStack {
                            Image(systemName: artifactIcon(artifact.kind))
                                .frame(width: 18)
                            Text(artifact.kind.rawValue)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MVSTheme.ink)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var processStages: [JobStage] {
        [.metadata, .subtitleProbe, .download, .audioDownload, .archive, .audioExtraction, .transcription, .summarization, .writing, .cleanup]
    }

    private func stageColor(_ stage: JobStage) -> Color {
        guard let current = processStages.firstIndex(of: job.stage),
              let index = processStages.firstIndex(of: stage) else {
            return MVSTheme.line
        }
        if index < current { return MVSTheme.success }
        if index == current { return MVSTheme.cyan }
        return MVSTheme.line
    }

    private func artifactIcon(_ kind: JobArtifact.Kind) -> String {
        switch kind {
        case .video: "film"
        case .note, .transcriptMarkdown, .outline, .mindmap: "doc.text"
        case .metadata, .summaryJSON: "curlybraces"
        case .transcriptSRT: "captions.bubble"
        }
    }

    private func openArtifact(_ artifact: JobArtifact) {
        let url = URL(fileURLWithPath: artifact.path)
        if url.pathExtension.lowercased() == "md" {
            markdownDocument = MarkdownDocument(url: url)
        } else if artifact.kind == .video {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
