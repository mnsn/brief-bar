import Foundation
import SQLite3
import Synchronization
import Testing
@testable import TeamsCore
@testable import NotificationCenterDB
import BriefBarCore

/// Fixed reference time for fixtures: 2026-10-18T10:00:00Z.
let referenceDate = Date(timeIntervalSince1970: 1_792_317_600)

/// The reference time plus `seconds`.
func t(_ seconds: TimeInterval) -> Date {
    referenceDate.addingTimeInterval(seconds)
}

struct TestError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

// MARK: - Made-up people and chats

/// Made-up conversations. Never put real names, messages or IDs in tests.
enum Chat {
    static let avery = "19:11111111-aaaa-4aaa-8aaa-111111111111_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
    static let sam = "19:22222222-bbbb-4bbb-8bbb-222222222222_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
    static let launchCrew = "19:0123456789abcdef0123456789abcdef@thread.v2"
    static let oldGroup = "19:fedcba98765432100123456789abcdef@thread.skype"
    static let weeklySync = "19:meeting_ZmFrZS1tZWV0aW5nLWlkLWZvci10ZXN0cw@thread.v2"
    static let channel = "19:abcdefabcdefabcdefabcdefabcdef12@thread.tacv2"
    static let userContext = "33333333-cccc-4ccc-8ccc-333333333333"
}

/// Teams message IDs are milliseconds since 1970.
func messageID(_ date: Date) -> String {
    String(Int64(date.timeIntervalSince1970 * 1_000))
}

// MARK: - Notification records

/// Builds `record.data` the way Notification Center stores Teams' notifications (structure from the
/// probe of Teams 26261 on macOS 27): a binary plist whose `req.usda` is an NSKeyedArchiver archive.
enum Record {
    static func userInfoArchive(_ userInfo: [String: Any]) -> Data {
        try! NSKeyedArchiver.archivedData(withRootObject: userInfo as NSDictionary, requiringSecureCoding: true)
    }

    static func data(
        title: String, body: String, identifier: String = UUID().uuidString, userInfo: [String: Any]?,
        date: Date, usda: Data? = nil, keyedArchive: Bool = false
    ) -> Data {
        var request: [String: Any] = [
            "titl": title, "body": body, "iden": identifier, "cate": "actions:teams",
            "dest": 7, "soun": ["nam": "default"],
        ]
        if let usda {
            request["usda"] = usda
        } else if let userInfo {
            request["usda"] = userInfoArchive(userInfo)
        }
        let record: [String: Any] = [
            "app": "com.microsoft.teams2", "date": date.timeIntervalSinceReferenceDate, "req": request,
            "srce": "com.microsoft.teams2", "styl": 1, "uuid": uuidBytes(),
        ]
        if keyedArchive {
            return try! NSKeyedArchiver.archivedData(withRootObject: record as NSDictionary, requiringSecureCoding: false)
        }
        return try! PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
    }

    static func uuidBytes() -> Data {
        withUnsafeBytes(of: UUID().uuid) { Data($0) }
    }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// A chat message's user info: the conversation, the message ID and, unless `reply` is false
    /// (as for reactions), the reply box.
    static func chatInfo(_ conversation: String, messageID: String?, reply: Bool = true) -> [String: Any] {
        var options: [String: Any] = ["actionType": "view", "userContextId": Chat.userContext]
        if let messageID { options["messageId"] = Int64(messageID)! }
        var info: [String: Any] = [
            "default_action": "view", "default_id": conversation, "default_options": json(options),
            "default_type": "chats", "deleteKey": messageID ?? "1792317600000", "source": "tmpcore_work",
        ]
        if reply {
            info["textInputsend_action"] = "send"
            info["textInputsend_type"] = "chats"
            info["textInputsend_options"] = json([
                "actionType": "quickReply", "convId": conversation, "userContextId": Chat.userContext,
            ])
        }
        return info
    }

    static func message(
        _ conversation: String, title: String, body: String, at date: Date, identifier: String = UUID().uuidString,
        messageID id: String? = nil
    ) -> Data {
        data(title: title, body: body, identifier: identifier,
             userInfo: chatInfo(conversation, messageID: id ?? messageID(date)), date: date)
    }

    static func reaction(_ conversation: String, title: String, at date: Date) -> Data {
        data(title: title, body: "", userInfo: chatInfo(conversation, messageID: messageID(date), reply: false), date: date)
    }

