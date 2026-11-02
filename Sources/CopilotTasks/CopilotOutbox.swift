import BriefBarCore
import CopilotCore
import Darwin
import Foundation

/// What BriefBar asks its extension in one of the Copilot app's sessions to do (`CopilotOutbox`): send that session a
/// prompt, or fork it.
public struct OutboxRequest: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Send the session the prompt, as your own message.
        case send
        /// Fork the session with the app's own fork, and say the fork's ID. It sends nothing.
        case fork
    }

    /// A lowercase UUID, which names its result.
    public let requestId: String
    /// The session whose extension takes it: a lowercase UUID.
    public let sessionId: String
    public let kind: Kind
    /// For a send; nil for a fork.
    public let prompt: String?
    public let createdAt: Date
    /// After this, no extension takes it.
    public let expiresAt: Date

    /// The longest a request waits for an extension to take it: the contract allows no longer.
    public static let lifetime: TimeInterval = 120
    /// The largest request an extension takes.
    public static let largestFile = 256 << 10

    /// Asks the session's extension to send it a prompt.
    public static func send(_ prompt: String, to sessionId: String, now: Date = Date()) -> OutboxRequest {
        OutboxRequest(sessionId: sessionId, kind: .send, prompt: prompt, now: now)
    }

    /// Asks the session's extension to fork it.
    public static func fork(_ sessionId: String, now: Date = Date()) -> OutboxRequest {
        OutboxRequest(sessionId: sessionId, kind: .fork, prompt: nil, now: now)
    }

    init(sessionId: String, kind: Kind, prompt: String?, now: Date, requestId: String = UUID().uuidString.lowercased()) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.kind = kind
        self.prompt = prompt
        // In whole seconds, so that the times it's written with are exactly its lifetime apart.
        createdAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        expiresAt = createdAt.addingTimeInterval(Self.lifetime)
    }

    /// `<sessionId>.<requestId>.json`, in `requests`.
    public var fileName: String { "\(sessionId).\(requestId).json" }

    /// It as the contract has it, version 1: only for a session's ID, with a prompt for a send and none for a fork.
    func encoded() throws -> Data {
        guard AppSessions.isSessionID(sessionId), AppSessions.isSessionID(requestId),
              (kind == .send) == (prompt != nil), prompt?.isEmpty != true,
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= Self.lifetime
        else { throw OutboxError.invalidRequest }
        var fields: [String: Any] = [
            "version": CopilotOutbox.version, "requestId": requestId, "sessionId": sessionId, "kind": kind.rawValue,
            "createdAt": CopilotOutbox.timestamp(createdAt), "expiresAt": CopilotOutbox.timestamp(expiresAt),
        ]
        if let prompt { fields["prompt"] = prompt }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
}

/// What an extension says became of a request.
public struct OutboxResult: Sendable, Equatable {
    /// Why it didn't do it.
    public enum Failure: String, Sendable, Equatable {
        /// The request's file, its JSON or a field was bad.
        case invalid
        /// The request expired before the extension took it.
        case expired
        /// The session didn't take the message.
        case sendFailed = "send_failed"
        /// The session doesn't offer the app's fork, as chats and remote sessions may not.
        case forkUnavailable = "fork_unavailable"
        /// The fork failed, or gave no session ID.
        case forkFailed = "fork_failed"
        /// A code this version of BriefBar doesn't know.
        case unknown
        /// BriefBar couldn't read what the extension said: not as the contract has it.
        case unreadable
    }

    public var requestId: String
    /// The session that took it.
    public var sessionId: String
    public var kind: OutboxRequest.Kind
    /// Nil once it's done.
    public var failure: Failure?
    /// What went wrong, in the extension's words, on one line: never the prompt.
    public var message: String?
    /// The message the session got, for a send.
    public var messageId: String?
    /// The new session, for a fork: a lowercase UUID, the app's ID for it.
    public var forkSessionId: String?
    public var finishedAt: Date?

    public init(
        requestId: String, sessionId: String, kind: OutboxRequest.Kind, failure: Failure? = nil, message: String? = nil,
        messageId: String? = nil, forkSessionId: String? = nil, finishedAt: Date? = nil
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.kind = kind
        self.failure = failure
        self.message = message
        self.messageId = messageId
        self.forkSessionId = forkSessionId
        self.finishedAt = finishedAt
    }

    public var isDone: Bool { failure == nil }

