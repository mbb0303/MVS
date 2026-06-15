import AVFoundation
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

    private var displayMap: [String: SCDisplay] = [:]
    private var windowMap: [String: SCWindow] = [:]
    private var activeStream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingFinished = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func refreshTargets() async {
        do {
            let content = try await SCShareableContent.current
            displayMap = Dictionary(uniqueKeysWithValues: content.displays.map { display in
                let id = "display-\(display.displayID)"
                return (id, display)
            })
            windowMap = Dictionary(uniqueKeysWithValues: content.windows
                .filter { $0.isOnScreen && ($0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier) }
                .map { window in
                    let id = "window-\(window.windowID)"
                    return (id, window)
                })

            let displayTargets = content.displays.map { display in
                CaptureTarget(id: "display-\(display.displayID)", kind: .display, name: "Display \(display.displayID) \(display.width)x\(display.height)")
            }
            let windowTargets = content.windows
                .filter { $0.isOnScreen && ($0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier) }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
                .map { window in
                    let app = window.owningApplication?.applicationName ?? "Window"
                    let title = window.title?.isEmpty == false ? " - \(window.title!)" : ""
                    return CaptureTarget(id: "window-\(window.windowID)", kind: .window, name: "\(app)\(title)")
                }
            targets = displayTargets + windowTargets
            selectedTargetID = selectedTargetID ?? targets.first?.id
            status = targets.isEmpty ? "No capture targets found" : "Targets refreshed"
        } catch {
            status = error.localizedDescription
        }
    }

    func startRecording(settings: SettingsStore) async {
        guard !isRecording else { return }
        guard #available(macOS 15.0, *) else {
            status = MVSError.recordingUnavailable.localizedDescription
            return
        }
        do {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
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
