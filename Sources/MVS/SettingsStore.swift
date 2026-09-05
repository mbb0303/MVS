import Foundation
import SwiftUI

@MainActor
protocol LibraryLocationProviding {
    var vaultURL: URL { get }
    var videoRootURL: URL { get }
}

@MainActor
protocol NoteWritingSettings: LibraryLocationProviding {
    var summaryModel: String { get }
}

@MainActor
final class SettingsStore: ObservableObject, NoteWritingSettings {
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
    private let credentialLoader: @Sendable () throws -> [String: String]
    private var credentialLoadTask: Task<[String: String], Error>?
    @Published private(set) var isUpdatingCredentials = false
    private var cachedAPIKeys: [AIProvider: String] = [:]
    private var cachedTranscriptionAPIKeys: [TranscriptionProvider: String] = [:]
    private var didLoadCredentialStore = false

    init(defaults: UserDefaults = .standard, credentialLoader: @escaping @Sendable () throws -> [String: String] = { try KeychainService().loadCredentialStore() }) {
        self.credentialLoader = credentialLoader
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
        defaults.set(vaultPath, forKey: Keys.vaultPath)
        defaults.set(videoRootPath, forKey: Keys.videoRootPath)
    }

    func prepareCredentials() async {
        do {
            try await loadUnifiedCredentialStoreIfNeeded()
            refreshAPIKeyState()
            lastSettingsError = nil
        } catch {
            lastSettingsError = error.localizedDescription
        }
    }

    func retryCredentialAccess() async {
        guard !isUpdatingCredentials else { return }
        credentialLoadTask = nil
        didLoadCredentialStore = false
        await prepareCredentials()
    }

    var vaultURL: URL { URL(fileURLWithPath: vaultPath, isDirectory: true) }
    var videoRootURL: URL { URL(fileURLWithPath: videoRootPath, isDirectory: true) }

    func saveAPIKey(_ key: String, provider: AIProvider) async {
        guard !isUpdatingCredentials else { return }
        isUpdatingCredentials = true
        defer { isUpdatingCredentials = false }
        do {
            try await loadUnifiedCredentialStoreIfNeeded()
            let previousKeys = cachedAPIKeys
            let previousTranscriptionKeys = cachedTranscriptionAPIKeys
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            cachedAPIKeys[provider] = trimmed
            if provider == .openAI {
                cachedTranscriptionAPIKeys[.openAI] = trimmed
            } else if provider == .bailianQwen {
                cachedTranscriptionAPIKeys[.bailianASR] = trimmed
            }
            do {
                try await saveUnifiedCredentialStore()
            } catch {
                cachedAPIKeys = previousKeys
                cachedTranscriptionAPIKeys = previousTranscriptionKeys
                throw error
            }
            lastSettingsError = nil
            refreshAPIKeyState()
        } catch {
            lastSettingsError = error.localizedDescription
        }
    }

    func loadAPIKey(provider: AIProvider) async throws -> String {
        if let cached = cachedAPIKeys[provider], !cached.isEmpty {
            return cached
        }
        try await loadUnifiedCredentialStoreIfNeeded()
        if let cached = cachedAPIKeys[provider], !cached.isEmpty {
            return cached
        }
        guard let key = try await Task.detached(operation: { try KeychainService().loadAPIKey(provider: provider) }).value, !key.isEmpty else {
            throw MVSError.missingAPIKey(provider.displayName)
        }
        cachedAPIKeys[provider] = key
        if provider == .openAI {
            cachedTranscriptionAPIKeys[.openAI] = key
        } else if provider == .bailianQwen {
            cachedTranscriptionAPIKeys[.bailianASR] = key
        }
        try await saveUnifiedCredentialStore()
        await Task.detached { KeychainService().deleteAPIKey(provider: provider) }.value
        return key
    }

