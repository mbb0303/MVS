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
    @EnvironmentObject private var recorder: RecordingController

    @State private var selection: LibrarySelection?
    @State private var filter: LibraryFilter = .all
    @State private var folderFilter = "__all__"
    @State private var searchText = ""
    @State private var showNewFolder = false
    @State private var renameItem: FinishedJob?
    @State private var moveItem: FinishedJob?
    @State private var deleteItem: FinishedJob?
    @State private var deletePendingItem: PendingVideoSummary?
    @State private var operationError: String?

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
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 450)
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
        .onChange(of: filter) {
            folderFilter = "__all__"
            selectFirstIfNeeded()
        }
        .sheet(isPresented: $showNewFolder) {
            NewLibraryFolderSheet(
                folders: library.folders,
                initialSourceDirectory: defaultFolderSource
            ) { name, parent, sourceDirectory in
                createFolder(name: name, parent: parent, sourceDirectory: sourceDirectory)
            }
        }
        .sheet(item: $renameItem) { item in
            RenameProjectSheet(item: item) { title in
                rename(item, to: title)
            }
        }
        .sheet(item: $moveItem) { item in
            MoveProjectSheet(item: item, folders: library.folderPaths(for: item.source)) { path in
                move(item, to: path)
            }
        }
        .confirmationDialog(
            "Delete project?",
            isPresented: Binding(
                get: { deleteItem != nil },
                set: { if !$0 { deleteItem = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteItem
        ) { item in
            Button("Move Project and Media to Trash", role: .destructive) {
                delete(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("“\(item.title)” and all generated artifacts will be moved to the Trash.")
        }
        .confirmationDialog(
            "Delete video?",
            isPresented: Binding(
                get: { deletePendingItem != nil },
                set: { if !$0 { deletePendingItem = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletePendingItem
        ) { item in
            Button("Move Video to Trash", role: .destructive) {
                deletePending(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("“\(item.title)” will be removed from the MVS Library.")
        }
        .alert("Library Operation Failed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "Unknown error")
        }
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            Picker("Source", selection: $filter) {
                ForEach(LibraryFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)

            Picker("Folder", selection: $folderFilter) {
                Text("All folders").tag("__all__")
                Text("Unfiled").tag("__root__")
                if !visibleFolders.isEmpty {
                    Divider()
                    ForEach(visibleFolders) { folder in
                        Text("\(folder.sourceDirectoryName) / \(folder.path)")
                            .tag(folder.id)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(width: 145)

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 155)

            Button {
                showNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(MVSSecondaryButtonStyle())
            .help("New folder")

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
                    ForEach(groupedFinished, id: \.folder) { group in
                        Section {
                            ForEach(group.items) { item in
                                FinishedLibraryRow(item: item)
                                    .tag(LibrarySelection.finished(item.id))
                            }
                        } header: {
                            Label(
                                group.folder.isEmpty ? "Unfiled" : group.folder,
                                systemImage: group.folder.isEmpty ? "tray" : "folder"
                            )
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
                LibraryDetailView(
                    item: item,
                    canManage: !jobs.hasActiveJobs && !recorder.isBusy,
                    rename: { renameItem = item },
                    move: { moveItem = item },
                    delete: { deleteItem = item }
                )
            } else {
                emptyDetail
            }
        case .pending(let id):
            if let item = library.pendingVideos.first(where: { $0.id == id }) {
                PendingLibraryDetail(
                    item: item,
                    canManage: !jobs.hasActiveJobs && !recorder.isBusy,
                    summarize: {
                        pipeline.summarizeArchivedVideo(
                            item.videoURL,
                            source: item.source,
                            settings: settings,
                            jobs: jobs,
                            library: library
                        )
                        showJobs()
                    },
                    delete: { deletePendingItem = item }
                )
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

    private var visibleFolders: [LibraryFolder] {
        library.folders.filter { folder in
            switch filter {
            case .all: true
            case .url: folder.sourceDirectoryName == "URL"
            case .local: folder.sourceDirectoryName == "Local"
            case .meeting: folder.sourceDirectoryName == "Meeting"
            }
        }
    }

    private var filteredFinished: [FinishedJob] {
        library.finishedJobs.filter { item in
            guard matches(source: item.source, title: item.title) else { return false }
            let key = "\(item.source.libraryDirectoryName)/\(item.folderPath)"
            switch folderFilter {
            case "__all__": return true
            case "__root__": return item.folderPath.isEmpty
            default: return key == folderFilter
            }
        }
    }

    private var groupedFinished: [(folder: String, items: [FinishedJob])] {
        let groups = Dictionary(grouping: filteredFinished, by: \.folderPath)
        return groups.keys.sorted { lhs, rhs in
            if lhs.isEmpty { return true }
            if rhs.isEmpty { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        .map { ($0, groups[$0] ?? []) }
    }

    private var filteredPending: [PendingVideoSummary] {
        guard folderFilter == "__all__" || folderFilter == "__root__" else { return [] }
        return library.pendingVideos.filter { matches(source: $0.source, title: $0.title) }
    }

    private var defaultFolderSource: String {
        switch filter {
        case .url: "URL"
        case .local: "Local"
        case .meeting: "Meeting"
        case .all: "Meeting"
        }
    }

    private func matches(source: VideoSourceKind, title: String) -> Bool {
        let sourceMatches: Bool
        switch filter {
        case .all: sourceMatches = true
        case .url: sourceMatches = source == .url
        case .local: sourceMatches = source == .local
        case .meeting:
            sourceMatches = source == .zoom || source == .tencentMeeting || source == .screenRecording
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceMatches && (query.isEmpty || title.localizedCaseInsensitiveContains(query))
    }

    private func selectFirstIfNeeded() {
        if let selection {
            switch selection {
            case .finished(let id) where filteredFinished.contains(where: { $0.id == id }): return
            case .pending(let id) where filteredPending.contains(where: { $0.id == id }): return
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

    private func createFolder(name: String, parent: String?, sourceDirectory: String) {
        do {
            let path = try library.createFolder(
                named: name,
                parentPath: parent,
                sourceDirectoryName: sourceDirectory,
                settings: settings
            )
            folderFilter = "\(sourceDirectory)/\(path)"
            filter = sourceDirectory == "URL" ? .url : (sourceDirectory == "Local" ? .local : .meeting)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func rename(_ item: FinishedJob, to title: String) {
        do {
            try library.renameProject(item, to: title, settings: settings)
            jobs.renameProjects(mediaID: item.mediaID, title: title)
            selection = library.finishedJobs
                .first(where: { $0.mediaID == item.mediaID })
                .map { .finished($0.id) }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func move(_ item: FinishedJob, to path: String?) {
        do {
            let mapping = try library.moveProject(item, toFolderPath: path, settings: settings)
            jobs.relocateArtifacts(mapping, mediaID: item.mediaID)
            folderFilter = path.map { "\(item.source.libraryDirectoryName)/\($0)" } ?? "__root__"
            selection = library.finishedJobs
                .first(where: { $0.mediaID == item.mediaID })
                .map { .finished($0.id) }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func delete(_ item: FinishedJob) {
        do {
            try library.deleteProject(item, settings: settings)
            jobs.removeProjects(mediaID: item.mediaID)
            deleteItem = nil
            selection = nil
            selectFirstIfNeeded()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deletePending(_ item: PendingVideoSummary) {
        do {
            try library.deletePendingVideo(item, settings: settings)
            deletePendingItem = nil
            selection = nil
            selectFirstIfNeeded()
        } catch {
            operationError = error.localizedDescription
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
                    if !item.folderPath.isEmpty {
                        Text("·")
                        Text(item.folderPath)
                    }
                    if let created = item.createdAt {
                        Text("·")
                        Text(created.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(MVSTheme.muted)
                .lineLimit(1)
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
    let canManage: Bool
    let rename: () -> Void
    let move: () -> Void
    let delete: () -> Void
    @State private var tab: LibraryArtifactTab = .note

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.source.libraryDirectoryName.uppercased())
                        if !item.folderPath.isEmpty {
                            Text("/")
                            Text(item.folderPath.uppercased())
                        }
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MVSTheme.gold)
                    Text(item.title)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(MVSTheme.ink)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(action: rename) { Image(systemName: "pencil") }
                    .buttonStyle(MVSSecondaryButtonStyle())
                    .help("Rename project")
                    .disabled(!canManage)
                Button(action: move) { Image(systemName: "folder") }
                    .buttonStyle(MVSSecondaryButtonStyle())
                    .help("Move to folder")
                    .disabled(!canManage)
                if let video = item.videoURL {
                    Button {
                        NSWorkspace.shared.open(video)
                    } label: {
                        Image(systemName: "play.rectangle")
                    }
                    .buttonStyle(MVSSecondaryButtonStyle())
                    .help("Open video")
                }
                Button(action: delete) { Image(systemName: "trash") }
                    .buttonStyle(MVSSecondaryButtonStyle())
                    .foregroundStyle(MVSTheme.danger)
                    .help("Delete project")
                    .disabled(!canManage)
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
    let canManage: Bool
    let summarize: () -> Void
    let delete: () -> Void

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
                .disabled(!canManage)
                Button {
                    NSWorkspace.shared.open(item.videoURL)
                } label: {
                    Label("Open Video", systemImage: "play.rectangle")
                }
                .buttonStyle(MVSSecondaryButtonStyle())
                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(MVSSecondaryButtonStyle())
                .foregroundStyle(MVSTheme.danger)
                .disabled(!canManage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .background(MVSTheme.canvas)
    }
}

private struct RenameProjectSheet: View {
    let item: FinishedJob
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    init(item: FinishedJob, save: @escaping (String) -> Void) {
        self.item = item
        self.save = save
        _title = State(initialValue: item.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Project").font(.system(size: 18, weight: .semibold))
            TextField("Project title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(MVSSecondaryButtonStyle())
                Button("Rename", action: commit)
                    .buttonStyle(MVSPrimaryButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(MVSTheme.canvas)
    }

    private func commit() {
        save(title)
        dismiss()
    }
}

private struct MoveProjectSheet: View {
    let item: FinishedJob
    let folders: [String]
    let move: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination: String

    init(item: FinishedJob, folders: [String], move: @escaping (String?) -> Void) {
        self.item = item
        self.folders = folders
        self.move = move
        _destination = State(initialValue: item.folderPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move Project").font(.system(size: 18, weight: .semibold))
            Picker("Folder", selection: $destination) {
                Text("Unfiled").tag("")
                ForEach(folders, id: \.self) { path in
                    Text(path).tag(path)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(MVSSecondaryButtonStyle())
                Button("Move") {
                    move(destination.isEmpty ? nil : destination)
                    dismiss()
                }
                .buttonStyle(MVSPrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(MVSTheme.canvas)
    }
}

private struct NewLibraryFolderSheet: View {
    let folders: [LibraryFolder]
    let create: (String, String?, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sourceDirectory: String
    @State private var parentPath = ""

    init(
        folders: [LibraryFolder],
        initialSourceDirectory: String,
        create: @escaping (String, String?, String) -> Void
    ) {
        self.folders = folders
        self.create = create
        _sourceDirectory = State(initialValue: initialSourceDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Folder").font(.system(size: 18, weight: .semibold))
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Source", selection: $sourceDirectory) {
                Text("URL").tag("URL")
                Text("Local").tag("Local")
                Text("Meeting").tag("Meeting")
            }
            .pickerStyle(.segmented)
            Picker("Parent", selection: $parentPath) {
                Text("Source root").tag("")
                ForEach(parentFolders, id: \.path) { folder in
                    Text(folder.path).tag(folder.path)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(MVSSecondaryButtonStyle())
                Button("Create") {
                    create(name, parentPath.isEmpty ? nil : parentPath, sourceDirectory)
                    dismiss()
                }
                .buttonStyle(MVSPrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(MVSTheme.canvas)
        .onChange(of: sourceDirectory) {
            parentPath = ""
        }
    }

    private var parentFolders: [LibraryFolder] {
        folders.filter { $0.sourceDirectoryName == sourceDirectory }
    }
}

private func sourceIcon(_ source: VideoSourceKind) -> String {
    switch source {
    case .url: "link"
    case .local: "film"
    case .zoom, .tencentMeeting: "person.2.wave.2"
    case .screenRecording: "display"
    }
}
