import Foundation
import Security
import TeamsCore

/// Keeps the key that seals the saved unread chats in the login keychain. The item's access list
/// trusts this app by its code signature, so macOS may ask whether a build with another signature,
/// such as each new ad-hoc build, may use it. Declined, the saved chats are left alone
/// (`UnreadCache.Load.keyUnavailable`).
struct KeychainKeyStore: KeyStore {
    var service = "com.asaf.BriefBar"
    var account = "teams-unread-chats-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func loadKey() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    func saveKey(_ key: Data) throws {
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrLabel as String] = "BriefBar: Teams unread chats key"
        item[kSecAttrDescription as String] = "Encrypts the unread Teams chats that BriefBar keeps on this Mac"
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

struct KeychainError: Error, CustomStringConvertible {
    var status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}
