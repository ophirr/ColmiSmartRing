import Foundation
import Security

/// Lightweight Keychain wrapper for storing small string credentials.
enum KeychainHelper {

    /// Read a UTF-8 string from the Keychain.
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData  as String: true,
            kSecMatchLimit  as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Write (or overwrite) a UTF-8 string in the Keychain.
    @discardableResult
    static func write(service: String, account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Delete any existing item first to avoid errSecDuplicateItem.
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData   as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Delete a Keychain item.
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
