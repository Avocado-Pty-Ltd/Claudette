import Foundation
import Security

/// Tiny Keychain helper for secrets like the Retell API key. Uses the generic-password class
/// scoped to Claudette's bundle identifier so nothing else can read it.
enum KeychainStore {
    private static let service = "com.claudette.app"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ key: String, value: String?) -> Bool {
        // Delete then add — simpler than update, avoids stale attribute drift.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)

        guard let value, !value.isEmpty else { return true }
        var attrs = base
        attrs[kSecValueData as String] = value.data(using: .utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }
}
