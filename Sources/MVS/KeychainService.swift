import Foundation
import Security

final class KeychainService {
    private let service = "local.mbb.mvs"

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

    func deleteAPIKey(provider: AIProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider)
        ]
        SecItemDelete(query as CFDictionary)
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
