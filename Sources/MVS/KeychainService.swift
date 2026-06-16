import Foundation
import Security

final class KeychainService {
    private let service = "local.mbb.mvs"
    private let credentialsAccount = "mvs-credentials-v1"

    func saveAPIKey(_ key: String, provider: AIProvider) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider)
        ]
        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MVSError.processFailed("Could not save API key to Keychain: \(status)")
        }
    }

    func loadAPIKey(provider: AIProvider) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MVSError.processFailed("Could not read API key from Keychain: \(status)")
        }
        return String(data: data, encoding: .utf8)
    }

    func hasAPIKey(provider: AIProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func deleteAPIKey(provider: AIProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider)
        ]
        SecItemDelete(query as CFDictionary)
    }

    func loadCredentialStore() throws -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialsAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return [:]
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MVSError.processFailed("Could not read credentials from Keychain: \(status)")
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func saveCredentialStore(_ values: [String: String]) throws {
        let data = try JSONEncoder().encode(values)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialsAccount
        ]
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialsAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
            ? SecItemUpdate(query as CFDictionary, update as CFDictionary)
            : SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MVSError.processFailed("Could not save credentials to Keychain: \(status)")
        }
    }

    func hasCredentialStore() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialsAccount,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func credentialKey(for provider: AIProvider) -> String {
        "summary.\(provider.rawValue)"
    }

    func credentialKey(for provider: TranscriptionProvider) -> String {
        "transcription.\(provider.rawValue)"
    }

    private func account(for provider: AIProvider) -> String {
        switch provider {
        case .openAI: "openai-api-key"
        case .deepSeek: "deepseek-api-key"
        case .bailianQwen: "bailian-asr-api-key"
        }
    }

    func saveTranscriptionAPIKey(_ key: String, provider: TranscriptionProvider) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: transcriptionAccount(for: provider)
        ]
        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: transcriptionAccount(for: provider),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MVSError.processFailed("Could not save API key to Keychain: \(status)")
        }
    }

    func loadTranscriptionAPIKey(provider: TranscriptionProvider) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: transcriptionAccount(for: provider),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MVSError.processFailed("Could not read API key from Keychain: \(status)")
        }
        return String(data: data, encoding: .utf8)
    }

    func hasTranscriptionAPIKey(provider: TranscriptionProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: transcriptionAccount(for: provider),
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func deleteTranscriptionAPIKey(provider: TranscriptionProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: transcriptionAccount(for: provider)
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func transcriptionAccount(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .openAI: "openai-api-key"
        case .bailianASR: "bailian-asr-api-key"
        }
    }
}
