import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum NewTaskMode: String, CaseIterable, Identifiable {
    case url = "URL"
    case local = "Local File"
    case meeting = "Meeting"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .url: "link"
        case .local: "film"
        case .meeting: "record.circle"
        }
    }
}

struct NewTaskView: View {
    let pipeline: AnalysisPipeline
    let showJobs: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var jobs: JobStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var recorder: RecordingController

    @State private var mode: NewTaskMode = .url
    @State private var urlText = ""
    @State private var keepURLDownload = false
    @State private var preferURLSubtitles = true
    @State private var forceURLASR = false
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MVSPageHeader(
                    title: "New Task",
                    eyebrow: "Capture and analyze",
                    trailing: AnyView(providerStatus)
                )

                Picker("Source", selection: $mode) {
                    ForEach(NewTaskMode.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    switch mode {
                    case .url: urlInput
                    case .local: localInput
                    case .meeting: meetingInput
                    }
                }
                .padding(20)
                .background(MVSTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(MVSTheme.line, lineWidth: 1)
                }
            }
            .frame(maxWidth: 820)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .mvsPage()
        .onAppear {
            preferURLSubtitles = settings.preferPlatformSubtitles
            forceURLASR = settings.forceASRForURL
        }
    }

    private var urlInput: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("VIDEO URL", icon: "link")
            HStack(spacing: 10) {
                TextField("https://…", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(MVSTheme.canvas.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).stroke(MVSTheme.line, lineWidth: 1)
                    }
                    .onSubmit(analyzeURL)

                Button(action: analyzeURL) {
                    Label("Analyze", systemImage: "arrow.right")
                }
                .buttonStyle(MVSPrimaryButtonStyle())
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            DisclosureGroup("Options") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Prefer platform subtitles", isOn: $preferURLSubtitles)
                    Toggle("Keep downloaded video", isOn: $keepURLDownload)
                    Toggle("Force cloud transcription", isOn: $forceURLASR)
                }
                .toggleStyle(.checkbox)
                .padding(.top, 10)
            }
            .tint(MVSTheme.indigo)
            .foregroundStyle(MVSTheme.muted)
        }
    }

    private var localInput: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("LOCAL MEDIA", icon: "film")
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(isDropTargeted ? MVSTheme.cyan : MVSTheme.periwinkle)
                Text("Drop a video here")
                    .font(.system(size: 15, weight: .semibold))
                Button {
                    chooseVideo()
                } label: {
                    Label("Choose Video", systemImage: "folder")
                }
                .buttonStyle(MVSPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, minHeight: 210)
            .background(isDropTargeted ? MVSTheme.indigo.opacity(0.06) : MVSTheme.canvas.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDropTargeted ? MVSTheme.cyan : MVSTheme.line, style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let video = urls.first else { return false }
                analyzeLocal(video)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
        }
    }

    private var meetingInput: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("MEETING CAPTURE", icon: "record.circle")

            Picker("Capture mode", selection: $recorder.meetingSource) {
                Text("Zoom").tag(VideoSourceKind.zoom)
                Text("Tencent Meeting").tag(VideoSourceKind.tencentMeeting)
                Text("Screen").tag(VideoSourceKind.screenRecording)
            }
            .pickerStyle(.segmented)
            .disabled(recorder.isBusy)
            .onChange(of: recorder.meetingSource) {
                Task { await recorder.refreshTargets() }
            }

            HStack(spacing: 10) {
                Picker("Capture target", selection: Binding(
                    get: { recorder.selectedTargetID ?? "" },
                    set: { recorder.selectedTargetID = $0 }
                )) {
                    if recorder.targets.isEmpty {
                        Text("No target loaded").tag("")
                    }
                    ForEach(recorder.targets) { target in
                        Text(target.name).tag(target.id)
                    }
                }
                Button {
                    Task { await recorder.refreshTargets() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(MVSSecondaryButtonStyle())
                .help("Refresh capture targets")
            }
            .disabled(recorder.isBusy)

            HStack(spacing: 10) {
                Label("System audio", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MVSTheme.success)
                Toggle("Microphone", isOn: $recorder.includeMicrophone)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
            }
            .disabled(recorder.isBusy)

            HStack(spacing: 10) {
                MVSEnergyCore(active: recorder.isRecording)
                Text(recorder.status)
                    .font(.system(size: 12))
                    .foregroundStyle(MVSTheme.muted)
                Spacer()
                if recorder.isRecording {
                    Button {
                        Task {
                            if let recording = await recorder.stopRecording() {
                                pipeline.analyzeRecording(
                                    recording,
                                    source: recorder.recordingSource,
                                    settings: settings,
                                    jobs: jobs,
                                    library: library
                                )
                                showJobs()
                            }
                        }
                    } label: {
                        Label("Stop and Analyze", systemImage: "stop.fill")
                    }
                    .buttonStyle(MVSPrimaryButtonStyle())
                    .disabled(recorder.isStopping)
                } else {
                    Button {
                        Task { await recorder.startRecording(settings: settings) }
                    } label: {
                        Label("Start Recording", systemImage: "record.circle")
                    }
                    .buttonStyle(MVSPrimaryButtonStyle())
                    .disabled(recorder.isBusy || !recorder.screenPermissionGranted || recorder.selectedTargetID == nil)
                }
            }

            if !recorder.screenPermissionGranted {
                HStack(spacing: 8) {
                    Image(systemName: recorder.screenPermissionNeedsRestart ? "arrow.clockwise.circle" : "lock.shield")
                        .foregroundStyle(MVSTheme.gold)
                    Text(recorder.screenPermissionNeedsRestart
                        ? "Quit and reopen MVS once to activate the new permission."
                        : "Screen recording permission is not active for this build.")
                        .font(.system(size: 11))
                        .foregroundStyle(MVSTheme.muted)
                    Spacer()
                    Button("Open Privacy Settings") {
                        recorder.openScreenRecordingSettings()
                    }
                    .buttonStyle(MVSSecondaryButtonStyle())
                }
            }

            if recorder.includeMicrophone && recorder.microphonePermissionDenied {
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .foregroundStyle(MVSTheme.gold)
                    Text("The current build does not have microphone access. You can turn Microphone off and still record system audio.")
                        .font(.system(size: 11))
                        .foregroundStyle(MVSTheme.muted)
                    Spacer()
                    Button("Open Microphone Settings") {
                        recorder.openMicrophoneSettings()
                    }
                    .buttonStyle(MVSSecondaryButtonStyle())
                }
            }
        }
    }

    private var providerStatus: some View {
        HStack(spacing: 12) {
            statusItem(label: settings.transcriptionProvider.displayName, ready: transcriptionReady)
            statusItem(label: settings.summaryProvider.displayName, ready: summaryReady)
        }
    }

    private func statusItem(label: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? MVSTheme.success : MVSTheme.gold)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MVSTheme.muted)
        }
    }

    private var transcriptionReady: Bool {
        switch settings.transcriptionProvider {
        case .openAI: settings.hasAPIKey
        case .bailianASR: settings.hasBailianASRAPIKey
        }
    }

    private var summaryReady: Bool {
        switch settings.summaryProvider {
        case .openAI: settings.hasAPIKey
        case .deepSeek: settings.hasDeepSeekAPIKey
        case .bailianQwen: settings.hasBailianASRAPIKey
        }
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(MVSTheme.indigo)
    }

    private func analyzeURL() {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        pipeline.analyzeURL(
            value,
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
        showJobs()
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            analyzeLocal(url)
        }
    }

    private func analyzeLocal(_ url: URL) {
        pipeline.analyzeLocalFile(url, settings: settings, jobs: jobs, library: library)
        showJobs()
    }
}
