import AppKit
import SwiftUI

enum MVSSection: String, CaseIterable, Identifiable {
    case newTask
    case jobs
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTask: "New Task"
        case .jobs: "Jobs"
        case .library: "Library"
        }
    }

    var systemImage: String {
        switch self {
        case .newTask: "plus.square"
        case .jobs: "list.bullet.rectangle"
        case .library: "books.vertical"
        }
    }
}

struct AppSidebar: View {
    @Binding var selection: MVSSection
    @EnvironmentObject private var jobs: JobStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            brand
            List(selection: $selection) {
                ForEach(MVSSection.allCases) { section in
                    sidebarRow(section)
                        .tag(section)
                        .listRowBackground(selection == section ? MVSTheme.indigo : Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            libraryFooter
        }
        .background(MVSTheme.surface)
    }

    private var brand: some View {
        HStack(spacing: 11) {
            brandIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("MVS")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MVSTheme.ink)
                Text("MEDIA INTELLIGENCE")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(MVSTheme.gold)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MVSTheme.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var brandIcon: some View {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
        } else {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 26))
                .foregroundStyle(MVSTheme.indigo)
                .frame(width: 42, height: 42)
        }
    }

    private func sidebarRow(_ section: MVSSection) -> some View {
        HStack(spacing: 10) {
            if selection == section {
                Rectangle()
                    .fill(MVSTheme.gold)
                    .frame(width: 7, height: 7)
                    .rotationEffect(.degrees(45))
            } else {
                Color.clear.frame(width: 7, height: 7)
            }
            Image(systemName: section.systemImage)
                .frame(width: 18)
            Text(section.title)
                .font(.system(size: 13, weight: selection == section ? .semibold : .medium))
            Spacer()
            if section == .jobs, activeJobCount > 0 {
                Text("\(activeJobCount)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(selection == section ? MVSTheme.cyan.opacity(0.20) : MVSTheme.periwinkle.opacity(0.25))
                    .clipShape(Capsule())
            } else if section == .library, !library.finishedJobs.isEmpty {
                Text("\(library.finishedJobs.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selection == section ? .white.opacity(0.8) : MVSTheme.muted)
            }
        }
        .foregroundStyle(selection == section ? Color.white : MVSTheme.ink)
        .padding(.vertical, 5)
    }

    private var libraryFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(MVSTheme.ink)

            Text(settings.vaultPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(MVSTheme.muted)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(16)
        .overlay(alignment: .top) {
            Rectangle().fill(MVSTheme.line).frame(height: 1)
        }
    }

    private var activeJobCount: Int {
        jobs.jobs.filter { $0.status == .queued || $0.status == .running }.count
    }
}
