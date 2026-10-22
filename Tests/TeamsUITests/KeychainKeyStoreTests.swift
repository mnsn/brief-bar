import Foundation
import Security
import Testing
@testable import TeamsUI

/// The key to Teams' saved chats is kept in your login keychain, the file in your home folder as the user database names
/// it, and looked for, added, updated and deleted only there: any program running as you can change the default keychain
/// and the search list, or start BriefBar with another `HOME`, which moves them. These name a keychain that isn't there,
/// so they never touch one, and never save a key: given a keychain that isn't there, macOS would add it to the default
/// one instead, which is why the key store makes sure it's there first.
@Suite struct KeychainKeyStoreTests {
    /// Not BriefBar's own, whatever happens.
    private let service = "com.example.briefbar-tests"

    @Test func keepsTheKeyInTheLoginKeychainOfYourHomeFolder() throws {
        let home = try #require(NSHomeDirectoryForUser(NSUserName()))
        #expect(KeychainKeyStore().keychainPath == home + "/Library/Keychains/login.keychain-db")
        #expect(KeychainKeyStore.loginKeychainPath(home: URL(fileURLWithPath: "/Users/avery", isDirectory: true))
            == "/Users/avery/Library/Keychains/login.keychain-db")
    }

    @Test func namesThatKeychainInEveryQuery() throws {
        try withTemporaryDirectory { directory in
            let pinned = directory.appendingPathComponent("Library/Keychains/login.keychain-db")
            let store = KeychainKeyStore(service: service, keychainPath: pinned.path)
            // macOS names a keychain by its real path, and the temporary folder is under /private.
            let expected = realPath(directory) + "/Library/Keychains/login.keychain-db"

            // To find the key, update it and delete it: that keychain only.
            let search = try store.searchQuery()
            let list = try #require(search[kSecMatchSearchList as String] as? [Any])
            #expect(list.map { keychainPath($0) } == [expected])
            #expect(search[kSecUseKeychain as String] == nil)

            // To add it: to that keychain.
            let add = try store.addQuery(Data(repeating: 7, count: 32))
            #expect(keychainPath(add[kSecUseKeychain as String]) == expected)
            #expect(add[kSecMatchSearchList as String] == nil)

            #expect(!FileManager.default.fileExists(atPath: pinned.path))
        }
    }

    @Test func findsAndDeletesNothingWithoutThatKeychain() throws {
        try withTemporaryDirectory { directory in
            let pinned = directory.appendingPathComponent("Library/Keychains/login.keychain-db")
            let store = KeychainKeyStore(service: service, keychainPath: pinned.path)
            #expect(status { try store.loadKey() } == errSecNoSuchKeychain)
            #expect(status { try store.deleteKey() } == errSecNoSuchKeychain)
            #expect(!FileManager.default.fileExists(atPath: pinned.path))
        }
    }

    /// What a key store call threw, or nil if it didn't.
    private func status(_ body: () throws -> Any?) -> OSStatus? {
        do {
            _ = try body()
            return nil
        } catch let error as KeychainError {
            return error.status
        } catch {
            return errSecInternalError
        }
    }
}

/// The file a keychain names. `SecKeychainGetPath` is deprecated with the rest of SecKeychain: called through this
/// protocol, it builds without a warning.
private protocol KeychainPaths {
    static func path(of keychain: AnyObject) -> String?
}

private enum KeychainPath: KeychainPaths {
    @available(macOS, deprecated: 10.10)
    static func path(of keychain: AnyObject) -> String? {
        guard CFGetTypeID(keychain) == SecKeychainGetTypeID() else { return nil }
        var length = UInt32(1_024)
        var buffer = [CChar](repeating: 0, count: 1_025)
        guard SecKeychainGetPath(unsafeDowncast(keychain, to: SecKeychain.self), &length, &buffer) == errSecSuccess else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private func keychainPath(_ value: Any?) -> String? {
    guard let value else { return nil }
    return (KeychainPath.self as any KeychainPaths.Type).path(of: value as AnyObject)
}

/// The path with every symbolic link resolved, `/private` included, which Foundation's own resolving leaves out.
private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BriefBarTeamsUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
