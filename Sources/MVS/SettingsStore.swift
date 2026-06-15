import Foundation
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    @Published var vaultPath: String {
        didSet { defaults.set(vaultPath, forKey: Keys.vaultPath) }
    }
    @Published var videoRootPath: String {
        didSet { defaults.set(videoRootPath, forKey: Keys.videoRootPath) }
    }
    @Published var summaryModel: String {
        didSet { defaults.set(summaryModel, forKey: Keys.summaryModel) }
    }
    @Published var summaryProvider: AIProvider {
        didSet {
            defaults.set(summaryProvider.rawValue, forKey: Keys.summaryProvider)
            if summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || summaryModel == oldValue.defaultSummaryModel {
                summaryModel = summaryProvider.defaultSummaryModel
            }
        }
    }
    @Published var languageMode: String {
        didSet { defaults.set(languageMode, forKey: Keys.languageMode) }
    }
    @Published var enableDiarizationForMeetings: Bool {
        didSet { defaults.set(enableDiarizationForMeetings, forKey: Keys.enableDiarizationForMeetings) }
    }
    @Published var transcriptionProvider: TranscriptionProvider {
        didSet {
            defaults.set(transcriptionProvider.rawValue, forKey: Keys.transcriptionProvider)
            if transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcriptionModel == oldValue.defaultModel {
                transcriptionModel = transcriptionProvider.defaultModel
            }
        }
    }
    @Published var transcriptionModel: String {
        didSet { defaults.set(transcriptionModel, forKey: Keys.transcriptionModel) }
    }
    @Published var youtubeCookiesFile: String {
        didSet { defaults.set(youtubeCookiesFile, forKey: Keys.youtubeCookiesFile) }
    }
    @Published var youtubeCookiesBrowser: String {
        didSet { defaults.set(youtubeCookiesBrowser, forKey: Keys.youtubeCookiesBrowser) }
    }
    @Published var youtubeProxy: String {
        didSet { defaults.set(youtubeProxy, forKey: Keys.youtubeProxy) }
    }
    @Published var preferPlatformSubtitles: Bool {
        didSet { defaults.set(preferPlatformSubtitles, forKey: Keys.preferPlatformSubtitles) }
    }
    @Published var forceASRForURL: Bool {
        didSet { defaults.set(forceASRForURL, forKey: Keys.forceASRForURL) }
    }
    @Published private(set) var hasAPIKey = false
    @Published private(set) var hasDeepSeekAPIKey = false
    @Published private(set) var hasBailianASRAPIKey = false
    @Published var lastSettingsError: String?

    private enum Keys {
        static let vaultPath = "vaultPath"
        static let videoRootPath = "videoRootPath"
        static let summaryModel = "summaryModel"
        static let summaryProvider = "summaryProvider"
        static let languageMode = "languageMode"
        static let enableDiarizationForMeetings = "enableDiarizationForMeetings"
        static let transcriptionProvider = "transcriptionProvider"
        static let transcriptionModel = "transcriptionModel"
        static let youtubeCookiesFile = "youtubeCookiesFile"
        static let youtubeCookiesBrowser = "youtubeCookiesBrowser"
        static let youtubeProxy = "youtubeProxy"
        static let preferPlatformSubtitles = "preferPlatformSubtitles"
        static let forceASRForURL = "forceASRForURL"
    }

    private let defaults: UserDefaults
    private let keychain = KeychainService()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedVault = defaults.string(forKey: Keys.vaultPath)
        let vault = MVSPaths.shouldMoveLegacyDefaultPath(savedVault) ? MVSPaths.defaultLibraryPath : savedVault ?? MVSPaths.defaultLibraryPath
        self.vaultPath = vault
        let defaultAssetRoot = URL(fileURLWithPath: vault).appendingPathComponent("assets").path
        let savedVideoRoot = defaults.string(forKey: Keys.videoRootPath)
        if savedVideoRoot?.hasSuffix("/assets/videos") == true || MVSPaths.isInsideLegacyObsidianStorage(savedVideoRoot) {
            self.videoRootPath = defaultAssetRoot
        } else {
            self.videoRootPath = savedVideoRoot ?? defaultAssetRoot
        }
        let providerValue = defaults.string(forKey: Keys.summaryProvider) ?? AIProvider.deepSeek.rawValue
        let initialSummaryProvider = AIProvider(rawValue: providerValue) ?? .deepSeek
        self.summaryProvider = initialSummaryProvider
        self.summaryModel = defaults.string(forKey: Keys.summaryModel) ?? initialSummaryProvider.defaultSummaryModel
        let transcriptionProviderValue = defaults.string(forKey: Keys.transcriptionProvider) ?? TranscriptionProvider.bailianASR.rawValue
        let initialTranscriptionProvider = TranscriptionProvider(rawValue: transcriptionProviderValue) ?? .bailianASR
        self.transcriptionProvider = initialTranscriptionProvider
        self.transcriptionModel = defaults.string(forKey: Keys.transcriptionModel) ?? initialTranscriptionProvider.defaultModel
        self.youtubeCookiesFile = defaults.string(forKey: Keys.youtubeCookiesFile) ?? ""
        self.youtubeCookiesBrowser = defaults.string(forKey: Keys.youtubeCookiesBrowser) ?? ""
        self.youtubeProxy = defaults.string(forKey: Keys.youtubeProxy) ?? ""
        if defaults.object(forKey: Keys.preferPlatformSubtitles) == nil {
            self.preferPlatformSubtitles = true
        } else {
            self.preferPlatformSubtitles = defaults.bool(forKey: Keys.preferPlatformSubtitles)
        }
        if defaults.object(forKey: Keys.forceASRForURL) == nil {
            self.forceASRForURL = false
        } else {
            self.forceASRForURL = defaults.bool(forKey: Keys.forceASRForURL)
        }
        self.languageMode = defaults.string(forKey: Keys.languageMode) ?? "follow-source"
        if defaults.object(forKey: Keys.enableDiarizationForMeetings) == nil {
            self.enableDiarizationForMeetings = true
        } else {
            self.enableDiarizationForMeetings = defaults.bool(forKey: Keys.enableDiarizationForMeetings)
        }
        refreshAPIKeyState()
        defaults.set(vaultPath, forKey: Keys.vaultPath)
        defaults.set(videoRootPath, forKey: Keys.videoRootPath)
    }

    var vaultURL: URL { URL(fileURLWithPath: vaultPath, isDirectory: true) }
    var videoRootURL: URL { URL(fileURLWithPath: videoRootPath, isDirectory: true) }

    func saveAPIKey(_ key: String, provider: AIProvider) {
        do {
            try keychain.saveAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider)
            lastSettingsError = nil
            refreshAPIKeyState()
        } catch {
            lastSettingsError = error.localizedDescription
        }
    }

    func loadAPIKey(provider: AIProvider) throws -> String {
        guard let key = try keychain.loadAPIKey(provider: provider), !key.isEmpty else {
            throw MVSError.missingAPIKey(provider.displayName)
        }
        return key
    }

    func clearAPIKey(provider: AIProvider) {
        keychain.deleteAPIKey(provider: provider)
        refreshAPIKeyState()
    }

    func saveTranscriptionAPIKey(_ key: String, provider: TranscriptionProvider) {
        do {
            try keychain.saveTranscriptionAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider)
            lastSettingsError = nil
            refreshAPIKeyState()
        } catch {
            lastSettingsError = error.localizedDescription
        }
    }

    func loadTranscriptionAPIKey(provider: TranscriptionProvider) throws -> String {
        guard let key = try keychain.loadTranscriptionAPIKey(provider: provider), !key.isEmpty else {
            throw MVSError.missingAPIKey(provider.displayName)
        }
        return key
    }

    func clearTranscriptionAPIKey(provider: TranscriptionProvider) {
        keychain.deleteTranscriptionAPIKey(provider: provider)
        refreshAPIKeyState()
    }

    func refreshAPIKeyState() {
        do {
            hasAPIKey = try keychain.loadAPIKey(provider: .openAI)?.isEmpty == false
            hasDeepSeekAPIKey = try keychain.loadAPIKey(provider: .deepSeek)?.isEmpty == false
            hasBailianASRAPIKey = try keychain.loadTranscriptionAPIKey(provider: .bailianASR)?.isEmpty == false
        } catch {
            hasAPIKey = false
            hasDeepSeekAPIKey = false
            hasBailianASRAPIKey = false
            lastSettingsError = error.localizedDescription
        }
    }

    func resetVideoRootToVaultDefault() {
        videoRootPath = vaultURL.appendingPathComponent("assets").path
    }

    func resetLibraryToAppDefault() {
        vaultPath = MVSPaths.defaultLibraryPath
        resetVideoRootToVaultDefault()
    }
}
