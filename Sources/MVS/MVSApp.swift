import SwiftUI
import AppKit

@main
struct MVSApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var jobStore = JobStore()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var recorder = RecordingController()

    init() {
        AppIcon.installRuntimeIcon()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(jobStore)
                .environmentObject(libraryStore)
                .environmentObject(recorder)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 640)
        }
    }
}

enum AppIcon {
    @MainActor
    static func installRuntimeIcon() {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return
        }
        NSApplication.shared.applicationIconImage = image
    }
}
