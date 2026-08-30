import AppKit
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case url = "URL"
    case local = "Local"
    case meeting = "Meeting"

    var id: String { rawValue }
}

private enum LibrarySelection: Hashable {
    case finished(String)
    case pending(String)
}

private enum LibraryArtifactTab: String, CaseIterable, Identifiable {
    case note = "Note"
    case transcript = "Transcript"
    case outline = "Outline"
    case mindmap = "Mindmap"
    case metadata = "Metadata"

    var id: String { rawValue }
}

struct LibraryView: View {
    let pipeline: AnalysisPipeline
    let showJobs: () -> Void

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var jobs: JobStore

    @State private var selection: LibrarySelection?
    @State private var filter: LibraryFilter = .all
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            MVSPageHeader(
                title: "Library",
                eyebrow: "Knowledge archive",
                trailing: AnyView(headerControls)
            )
            .padding(.horizontal, 24)
            .padding(.top, 24)

            HSplitView {
                itemList
                    .frame(minWidth: 310, idealWidth: 350, maxWidth: 430)
                    .frame(maxHeight: .infinity)
                    .background(MVSTheme.surface)
                detail
                    .frame(minWidth: 500)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .mvsPage()
        .onAppear {
            library.refresh(settings: settings)
            selectFirstIfNeeded()
        }
        .onChange(of: library.finishedJobs.map(\.id) + library.pendingVideos.map(\.id)) {
            selectFirstIfNeeded()
        }
    }

    private var headerControls: some View {
        HStack(spacing: 10) {
            Picker("Source", selection: $filter) {
                ForEach(LibraryFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 105)

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            Button {
                library.refresh(settings: settings)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(MVSSecondaryButtonStyle())
            .help("Refresh library")
        }
    }

    private var itemList: some View {
        Group {
            if filteredFinished.isEmpty && filteredPending.isEmpty {
                ContentUnavailableView("Library is empty", systemImage: "books.vertical")
            } else {
                List(selection: $selection) {
                    if !filteredPending.isEmpty {
                        Section("Needs summary") {
                            ForEach(filteredPending) { item in
                                PendingLibraryRow(item: item)
                                    .tag(LibrarySelection.pending(item.id))
                            }
                        }
                    }
                    if !filteredFinished.isEmpty {
                        Section("Finished") {
                            ForEach(filteredFinished) { item in
                                FinishedLibraryRow(item: item)
                                    .tag(LibrarySelection.finished(item.id))
                            }
                        }
                    }
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
        switch selection {
        case .finished(let id):
            if let item = library.finishedJobs.first(where: { $0.id == id }) {
                LibraryDetailView(item: item)
            } else {
                emptyDetail
            }
        case .pending(let id):
            if let item = library.pendingVideos.first(where: { $0.id == id }) {
                PendingLibraryDetail(item: item) {
                    pipeline.summarizeArchivedVideo(
                        item.videoURL,
                        source: item.source,
                        settings: settings,
                        jobs: jobs,
                        library: library
                    )
                    showJobs()
                }
            } else {
                emptyDetail
            }
        case nil:
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        ContentUnavailableView("Select an item", systemImage: "doc.text.magnifyingglass")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredFinished: [FinishedJob] {
        library.finishedJobs.filter { item in
            matches(source: item.source, title: item.title)
        }
    }

    private var filteredPending: [PendingVideoSummary] {
        library.pendingVideos.filter { item in
            matches(source: item.source, title: item.title)
        }
    }

    private func matches(source: VideoSourceKind, title: String) -> Bool {
        let sourceMatches: Bool
        switch filter {
        case .all: sourceMatches = true
        case .url: sourceMatches = source == .url
        case .local: sourceMatches = source == .local
        case .meeting: sourceMatches = source == .zoom || source == .tencentMeeting
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceMatches && (query.isEmpty || title.localizedCaseInsensitiveContains(query))
    }

    private func selectFirstIfNeeded() {
        if let selection {
            switch selection {
            case .finished(let id) where library.finishedJobs.contains(where: { $0.id == id }): return
            case .pending(let id) where library.pendingVideos.contains(where: { $0.id == id }): return
            default: break
            }
        }
        if let first = filteredPending.first {
            selection = .pending(first.id)
        } else if let first = filteredFinished.first {
            selection = .finished(first.id)
        } else {
            selection = nil
        }
    }
}

private struct FinishedLibraryRow: View {
    let item: FinishedJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sourceIcon(item.source))
                .foregroundStyle(MVSTheme.indigo)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.source.libraryDirectoryName)
                    if let created = item.createdAt {
                        Text("·")
                        Text(created.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(MVSTheme.muted)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct PendingLibraryRow: View {
    let item: PendingVideoSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MVSEnergyCore(active: false)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text(item.source.libraryDirectoryName)
                    .font(.system(size: 10))
                    .foregroundStyle(MVSTheme.gold)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct LibraryDetailView: View {
    let item: FinishedJob
    @State private var tab: LibraryArtifactTab = .note

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.source.libraryDirectoryName.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MVSTheme.gold)
                    Text(item.title)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(MVSTheme.ink)
                        .textSelection(.enabled)
                }
                Spacer()
                if let video = item.videoURL {
                    Button {
                        NSWorkspace.shared.open(video)
                    } label: {
                        Label("Open Video", systemImage: "play.rectangle")
                    }
                    .buttonStyle(MVSSecondaryButtonStyle())
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.noteURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(MVSSecondaryButtonStyle())
                .help("Reveal files")
            }
            .padding(22)
            .background(MVSTheme.canvas)

            Picker("Artifact", selection: $tab) {
                ForEach(LibraryArtifactTab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
            .background(MVSTheme.canvas)

            Divider()
            artifactContent
        }
    }

    @ViewBuilder
    private var artifactContent: some View {
        let url = artifactURL(for: tab)
        if let url, FileManager.default.fileExists(atPath: url.path) {
            if tab == .metadata {
                ScrollView {
                    Text((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(MVSTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(24)
                }
                .background(MVSTheme.surface)
            } else {
                MarkdownContentView(content: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
        } else {
            ContentUnavailableView("Artifact not available", systemImage: "doc.questionmark")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func artifactURL(for tab: LibraryArtifactTab) -> URL? {
        let base = item.noteURL.deletingPathExtension()
        return switch tab {
        case .note: item.noteURL
        case .transcript: base.appendingPathExtension("transcript.md")
        case .outline: base.appendingPathExtension("outline.md")
        case .mindmap: base.appendingPathExtension("mindmap.md")
        case .metadata: base.appendingPathExtension("metadata.json")
        }
    }
}

private struct PendingLibraryDetail: View {
    let item: PendingVideoSummary
    let summarize: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(MVSTheme.periwinkle)
            Text(item.title)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(item.source.libraryDirectoryName.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(MVSTheme.gold)
            HStack(spacing: 10) {
                Button(action: summarize) {
                    Label("Summarize", systemImage: "sparkles")
                }
                .buttonStyle(MVSPrimaryButtonStyle())
                Button {
                    NSWorkspace.shared.open(item.videoURL)
                } label: {
                    Label("Open Video", systemImage: "play.rectangle")
                }
                .buttonStyle(MVSSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .background(MVSTheme.canvas)
    }
}

private func sourceIcon(_ source: VideoSourceKind) -> String {
    switch source {
    case .url: "link"
    case .local: "film"
    case .zoom, .tencentMeeting: "person.2.wave.2"
    }
}
