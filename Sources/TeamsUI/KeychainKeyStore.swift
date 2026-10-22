import BriefBarCore
import Foundation
import Security
import TeamsCore

/// Keeps the key that seals the saved unread chats in your login keychain: the file in your home folder as the user
/// database names it (`UserHome`), and no other keychain, whatever the default keychain and the search list say. Any
/// program running as you can change those (`security default-keychain -s`, `security list-keychains -s`), or choose
/// them by starting BriefBar with another `HOME`; the key would then be made in a keychain that program chose, and the
/// chats saved with it, where it can read them. The item's access list trusts this app by its code signature, so macOS
/// may ask whether a build with another signature, such as each new ad-hoc build, may use it. Declined, the saved
/// chats are left alone (`UnreadCache.Load.keyUnavailable`).
struct KeychainKeyStore: KeyStore {
    var service = "com.asaf.BriefBar"
    var account = "teams-unread-chats-key"
    /// The keychain the key is looked for, added, updated and deleted in, and no other.
    var keychainPath = KeychainKeyStore.loginKeychainPath(home: UserHome.url)

    /// The login keychain in `home`, as macOS names its file.
    static func loginKeychainPath(home: URL) -> String {
        home.appendingPathComponent("Library/Keychains/login.keychain-db").path
    }

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// The item, in that keychain only: to find it, update it and delete it.
    func searchQuery() throws -> [String: Any] {
        var query = item
        query[kSecMatchSearchList as String] = [try keychain()]
        return query
    }

    /// The item to add, with the key, to that keychain.
    func addQuery(_ key: Data) throws -> [String: Any] {
        var query = item
        query[kSecUseKeychain as String] = try keychain()
        query[kSecValueData as String] = key
        query[kSecAttrLabel as String] = "BriefBar: Teams unread chats key"
        query[kSecAttrDescription as String] = "Encrypts the unread Teams chats that BriefBar keeps on this Mac"
        return query
    }

    func loadKey() throws -> Data? {
        try requireKeychain()
        var query = try searchQuery()
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
        try requireKeychain()
        var status = SecItemAdd(try addQuery(key) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(try searchQuery() as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        // Had the keychain gone meanwhile, macOS would have added the key to the default keychain instead: only a key in
        // this one counts, so no chats are sealed with one anywhere else.
        var query = try searchQuery()
        query[kSecReturnAttributes as String] = true
        guard SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess else {
            throw KeychainError(status: errSecNoSuchKeychain)
        }
    }

    func deleteKey() throws {
        try requireKeychain()
        let status = SecItemDelete(try searchQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// The keychain at `keychainPath`. Naming it reads nothing, and creates nothing if there's no file.
    private func keychain() throws -> SecKeychain {
        guard let keychain = (KeychainFile.self as any KeychainFiles.Type).open(keychainPath) else {
            throw KeychainError(status: errSecNoSuchKeychain)
        }
        return keychain
    }

    /// Fails unless that keychain is there: given one that isn't, `SecItemAdd` uses the default keychain instead, which
    /// any program running as you can choose.
    private func requireKeychain() throws {
        let status = (KeychainFile.self as any KeychainFiles.Type).status(of: try keychain())
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// Names a keychain by its file: on macOS, the only way to choose the keychain that the SecItem calls use
/// (`kSecMatchSearchList`, `kSecUseKeychain`) for a file-based keychain, such as the login keychain. These are
/// SecKeychain calls, deprecated since macOS 10.10 without a replacement for that; called through this protocol, they
/// build without a warning.
protocol KeychainFiles {
    static func open(_ path: String) -> SecKeychain?
    /// `errSecSuccess` if the keychain is there, whether it's locked or not; `errSecNoSuchKeychain` if there's no file.
    static func status(of keychain: SecKeychain) -> OSStatus
}

enum KeychainFile: KeychainFiles {
    @available(macOS, deprecated: 10.10)
    static func open(_ path: String) -> SecKeychain? {
        var keychain: SecKeychain?
        return SecKeychainOpen(path, &keychain) == errSecSuccess ? keychain : nil
    }

    @available(macOS, deprecated: 10.10)
    static func status(of keychain: SecKeychain) -> OSStatus {
        var state: SecKeychainStatus = 0
        return SecKeychainGetStatus(keychain, &state)
    }
}

struct KeychainError: Error, CustomStringConvertible {
    var status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}
