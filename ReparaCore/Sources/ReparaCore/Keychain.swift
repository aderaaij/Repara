import Foundation
import Security

/// Secret storage.
///
/// Every secret in this app lives here: the portal email and password, and one
/// API key per model provider. None of them may be baked into the bundle, a
/// plist, or source — the API keys in particular are extractable from a shipped
/// binary, which is why the user types one in once rather than the app carrying
/// it.
///
/// The provider keys are account names, not model code: `ReparaCore` still
/// knows nothing about any model API, and the calls themselves live in
/// `Repara/Intelligence/`. A key is kept per provider so switching between them
/// in Settings does not make the user find their key again.
public enum Keychain {

    public enum Key: String, Sendable, CaseIterable {
        case portalUsername = "portal-username"
        case portalPassword = "portal-password"
        /// Raw value predates the other two providers; renaming it would strand
        /// the key already in the Keychain of anyone running the app.
        case claudeAPIKey = "claude-api-key"
        case openAIAPIKey = "openai-api-key"
        case geminiAPIKey = "gemini-api-key"
    }

    public enum KeychainError: Error, CustomStringConvertible {
        case failed(OSStatus)

        public var description: String {
            switch self {
            case let .failed(status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    private static let service = "com.aderaaij.repara"

    public static func set(_ value: String?, for key: Key) throws {
        guard let value, !value.isEmpty else {
            try remove(key)
            return
        }
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The app never needs a secret while the phone is locked, and this
            // keeps the credentials out of an unencrypted device backup.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.failed(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.failed(status)
        }
    }

    public static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func remove(_ key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failed(status)
        }
    }

    public static func removeAll() throws {
        for key in Key.allCases { try remove(key) }
    }
}