    /// The most an extension's message says.
    static let longestMessage = 300

    /// A result the extension wrote for `request`, as version 1 of the contract has it; or one that says BriefBar couldn't
    /// read it (`unreadable`), when it's for another request, or a fork's says no session that BriefBar can send to.
    init(_ data: Data, for request: OutboxRequest) {
        self.init(requestId: request.requestId, sessionId: request.sessionId, kind: request.kind, failure: .unreadable)
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              CopilotOutbox.number(fields["version"]) == Double(CopilotOutbox.version),
              fields["requestId"] as? String == request.requestId, fields["sessionId"] as? String == request.sessionId,
              fields["kind"] as? String == request.kind.rawValue,
              let ok = fields["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID()
        else { return }
        finishedAt = (fields["finishedAt"] as? String).flatMap(CopilotOutbox.date)
        guard ok.boolValue else {
            let error = fields["error"] as? [String: Any]
            failure = (error?["code"] as? String).map { Failure(rawValue: $0) ?? .unknown } ?? .unknown
            if failure == .unreadable { failure = .unknown }
            message = (error?["message"] as? String).map(Self.oneLine).flatMap { $0.isEmpty ? nil : $0 }
            return
        }
        switch request.kind {
        case .send:
            messageId = fields["messageId"] as? String
        case .fork:
            guard let fork = fields["forkSessionId"] as? String, AppSessions.isSessionID(fork), fork != request.sessionId else { return }
            forkSessionId = fork
        }
        failure = nil
    }

    static func oneLine(_ text: String) -> String {
        let line = PlainText.singleLine(text)
        return line.count > longestMessage ? String(line.prefix(longestMessage - 1)) + "…" : line
    }
}

/// BriefBar's extension, running in one of the Copilot app's sessions, as it says while it runs.
public struct OutboxListener: Sendable, Equatable {
    public var sessionId: String
    /// The extension's process.
    public var pid: Int32
    /// When the extension started, as it says: its process started no later.
    public var startedAt: Date
    /// What it does, of what this version of BriefBar knows.
    public var kinds: Set<OutboxRequest.Kind>

    public init(sessionId: String, pid: Int32, startedAt: Date, kinds: Set<OutboxRequest.Kind>) {
        self.sessionId = sessionId
        self.pid = pid
        self.startedAt = startedAt
        self.kinds = kinds
    }

    /// One as version 1 of the contract has it, for the session its file is named for.
    init?(_ data: Data, sessionId: String) {
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              CopilotOutbox.number(fields["version"]) == Double(CopilotOutbox.version),
              fields["sessionId"] as? String == sessionId,
              let pid = CopilotOutbox.number(fields["pid"]).flatMap({ Int32(exactly: $0) }), pid > 0,
              let startedAt = (fields["startedAt"] as? String).flatMap(CopilotOutbox.date),
              let kinds = fields["kinds"] as? [String]
        else { return nil }
        self.init(sessionId: sessionId, pid: pid, startedAt: startedAt, kinds: Set(kinds.compactMap(OutboxRequest.Kind.init(rawValue:))))
    }
}

public enum OutboxError: Error, Sendable, Equatable, CustomStringConvertible {
    /// One of the outbox's folders isn't a real one that only you can open, or couldn't be made: its name.
    case unsafeFolder(String)
    /// A request whose fields the contract doesn't allow.
    case invalidRequest
    /// A request too large for an extension to take.
    case tooLarge
    /// Writing it failed, with this error.
    case couldntWrite(Int32)

    public var description: String {
        switch self {
        case .unsafeFolder(let name):
            return "BriefBar's folder for the Copilot app's sessions (\(name)) isn't a folder only you can open, so BriefBar won't use it."
        case .invalidRequest: return "BriefBar can't send that to a session."
        case .tooLarge: return "The prompt is too long to send to a session."
        case .couldntWrite(let code): return "BriefBar couldn't write to its folder for the Copilot app's sessions: \(String(cString: strerror(code)))."
        }
    }
}

/// The folder BriefBar shares with its extension in the Copilot app's sessions, which the opt-in `briefbar-sessions` plugin
/// installs (version 1 of the contract, in docs/how-it-works.md): local files only. BriefBar writes requests to
/// `requests`, where an extension claims its own session's by renaming it, then writes a result to `results`; while it
/// runs, an extension says so in `listening`.
///
/// Each of its folders is a real one, yours, that only you can open (0700), and each file a regular one, yours, that only
/// you can read (0600), written whole to a name starting with `.`, then renamed into place: what isn't so is never read,
/// and a folder that isn't so is never used. Nothing below `root` is followed through a symbolic link, so nothing BriefBar
/// writes or reads here can lead elsewhere, whatever BriefBar may have access to. Reading makes nothing; a request makes
/// the folders it needs.
public struct CopilotOutbox: Sendable {
    public enum Folder: String, Sendable, CaseIterable {
        /// BriefBar's requests, which extensions claim.
        case requests
        /// Extensions' results, which BriefBar reads and removes.
        case results
        /// The extensions that run, each in its own session.
        case listening
    }

