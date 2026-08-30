import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var jobs: JobStore
    @EnvironmentObject private var library: LibraryStore

    @State private var openAIAPIKey = ""
    @State private var deepSeekAPIKey = ""
    @State private var bailianAPIKey = ""
    @State private var confirmEraseHistory = false
    @State private var eraseError: String?

    var body: some View {
        TabView {
            settingsPage { librarySettings }
                .tabItem { Label("Library", systemImage: "externaldrive") }

            settingsPage { aiSettings }
                .tabItem { Label("AI", systemImage: "sparkles") }

            settingsPage { downloadSettings }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            settingsPage { recordingSettings }
                .tabItem { Label("Recording", systemImage: "record.circle") }

            settingsPage { dataSettings }
                .tabItem { Label("Data", systemImage: "internaldrive") }
        }
        .padding(.top, 8)
        .background(MVSTheme.canvas)
        .confirmationDialog(
            "Erase all MVS history?",
            isPresented: $confirmEraseHistory,
            titleVisibility: .visible
        ) {
            Button("Erase Jobs, Notes, and Media", role: .destructive) {
                eraseHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Generated files are moved to the Trash. API keys and preferences are not changed.")
        }
        .alert("Could Not Erase History", isPresented: Binding(
            get: { eraseError != nil },
            set: { if !$0 { eraseError = nil } }
        )) {
            Button("OK") { eraseError = nil }
        } message: {
            Text(eraseError ?? "Unknown error")
        }
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: 680)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var librarySettings: some View {
        Form {
            Section("MVS Library") {
                LabeledContent("Library path") {
                    HStack {
                        TextField("Library path", text: $settings.vaultPath)
                        Button("Choose") { chooseDirectory { settings.vaultPath = $0.path } }
                        Button("App Default") { settings.resetLibraryToAppDefault() }
                        Button {
                            NSWorkspace.shared.open(settings.vaultURL)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Open library")
                    }
                }

                LabeledContent("Media path") {
                    HStack {
                        TextField("Media storage path", text: $settings.videoRootPath)
                        Button("Choose") { chooseDirectory { settings.videoRootPath = $0.path } }
                        Button("Default") { settings.resetVideoRootToVaultDefault() }
                        Button {
                            NSWorkspace.shared.open(settings.videoRootURL)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Open media storage")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aiSettings: some View {
        Form {
            Section("Summary") {
                Picker("Provider", selection: $settings.summaryProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Model", text: $settings.summaryModel)

                credentialRow(
                    label: "OpenAI API key",
                    configured: settings.hasAPIKey,
                    value: $openAIAPIKey,
                    save: {
                        settings.saveAPIKey(openAIAPIKey, provider: .openAI)
                        openAIAPIKey = ""
                    },
                    clear: { settings.clearAPIKey(provider: .openAI) }
                )

                credentialRow(
                    label: "DeepSeek API key",
                    configured: settings.hasDeepSeekAPIKey,
                    value: $deepSeekAPIKey,
                    save: {
                        settings.saveAPIKey(deepSeekAPIKey, provider: .deepSeek)
                        deepSeekAPIKey = ""
                    },
                    clear: { settings.clearAPIKey(provider: .deepSeek) }
                )
            }

            Section("Transcription") {
                Picker("Provider", selection: $settings.transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Model", text: $settings.transcriptionModel)

                credentialRow(
                    label: "Bailian API key",
                    configured: settings.hasBailianASRAPIKey,
                    value: $bailianAPIKey,
                    save: {
                        settings.saveTranscriptionAPIKey(bailianAPIKey, provider: .bailianASR)
                        bailianAPIKey = ""
                    },
                    clear: { settings.clearTranscriptionAPIKey(provider: .bailianASR) }
                )
            }

            if let error = settings.lastSettingsError {
                Section("Error") {
                    Text(error).foregroundStyle(MVSTheme.danger)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var downloadSettings: some View {
        Form {
            Section("URL Analysis") {
                Toggle("Prefer platform subtitles before ASR", isOn: $settings.preferPlatformSubtitles)
                Toggle("Force ASR for URL videos", isOn: $settings.forceASRForURL)
            }

            Section("YouTube") {
                LabeledContent("Cookies file") {
                    HStack {
                        TextField("Optional cookies.txt path", text: $settings.youtubeCookiesFile)
                        Button("Choose") { chooseFile { settings.youtubeCookiesFile = $0.path } }
                    }
                }
                Picker("Cookies browser", selection: $settings.youtubeCookiesBrowser) {
                    Text("None").tag("")
                    Text("Safari").tag("safari")
                    Text("Chrome").tag("chrome")
                    Text("Firefox").tag("firefox")
                    Text("Edge").tag("edge")
                    Text("Brave").tag("brave")
                }
                TextField("Proxy URL, for example http://127.0.0.1:7897", text: $settings.youtubeProxy)
            }
        }
        .formStyle(.grouped)
    }

    private var recordingSettings: some View {
        Form {
            Section("Meeting Capture") {
                Toggle("Enable speaker diarization when supported", isOn: $settings.enableDiarizationForMeetings)
                Picker("Summary language", selection: $settings.languageMode) {
                    Text("Follow source").tag("follow-source")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Generated History")
                .font(.system(size: 18, weight: .semibold))
            Text(jobs.hasActiveJobs
                ? "Wait for active jobs to finish or cancel them first."
                : "Erase task history, notes, transcripts, summaries, and archived media. API keys and preferences remain unchanged.")
                .font(.system(size: 13))
                .foregroundStyle(MVSTheme.muted)
            Button("Erase All History", role: .destructive) {
                confirmEraseHistory = true
            }
            .disabled(jobs.hasActiveJobs)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .padding(20)
        .background(MVSTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(MVSTheme.line, lineWidth: 1) }
    }

    private func credentialRow(
        label: String,
        configured: Bool,
        value: Binding<String>,
        save: @escaping () -> Void,
        clear: @escaping () -> Void
    ) -> some View {
        LabeledContent(label) {
            HStack {
                SecureField(configured ? "Saved in Keychain" : "Not configured", text: value)
                Button("Save", action: save)
                    .disabled(value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Clear", action: clear)
                    .disabled(!configured)
            }
        }
    }

    private func chooseDirectory(_ update: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            update(url)
        }
    }

    private func chooseFile(_ update: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            update(url)
        }
    }

    private func eraseHistory() {
        do {
            jobs.clearHistory()
            try library.eraseAllGeneratedData(settings: settings)
            library.refresh(settings: settings)
        } catch {
            eraseError = error.localizedDescription
        }
    }
}