    func clearAPIKey(provider: AIProvider) async {
        guard !isUpdatingCredentials else { return }
        isUpdatingCredentials = true
        defer { isUpdatingCredentials = false }
        do {
            try await loadUnifiedCredentialStoreIfNeeded()
            let oldAPIKeys = cachedAPIKeys
            let oldTranscriptionKeys = cachedTranscriptionAPIKeys
            cachedAPIKeys[provider] = nil
            if provider == .openAI {
                cachedTranscriptionAPIKeys[.openAI] = nil
            } else if provider == .bailianQwen {
                cachedTranscriptionAPIKeys[.bailianASR] = nil
            }
            do {
                try await saveUnifiedCredentialStore()
                await Task.detached { KeychainService().deleteAPIKey(provider: provider) }.value
                lastSettingsError = nil
            } catch {
                cachedAPIKeys = oldAPIKeys
                cachedTranscriptionAPIKeys = oldTranscriptionKeys
                throw error
            }
            refreshAPIKeyState()
        } catch {
            lastSettingsError = error.localizedDescription
        }
    }

    func saveTranscriptionAPIKey(_ key: String, provider: TranscriptionProvider) async {
        await saveAPIKey(key, provider: provider == .openAI ? .openAI : .bailianQwen)
    }

    func loadTranscriptionAPIKey(provider: TranscriptionProvider) async throws -> String {
        if let cached = cachedTranscriptionAPIKeys[provider], !cached.isEmpty {
            return cached
        }
        try await loadUnifiedCredentialStoreIfNeeded()
        if let cached = cachedTranscriptionAPIKeys[provider], !cached.isEmpty {
            return cached
        }
        guard let key = try await Task.detached(operation: { try KeychainService().loadTranscriptionAPIKey(provider: provider) }).value, !key.isEmpty else {
            throw MVSError.missingAPIKey(provider.displayName)
        }
        cachedTranscriptionAPIKeys[provider] = key
        if provider == .openAI {
            cachedAPIKeys[.openAI] = key
        } else if provider == .bailianASR {
            cachedAPIKeys[.bailianQwen] = key
        }
        try await saveUnifiedCredentialStore()
        await Task.detached { KeychainService().deleteTranscriptionAPIKey(provider: provider) }.value
        return key
    }

    func clearTranscriptionAPIKey(provider: TranscriptionProvider) async {
        await clearAPIKey(provider: provider == .openAI ? .openAI : .bailianQwen)
    }

    func refreshAPIKeyState() {
        hasAPIKey = cachedAPIKeys[.openAI]?.isEmpty == false
        hasDeepSeekAPIKey = cachedAPIKeys[.deepSeek]?.isEmpty == false
        hasBailianASRAPIKey = cachedTranscriptionAPIKeys[.bailianASR]?.isEmpty == false
    }

    private func loadUnifiedCredentialStoreIfNeeded() async throws {
        guard !didLoadCredentialStore else { return }
        if credentialLoadTask == nil {
            let loader = credentialLoader
            credentialLoadTask = Task.detached(priority: .userInitiated) { try loader() }
        }
        guard let credentialLoadTask else { return }
        let values = try await credentialLoadTask.value
        guard !didLoadCredentialStore else { return }
        for provider in AIProvider.allCases {
            if let value = values[keychain.credentialKey(for: provider)], !value.isEmpty {
                cachedAPIKeys[provider] = value
            }
        }
        for provider in TranscriptionProvider.allCases {
            if let value = values[keychain.credentialKey(for: provider)], !value.isEmpty {
                cachedTranscriptionAPIKeys[provider] = value
            }
        }
        didLoadCredentialStore = true
    }

    private func saveUnifiedCredentialStore() async throws {
        var values: [String: String] = [:]
        for (provider, key) in cachedAPIKeys where !key.isEmpty {
            values[keychain.credentialKey(for: provider)] = key
        }
        for (provider, key) in cachedTranscriptionAPIKeys where !key.isEmpty {
            values[keychain.credentialKey(for: provider)] = key
        }
        let snapshot = values
        try await Task.detached { try KeychainService().saveCredentialStore(snapshot) }.value
    }

    func resetVideoRootToVaultDefault() {
        videoRootPath = vaultURL.appendingPathComponent("assets").path
    }

    func resetLibraryToAppDefault() {
        vaultPath = MVSPaths.defaultLibraryPath
        resetVideoRootToVaultDefault()
    }
}
