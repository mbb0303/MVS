import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var jobs: JobStore
    @EnvironmentObject private var library: LibraryStore

    @State private var section: MVSSection = .newTask
    @State private var pipeline = AnalysisPipeline()

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $section)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            switch section {
            case .newTask:
                NewTaskView(pipeline: pipeline) {
                    section = .jobs
                }
            case .jobs:
                JobsView(pipeline: pipeline)
            case .library:
                LibraryView(pipeline: pipeline) {
                    section = .jobs
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    section = .newTask
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)

                if section == .jobs || section == .library {
                    Button {
                        library.refresh(settings: settings)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .task {
            MediaProcessor.cleanupStaleTemporaryDirectories()
            jobs.configure(settings: settings)
            library.refresh(settings: settings)
            await settings.prepareCredentials()
        }
        .onChange(of: settings.vaultPath) {
            jobs.configure(settings: settings)
            library.refresh(settings: settings)
        }
        .onChange(of: settings.videoRootPath) {
            library.refresh(settings: settings)
        }
        .tint(MVSTheme.indigo)
    }
}