    static func channelPost(title: String, body: String, at date: Date) -> Data {
        let id = messageID(date)
        let info: [String: Any] = [
            "default_action": "view", "default_type": "channels", "source": "tmpcore_work", "deleteKey": id,
            "default_id": json(["channelId": Chat.channel, "replyChainId": Int64(id)!]),
            "default_options": json([
                "actionType": "view", "deepLinkId": "deep-link", "focusOnLoad": "DoNotMove",
                "messageId": Int64(id)!, "userContextId": Chat.userContext,
            ]),
        ]
        return data(title: title, body: body, userInfo: info, date: date)
    }
}

// MARK: - Files

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BriefBarTeamsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // FSEvents reports resolved paths (/private/var/…), so use that form throughout.
    return url.resolvingSymlinksInPath()
}

func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

func paths(in directory: URL) -> NotificationPaths {
    NotificationPaths(
        database: directory.appendingPathComponent("db2/db"),
        stateDirectory: directory.appendingPathComponent("state", isDirectory: true)
    )
}

// MARK: - Database

/// A stand-in for Notification Center's `db2/db` with the layout the probe found. It writes through
/// its own connection, as Notification Center does while BriefBar reads.
final class TestDatabase {
    private var handle: OpaquePointer?
    private(set) var appIDs: [String: Int64] = [:]

    static let schema = """
        CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL);
        CREATE TABLE categories (app_id INTEGER PRIMARY KEY, categories BLOB);
        CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
        CREATE TABLE delivered (app_id INTEGER PRIMARY KEY, list BLOB);
        CREATE TABLE displayed (app_id INTEGER PRIMARY KEY, list BLOB);
        CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB,
                             request_date REAL, request_last_date REAL, delivered_date REAL,
                             presented BOOL, style INTEGER, snooze_fire_date REAL);
        CREATE TABLE requests (app_id INTEGER PRIMARY KEY, list BLOB);
        """

    /// Use WAL, as Notification Center does, for tests that write while something reads.
    init(at url: URL, journalMode: String = "WAL", schema: String = TestDatabase.schema) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            throw TestError("Could not create \(url.path)")
        }
        try exec("PRAGMA journal_mode=\(journalMode);")
        try exec(schema)
    }

    deinit {
        close()
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
        }
        handle = nil
    }

    func exec(_ statements: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, statements, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw TestError(message.map { String(cString: $0) } ?? "SQLite error")
        }
    }

    @discardableResult
    func addApp(_ identifier: String, badge: Int? = nil) throws -> Int64 {
        if let id = appIDs[identifier] { return id }
        try exec("INSERT INTO app (identifier, badge) VALUES ('\(identifier)', \(badge.map(String.init) ?? "NULL"));")
        let id = sqlite3_last_insert_rowid(handle)
        appIDs[identifier] = id
        return id
    }

    func setBadge(_ badge: Int?, for identifier: String = "com.microsoft.teams2") throws {
        try exec("UPDATE app SET badge = \(badge.map(String.init) ?? "NULL") WHERE identifier = '\(identifier)';")
    }

    /// Adds a notification and returns its row ID.
    @discardableResult
    func add(_ data: Data?, delivered: Date?, app: String = "com.microsoft.teams2") throws -> Int64 {
        let appID = try addApp(app)
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO record (app_id, uuid, data, request_date, request_last_date, delivered_date, presented, style)
            VALUES (?, ?, ?, ?, ?, ?, 0, 1)
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TestError(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(statement, 1, appID)
        let uuid = Record.uuidBytes()
        _ = uuid.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
        if let data {
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
        } else {
            sqlite3_bind_null(statement, 3)
        }
        for column: Int32 in 4...6 {
            if let delivered {
                sqlite3_bind_double(statement, column, delivered.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(statement, column)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestError(String(cString: sqlite3_errmsg(handle)))
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func remove(_ recordID: Int64) throws {
        try exec("DELETE FROM record WHERE rec_id = \(recordID);")
    }
}

// MARK: - Engine

/// Collects engine publications (delivered on the engine's queue) for async assertions.
final class SnapshotCollector: Sendable {
    private let snapshots = Mutex<[EngineSnapshot]>([])

    func add(_ snapshot: EngineSnapshot) {
        snapshots.withLock { $0.append(snapshot) }
    }

    var count: Int {
        snapshots.withLock { $0.count }
    }

    /// Waits until the latest snapshot satisfies `predicate`.
    @discardableResult
    func wait(
        _ what: String, timeout: Duration = .seconds(10), until predicate: (EngineSnapshot) -> Bool
    ) async throws -> EngineSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let latest = snapshots.withLock({ $0.last }), predicate(latest) {
                return latest
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // On a busy machine a test can run again only after its deadline, though what it waits for came in time.
        if let latest = snapshots.withLock({ $0.last }), predicate(latest) { return latest }
        throw TestError("Timed out waiting for \(what); \(count) snapshots")
    }
}
