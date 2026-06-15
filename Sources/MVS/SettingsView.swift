import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var openAIAPIKey = ""
    @State private var deepSeekAPIKey = ""
    @State private var bailianAPIKey = ""

    var body: some View {
        Form {
            Section("MVS Library") {
                HStack {
                    TextField("Library path", text: $settings.vaultPath)
                    Button("Choose") {
                        chooseDirectory { settings.vaultPath = $0.path }
                    }
                    Button("App Default") {
                        settings.resetLibraryToAppDefault()
                    }
                    Button("Open") {
                        NSWorkspace.shared.open(settings.vaultURL)
                    }
                }
                HStack {
                    TextField("Asset storage path", text: $settings.videoRootPath)
                    Button("Choose") {
                        chooseDirectory { settings.videoRootPath = $0.path }
                    }
                    Button("Default") {
                        settings.resetVideoRootToVaultDefault()
                    }
                    Button("Open") {
                        NSWorkspace.shared.open(settings.videoRootURL)
                    }
                }
                Text("MVS stores notes, transcripts, summaries, job database, and videos here by default. This does not require Obsidian.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI Summary Provider") {
                Picker("Provider", selection: $settings.summaryProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Summary model", text: $settings.summaryModel)

                HStack {
                    SecureField(settings.hasAPIKey ? "OpenAI key saved in Keychain" : "OpenAI API key", text: $openAIAPIKey)
                    Button("Save") {
                        settings.saveAPIKey(openAIAPIKey, provider: .openAI)
                        openAIAPIKey = ""
                    }
                    .disabled(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear") {
                        settings.clearAPIKey(provider: .openAI)
                    }
                    .disabled(!settings.hasAPIKey)
                }
                Text(settings.hasAPIKey ? "OpenAI key is configured for optional OpenAI summaries/transcription." : "OpenAI key is not configured.")
                    .foregroundStyle(settings.hasAPIKey ? .green : .secondary)

                HStack {
                    SecureField(settings.hasDeepSeekAPIKey ? "DeepSeek key saved in Keychain" : "DeepSeek API key", text: $deepSeekAPIKey)
                    Button("Save") {
                        settings.saveAPIKey(deepSeekAPIKey, provider: .deepSeek)
                        deepSeekAPIKey = ""
                    }
                    .disabled(deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear") {
                        settings.clearAPIKey(provider: .deepSeek)
                    }
                    .disabled(!settings.hasDeepSeekAPIKey)
                }
                Text(settings.hasDeepSeekAPIKey ? "DeepSeek key is configured for transcript summaries." : "DeepSeek key is not configured.")
                    .foregroundStyle(settings.hasDeepSeekAPIKey ? .green : .secondary)
            }

            Section("Audio Transcription Provider") {
                Picker("Provider", selection: $settings.transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Transcription model", text: $settings.transcriptionModel)

                HStack {
                    SecureField(settings.hasBailianASRAPIKey ? "Bailian ASR key saved in Keychain" : "Bailian ASR API key", text: $bailianAPIKey)
                    Button("Save") {
                        settings.saveTranscriptionAPIKey(bailianAPIKey, provider: .bailianASR)
                        bailianAPIKey = ""
                    }
                    .disabled(bailianAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear") {
                        settings.clearTranscriptionAPIKey(provider: .bailianASR)
                    }
                    .disabled(!settings.hasBailianASRAPIKey)
                }
                Text(settings.hasBailianASRAPIKey ? "Bailian ASR key is configured for audio transcription." : "Bailian ASR key is not configured.")
                    .foregroundStyle(settings.hasBailianASRAPIKey ? .green : .secondary)
            }

            Section("URL Download") {
                Toggle("Prefer platform subtitles before ASR", isOn: $settings.preferPlatformSubtitles)
                Toggle("Force ASR for URL videos", isOn: $settings.forceASRForURL)
                HStack {
                    TextField("YouTube cookies.txt path", text: $settings.youtubeCookiesFile)
                    Button("Choose") {
                        chooseFile { settings.youtubeCookiesFile = $0.path }
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
                TextField("Proxy for yt-dlp, for example http://127.0.0.1:7897", text: $settings.youtubeProxy)
            }

            Section("Analysis") {
                Toggle("Enable diarization for meeting recordings", isOn: $settings.enableDiarizationForMeetings)
                Picker("Summary language", selection: $settings.languageMode) {
                    Text("Follow source").tag("follow-source")
                }
            }

            if let error = settings.lastSettingsError {
                Section("Error") {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(24)
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
}
