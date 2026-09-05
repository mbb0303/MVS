import AVFoundation
import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import SwiftUI

@MainActor
final class RecordingController: NSObject, ObservableObject {
    @Published private(set) var targets: [CaptureTarget] = []
    @Published var selectedTargetID: CaptureTarget.ID?
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var recordingSource: VideoSourceKind = .zoom
    var isBusy: Bool { isRecording || isStarting || isStopping }
    private var recordingError: String?
    @Published private(set) var status = "Click Refresh to load recording targets"
    @Published private(set) var lastRecordingURL: URL?
    @Published var meetingSource: VideoSourceKind = .zoom {
        didSet {
            if meetingSource != oldValue {
                includeMicrophone = meetingSource != .screenRecording
            }
        }
    }
    @Published var includeMicrophone = true
    @Published private(set) var screenPermissionGranted = false
    @Published private(set) var screenPermissionNeedsRestart = false
    @Published private(set) var microphonePermissionGranted = false
    @Published private(set) var microphonePermissionDenied = false

    private var displayMap: [String: SCDisplay] = [:]
    private var windowMap: [String: SCWindow] = [:]
    private var activeStream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingFinished = false
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var requestedScreenPermissionThisSession = false

    override init() {
        screenPermissionGranted = CGPreflightScreenCaptureAccess()
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphonePermissionGranted = microphoneStatus == .authorized
        microphonePermissionDenied = microphoneStatus == .denied || microphoneStatus == .restricted
        super.init()
    }

