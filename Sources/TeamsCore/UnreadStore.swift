import CryptoKit
import BriefBarCore
import Foundation
import NotificationCenterDB

/// Holds the key that seals the saved unread chats.
public protocol KeyStore: Sendable {
    /// The key, nil if there's none yet. Throws when it exists but can't be read right now
    /// (for example, a locked keychain), so the saved chats aren't thrown away.
    func loadKey() throws -> Data?
    func saveKey(_ key: Data) throws
    func deleteKey() throws
}

/// Keeps the key in memory only: saved chats last as long as the process.
public final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    public init(key: Data? = nil) {
        self.key = key
    }

    public func loadKey() throws -> Data? { lock.withLock { key } }
    public func saveKey(_ key: Data) throws { lock.withLock { self.key = key } }
    public func deleteKey() throws { lock.withLock { key = nil } }
}

/// Keeps the key in a file next to the data. Only for demo data and fixtures, where nothing is private.
public struct FileKeyStore: KeyStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func loadKey() throws -> Data? {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    public func saveKey(_ key: Data) throws {
        try SecureFile.write(key, to: url)
    }

    public func deleteKey() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// The unread chats, saved so they survive a restart after Notification Center dropped them.
/// Only unread chats are written, sealed with AES-GCM; read chats leave the file, and the file is
/// deleted when nothing is unread.
public struct UnreadCache: Sendable {
    public let url: URL
    public let keyStore: any KeyStore

    static let magic = Data("TPU1".utf8)

    private struct Payload: Codable {
        var version: Int
        var savedAt: Date
        var conversations: [CachedConversation]
    }

    public init(url: URL, keyStore: any KeyStore) {
        self.url = url
        self.keyStore = keyStore
    }

    /// The result of loading the saved chats.
    public enum Load: Sendable, Equatable {
        /// What was saved: empty when there's no file, or when it couldn't be opened with the key.
        case loaded([CachedConversation])
        /// The key exists but can't be read right now (for example, the keychain is locked, or its
        /// prompt was declined). The file is left alone, and mustn't be overwritten until it's loaded.
        case keyUnavailable

        public var conversations: [CachedConversation] {
            if case .loaded(let conversations) = self { return conversations }
            return []
        }
    }

    /// The saved chats. A file that can't be opened with the key is deleted, with the key, unless
    /// `discardingUnreadable` is false (read-only callers).
    public func load(discardingUnreadable: Bool = true) -> Load {
        guard let sealed = try? Data(contentsOf: url) else { return .loaded([]) }
        let key: Data?
        do {
            key = try keyStore.loadKey()
        } catch {
            return .keyUnavailable
        }
        guard let key, key.count == 32, sealed.starts(with: Self.magic) else {
            if discardingUnreadable { discard() }
            return .loaded([])
        }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(Self.magic.count))
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
            return .loaded(try JSONDecoder().decode(Payload.self, from: plain).conversations)
        } catch {
            if discardingUnreadable { discard() }
            return .loaded([])
        }
    }

    public func save(_ conversations: [CachedConversation], at date: Date) throws {
        guard !conversations.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let key = try existingOrNewKey()
        let plain = try JSONEncoder().encode(Payload(version: 1, savedAt: date, conversations: conversations))
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        try SecureFile.write(Self.magic + sealed, to: url)
    }

    public func discard() {
        try? FileManager.default.removeItem(at: url)
        try? keyStore.deleteKey()
    }

    private func existingOrNewKey() throws -> SymmetricKey {
        if let data = try keyStore.loadKey(), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try keyStore.saveKey(key.withUnsafeBytes { Data($0) })
        return key
    }
}

/// BriefBar's own bookkeeping, with nothing about chats in it.
public struct PulseState: Sendable, Equatable, Codable {
    public var firstLaunchAt: Date?
    /// Updated every minute while it runs, and when it quits.
    public var lastRunAt: Date?
    /// Whether it ever could read the database, so a lost permission can be explained.
    public var hadAccess: Bool

    public init(firstLaunchAt: Date? = nil, lastRunAt: Date? = nil, hadAccess: Bool = false) {
        self.firstLaunchAt = firstLaunchAt
        self.lastRunAt = lastRunAt
        self.hadAccess = hadAccess
    }
}

public struct StateStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> PulseState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PulseState.self, from: data)
    }

    public func save(_ state: PulseState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try SecureFile.write(try encoder.encode(state), to: url)
    }
}

/// Writes files only the user can read (0600), in a folder only the user can open (0700) that Time
/// Machine skips, replacing the old file atomically.
public enum SecureFile {
    public static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = folder
            try? excluded.setResourceValues(values)
        }
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        guard failure == 0, rename(temporary.path, url.path) == 0 else {
            let code = failure != 0 ? failure : errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
