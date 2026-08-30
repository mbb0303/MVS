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
    @Published private(set) var status = "Click Refresh to load recording targets"
    @Published private(set) var lastRecordingURL: URL?
    @Published var meetingSource: VideoSourceKind = .zoom
    @Published private(set) var screenPermissionGranted = false
    @Published private(set) var screenPermissionNeedsRestart = false

    private var displayMap: [String: SCDisplay] = [:]
    private var windowMap: [String: SCWindow] = [:]
    private var activeStream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingFinished = false
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var requestedScreenPermissionThisSession = false

    override init() {
        screenPermissionGranted = CGPreflightScreenCaptureAccess()
        super.init()
    }

    func refreshTargets() async {
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

    func startRecording(settings: SettingsStore) async {
        guard !isRecording else { return }
        guard #available(macOS 15.0, *) else {
            status = MVSError.recordingUnavailable.localizedDescription
            return
        }
        do {
            guard ensureScreenPermission() else { return }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                status = "Microphone permission is required for meeting recording."
                return
            }
            if selectedTargetID == nil {
                status = "Loading capture targets"
                await refreshTargets()
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
            try await stream.startCapture()

            activeStream = stream
            recordingOutput = output
            recordingFinished = false
            lastRecordingURL = outputURL
            isRecording = true
            status = "Recording"
        } catch {
            status = error.localizedDescription
        }
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        do {
            if let stream = activeStream {
                try await stream.stopCapture()
            }
            await waitForRecordingOutputToFinish()
            let url = lastRecordingURL
            activeStream = nil
            recordingOutput = nil
            isRecording = false
            status = "Recording saved"
            return url
        } catch {
            status = error.localizedDescription
            isRecording = false
            return lastRecordingURL
        }
    }

    private func waitForRecordingOutputToFinish() async {
        if recordingFinished { return }
        status = "Finalizing recording"
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
            Task {
                try? await Task.sleep(for: .seconds(8))
                await MainActor.run {
                    if !recordingFinished {
                        status = "Recording finalization timed out; trying saved file"
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
        configuration.captureMicrophone = true

        if let display = displayMap[targetID] {
            configuration.width = display.width
            configuration.height = display.height
        } else if let window = windowMap[targetID] {
            configuration.width = max(Int(window.frame.width), 1280)
            configuration.height = max(Int(window.frame.height), 720)
        } else {
            throw MVSError.noCaptureTarget
        }
        return configuration
    }
}

extension RecordingController: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            status = "Recording"
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            status = error.localizedDescription
            isRecording = false
            markRecordingOutputFinished()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            status = "Recording finished"
            markRecordingOutputFinished()
        }
    }
}

extension RecordingController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            status = error.localizedDescription
            isRecording = false
        }
    }
}
