import Foundation
import Security

/// One generic-password item in the login Keychain, for the ChatGPT sign-in and the Claude API key.
struct KeychainItem {
    let service: String
    let account: String

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    func write(_ data: Data) {
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func delete() { SecItemDelete(base as CFDictionary) }
}