    /// The contract's version.
    public static let version = 1
    /// The largest result or listening file BriefBar reads.
    static let largestAnswer = 64 << 10
    /// How old BriefBar's requests and their results get before BriefBar removes them, as it starts another.
    public static let oldAge: TimeInterval = 3_600

    /// A folder that's trusted as it is: your home folder, or a test's temporary folder.
    public let root: URL
    /// The folders below it, down to the outbox's own, each a single name.
    public let path: [String]

    public init(root: URL, path: [String] = ["Outbox"]) {
        precondition(!path.isEmpty && path.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
        self.root = root
        self.path = path
    }

    /// `~/Library/Application Support/BriefBar/Copilot/Outbox`.
    public static let standard = CopilotOutbox(
        root: UserHome.url, path: ["Library", "Application Support", "BriefBar", "Copilot", "Outbox"]
    )

    public var url: URL {
        path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    // MARK: Requests

    /// Writes a request, for its session's extension to claim.
    public func write(_ request: OutboxRequest) throws {
        let data = try request.encoded()
        guard data.count <= OutboxRequest.largestFile else { throw OutboxError.tooLarge }
        let folder = try openFolder(.requests, create: true)
        defer { close(folder) }
        try Self.writeFile(data, named: request.fileName, in: folder)
    }

    /// Whether the request still waits for its extension: false once one claimed it, or it was withdrawn.
    public func isWaiting(_ request: OutboxRequest) -> Bool {
        guard let folder = try? openFolder(.requests, create: false) else { return false }
        defer { close(folder) }
        var info = stat()
        return fstatat(folder, request.fileName, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    /// Takes a request back before an extension claims it: true once it's withdrawn; false when it's gone already, claimed,
    /// so that its result is still to come.
    @discardableResult
    public func withdraw(_ request: OutboxRequest) -> Bool {
        guard let folder = try? openFolder(.requests, create: false) else { return false }
        defer { close(folder) }
        return unlinkat(folder, request.fileName, 0) == 0
    }

    /// The request's result, once its extension wrote it, which BriefBar then removes: nil until then. One that isn't as
    /// the contract has it says so (`OutboxResult.Failure.unreadable`).
    public func takeResult(of request: OutboxRequest) -> OutboxResult? {
        guard let folder = try? openFolder(.results, create: false) else { return nil }
        defer { close(folder) }
        let name = "\(request.requestId).json"
        let found = Self.read(name, in: folder, limit: Self.largestAnswer)
        if case .missing = found { return nil }
        unlinkat(folder, name, 0)
        guard case .data(let data) = found else {
            return OutboxResult(requestId: request.requestId, sessionId: request.sessionId, kind: request.kind, failure: .unreadable)
        }
        return OutboxResult(data, for: request)
    }

    // MARK: Listeners

    /// The extension that says it listens in the session, whether or not it still runs (`isLive`).
    public func listener(of sessionId: String) -> OutboxListener? {
        guard AppSessions.isSessionID(sessionId), let folder = try? openFolder(.listening, create: false) else { return nil }
        defer { close(folder) }
        return Self.listener(named: "\(sessionId).json", in: folder)
    }

    /// Whether the extension still runs: its process does, and started no later than the extension says it did, give or
    /// take two seconds, as `DetachedProgram.isRunning` checks a handle. Otherwise, a process that got its ID later has it.
    public static func isLive(
        _ listener: OutboxListener, isRunning: (pid_t) -> Bool = SessionLock.isRunning,
        startTime: (pid_t) -> Date? = DetachedProgram.startTime(of:)
    ) -> Bool {
        guard isRunning(listener.pid), let started = startTime(listener.pid) else { return false }
        return started <= listener.startedAt.addingTimeInterval(2)
    }

    // MARK: Cleaning up

    /// Removes BriefBar's requests, claimed or not, and their results, that are more than `age` old, as it starts a
    /// request: an extension that ended as it handled one leaves it.
    public func removeOld(now: Date = Date(), age: TimeInterval = CopilotOutbox.oldAge) {
        for kind in [Folder.requests, .results] {
            guard let folder = try? openFolder(kind, create: false) else { continue }
            defer { close(folder) }
            for name in Self.names(in: folder) {
                var info = stat()
                guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK
                else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                if now.timeIntervalSince(modified) >= age { unlinkat(folder, name, 0) }
            }
        }
    }

    /// Removes every request and result, whatever its age, as when Azure DevOps is turned off: they hold its prompts.
    /// What extensions say in `listening` stays, theirs while they run.
    public func forget() {
        removeOld(now: .distantFuture, age: 0)
    }

    // MARK: Files

    /// Opens one of the outbox's folders, or the outbox itself, without following a symbolic link below `root`: the outbox
    /// and its folders must be real ones, yours, that only you can open. With `create`, makes what's missing, only yours.
    func openFolder(_ folder: Folder?, create: Bool) throws -> Int32 {
        let names = path + (folder.map { [$0.rawValue] } ?? [])
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw OutboxError.unsafeFolder(root.lastPathComponent) }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        for (index, name) in names.enumerated() {
            var next = openat(descriptor, name, flags)
            if next < 0, errno == ENOENT, create {
                if mkdirat(descriptor, name, 0o700) == 0 {
                    next = openat(descriptor, name, flags)
                    // Only yours, whatever the umask.
                    if next >= 0, Self.isOwnFolder(next) { fchmod(next, 0o700) }
                } else if errno == EEXIST {
                    // An extension made it meanwhile: as it made it.
                    next = openat(descriptor, name, flags)
                }
            }
            close(descriptor)
            guard next >= 0 else { throw OutboxError.unsafeFolder(name) }
            // The outbox and its folders; not those it's in, such as Library.
            if index >= path.count - 1, !Self.isPrivateFolder(next) {
                close(next)
                throw OutboxError.unsafeFolder(name)
            }
            descriptor = next
        }
        return descriptor
    }

    static func isOwnFolder(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    /// A folder of yours that only you can open: mode 0700, nothing more.
    static func isPrivateFolder(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o7777 == 0o700
    }

    /// Writes a file whole, only yours to read (0600), to a name starting with `.`, then renames it into place, never over
    /// another file.
    static func writeFile(_ data: Data, named name: String, in folder: Int32) throws {
        let temporary = ".\(name).\(UUID().uuidString.lowercased())"
        let descriptor = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OutboxError.couldntWrite(errno) }
        var failure: Int32 = fchmod(descriptor, 0o600) == 0 ? 0 : errno
        if failure == 0 {
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
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if failure == 0, renameatx_np(folder, temporary, folder, name, UInt32(RENAME_EXCL)) != 0 { failure = errno }
        guard failure == 0 else {
            unlinkat(folder, temporary, 0)
            throw OutboxError.couldntWrite(failure)
        }
    }

    enum Read: Equatable {
        case missing
        /// It's there, but isn't a regular file of yours that only you can read, of at most the size allowed.
        case unsafe
        case data(Data)
    }

    /// A file in a folder, opened without following a symbolic link.
    static func read(_ name: String, in folder: Int32, limit: Int) -> Read {
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .unsafe }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600, info.st_size <= limit
        else { return .unsafe }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        while data.count <= limit {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.count <= limit ? .data(data) : .unsafe
    }

    static func listener(named name: String, in folder: Int32) -> OutboxListener? {
        guard case .data(let data) = read(name, in: folder, limit: largestAnswer) else { return nil }
        return OutboxListener(data, sessionId: String(name.dropLast(".json".count)))
    }

    /// The names in a folder, but `.` and `..`.
    static func names(in folder: Int32) -> [String] {
        let copy = dup(folder)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    // MARK: Times

    /// A JSON number, but not `true` or `false`, which Foundation reads as numbers too.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// ISO 8601, in UTC, to the second.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    /// An ISO 8601 time, with or without fractions of a second, as JavaScript's `toISOString()` writes one.
    static func date(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