    func refreshTargets() async {
        guard !isBusy else { return }
        guard ensureScreenPermission() else {
            clearTargets()
            return
        }
        do {
            status = "Loading capture targets"
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            displayMap = Dictionary(uniqueKeysWithValues: content.displays.map { display in
                let id = "display-\(display.displayID)"
                return (id, display)
            })
            let eligibleWindows = content.windows
                .filter { isEligibleWindow($0) }
                .sorted { windowPriority($0) < windowPriority($1) }
            windowMap = Dictionary(uniqueKeysWithValues: eligibleWindows
                .map { window in
                    let id = "window-\(window.windowID)"
                    return (id, window)
                })

            let displayTargets = content.displays.map { display in
                CaptureTarget(id: "display-\(display.displayID)", kind: .display, name: "Display \(display.displayID) \(display.width)x\(display.height)")
            }
            let windowTargets = eligibleWindows
                .map { window in
                    let app = window.owningApplication?.applicationName ?? "Window"
                    let title = window.title?.isEmpty == false ? " - \(window.title!)" : ""
                    return CaptureTarget(id: "window-\(window.windowID)", kind: .window, name: "\(app)\(title)")
                }
            if meetingSource == .screenRecording {
                targets = displayTargets
                let validDisplayIDs = Set(displayTargets.map(\.id))
                if let selectedTargetID, validDisplayIDs.contains(selectedTargetID) {
                    self.selectedTargetID = selectedTargetID
                } else {
                    selectedTargetID = displayTargets.first?.id
                }
                status = displayTargets.isEmpty
                    ? "No displays found"
                    : "Found \(displayTargets.count) display(s); system audio will be recorded"
                return
            }

            targets = displayTargets + windowTargets
            let validIDs = Set(targets.map(\.id))
            let preferredWindowID = eligibleWindows
                .first(where: { isPreferredMeetingWindow($0) })
                .map { "window-\($0.windowID)" }
            if let preferredWindowID {
                selectedTargetID = preferredWindowID
            } else if let selectedTargetID, validIDs.contains(selectedTargetID) {
                self.selectedTargetID = selectedTargetID
            } else {
                selectedTargetID = displayTargets.first?.id ?? windowTargets.first?.id
            }
            status = targets.isEmpty
                ? "No capture targets found"
                : "Found \(displayTargets.count) display(s) and \(windowTargets.count) window(s)"
        } catch {
            clearTargets()
            screenPermissionGranted = CGPreflightScreenCaptureAccess()
            status = screenPermissionGranted
                ? "Could not load capture targets: \(error.localizedDescription)"
                : "Screen recording permission is not active. Quit and reopen MVS after enabling it."
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    func startRecording(settings: SettingsStore) async {
        guard !isBusy else { return }
        isStarting = true
        defer { isStarting = false }
        recordingSource = meetingSource
        guard #available(macOS 15.0, *) else {
            status = MVSError.recordingUnavailable.localizedDescription
            return
        }
        do {
            guard ensureScreenPermission() else { return }
            if includeMicrophone {
                guard await ensureMicrophonePermission() else { return }
            }
            guard let targetID = selectedTargetID else {
                throw MVSError.noCaptureTarget
            }
            let outputURL = try MediaProcessor().archiveRecordingURL(source: meetingSource, title: meetingSource.fallbackTitle, settings: settings)
            let filter = try contentFilter(for: targetID)
            let configuration = try streamConfiguration(for: targetID)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = outputURL
            recordingConfiguration.outputFileType = .mp4
            recordingConfiguration.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
            try stream.addRecordingOutput(output)
            activeStream = stream
            recordingOutput = output
            recordingFinished = false
            recordingError = nil
            try await stream.startCapture()
            if let recordingError { throw MVSError.processFailed(recordingError) }
            lastRecordingURL = outputURL
            isRecording = true
            status = "Recording"
        } catch {
            if let stream = activeStream { try? await stream.stopCapture() }
            activeStream = nil
            recordingOutput = nil
            isRecording = false
            status = error.localizedDescription
        }
    }

    func stopRecording() async -> URL? {
        guard isRecording, !isStopping else { return nil }
        isStopping = true
        defer {
            activeStream = nil
            recordingOutput = nil
            isRecording = false
            isStopping = false
        }
        do {
            if let stream = activeStream {
                try await stream.stopCapture()
            }
            await waitForRecordingOutputToFinish()
            if let recordingError { throw MVSError.processFailed(recordingError) }
            guard let url = lastRecordingURL,
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 }) == true else {
                throw MVSError.processFailed("No finalized recording file was produced.")
            }
            activeStream = nil
            recordingOutput = nil
            isRecording = false
            status = "Recording saved"
            return url
        } catch {
            status = error.localizedDescription
            isRecording = false
            return nil
        }
    }

    private func waitForRecordingOutputToFinish() async {
        if recordingFinished { return }
        status = "Finalizing recording"
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
            let expectedOutput = recordingOutput
            Task {
                try? await Task.sleep(for: .seconds(30))
                await MainActor.run {
                    if recordingOutput === expectedOutput, !recordingFinished {
                        recordingError = "Recording finalization timed out. The file was retained for recovery but will not be analyzed."
                        markRecordingOutputFinished()
                    }
                }
            }
        }
    }

    private func markRecordingOutputFinished() {
        recordingFinished = true
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func ensureScreenPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            screenPermissionGranted = true
            screenPermissionNeedsRestart = false
            return true
        }

        screenPermissionGranted = false
        if !requestedScreenPermissionThisSession {
            requestedScreenPermissionThisSession = true
            let granted = CGRequestScreenCaptureAccess()
            screenPermissionGranted = CGPreflightScreenCaptureAccess()
            screenPermissionNeedsRestart = granted && !screenPermissionGranted
            if screenPermissionGranted {
                return true
            }
        }

        status = screenPermissionNeedsRestart
            ? "Permission changed. Quit and reopen MVS once."
            : "Screen recording permission is required. Open Privacy Settings, enable MVS, then quit and reopen it."
        return false
    }

    private func ensureMicrophonePermission() async -> Bool {
        var authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        if authorization == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        microphonePermissionGranted = authorization == .authorized
        microphonePermissionDenied = authorization == .denied || authorization == .restricted
        guard microphonePermissionGranted else {
            status = "Microphone permission is unavailable. Turn off Microphone to record system audio only, or open Privacy Settings."
            return false
        }
        return true
    }

    private func clearTargets() {
        targets = []
        displayMap = [:]
        windowMap = [:]
        selectedTargetID = nil
    }

    private func isEligibleWindow(_ window: SCWindow) -> Bool {
        guard let application = window.owningApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              window.frame.width >= 120,
              window.frame.height >= 80 else {
            return false
        }
        return window.isOnScreen || isPreferredMeetingWindow(window)
    }

    private func isPreferredMeetingWindow(_ window: SCWindow) -> Bool {
        guard let bundleID = window.owningApplication?.bundleIdentifier.lowercased() else { return false }
        return Self.isMeetingBundleIdentifier(bundleID, source: meetingSource)
    }

    nonisolated static func isMeetingBundleIdentifier(_ bundleID: String, source: VideoSourceKind) -> Bool {
        let normalized = bundleID.lowercased()
        switch source {
        case .tencentMeeting:
            return normalized == "com.tencent.meeting" || normalized.contains("wemeet")
        case .zoom:
            return normalized == "us.zoom.xos" || normalized.hasPrefix("us.zoom")
        case .screenRecording:
            return false
        default:
            return false
        }
    }

    private func windowPriority(_ window: SCWindow) -> String {
        let preferred = isPreferredMeetingWindow(window) ? "0" : (window.isOnScreen ? "1" : "2")
        let app = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        return "\(preferred)-\(app)-\(title)"
    }

    private func contentFilter(for targetID: String) throws -> SCContentFilter {
        if let display = displayMap[targetID] {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        if let window = windowMap[targetID] {
            return SCContentFilter(desktopIndependentWindow: window)
        }
        throw MVSError.noCaptureTarget
    }

    private func streamConfiguration(for targetID: String) throws -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = includeMicrophone

        if let display = displayMap[targetID] {
            configuration.width = display.width
            configuration.height = display.height
        } else if let window = windowMap[targetID] {
            configuration.width = max(2, Int(window.frame.width) / 2 * 2)
            configuration.height = max(2, Int(window.frame.height) / 2 * 2)
        } else {
            throw MVSError.noCaptureTarget
        }
        return configuration
    }
}

extension RecordingController: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.recordingOutput === recordingOutput else { return }
            status = "Recording"
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.recordingOutput === recordingOutput else { return }
            recordingError = error.localizedDescription
            status = error.localizedDescription
            markRecordingOutputFinished()
            if !isStopping {
                if let activeStream { try? await activeStream.stopCapture() }
                isRecording = false
                activeStream = nil
                self.recordingOutput = nil
            }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.recordingOutput === recordingOutput else { return }
            status = "Recording finished"
            markRecordingOutputFinished()
        }
    }
}

extension RecordingController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.activeStream === stream else { return }
            recordingError = error.localizedDescription
            status = error.localizedDescription
            markRecordingOutputFinished()
            isRecording = false
            self.activeStream = nil
            recordingOutput = nil
        }
    }
}
