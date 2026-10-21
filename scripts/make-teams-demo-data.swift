// Writes made-up Teams notifications in Notification Center's database layout, for `make demo`,
// `make demo-check` and the README screenshots:
//   swift scripts/make-teams-demo-data.swift build/demo/teams
// It creates <dir>/db2/db (like ~/Library/Group Containers/group.com.apple.usernoted/db2/db) and
// <dir>/state/state.json, which says BriefBar last ran 3 hours ago: notifications from before then
// count as read, and later ones as unread. Every name, message and ID here is made up.
import Foundation
import SQLite3

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/demo/teams")
let database = root.appendingPathComponent("db2/db")
let stateDirectory = root.appendingPathComponent("state")
try? FileManager.default.removeItem(at: root)
try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

let now = Date()
let lastRun = now.addingTimeInterval(-3 * 3_600)
func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

enum Chat {
    static let avery = "19:11111111-aaaa-4aaa-8aaa-111111111111_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
    static let sam = "19:22222222-bbbb-4bbb-8bbb-222222222222_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
    static let noah = "19:44444444-dddd-4ddd-8ddd-444444444444_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
    static let launchCrew = "19:0123456789abcdef0123456789abcdef@thread.v2"
    static let designReviews = "19:00112233445566778899aabbccddeeff@thread.v2"
    static let weeklySync = "19:meeting_ZGVtby1tZWV0aW5nLWlkLWZvci10ZWFtcy1wdWxzZQ@thread.v2"
    static let channel = "19:abcdefabcdefabcdefabcdefabcdef12@thread.tacv2"
    static let userContext = "33333333-cccc-4ccc-8ccc-333333333333"
}

func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

func messageID(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

/// A chat notification's user info, as Teams 26261 posts it. Reactions have no reply box.
func chatInfo(_ conversation: String, _ date: Date, reply: Bool = true) -> [String: Any] {
    var info: [String: Any] = [
        "default_action": "view", "default_id": conversation, "default_type": "chats",
        "default_options": json(["actionType": "view", "messageId": messageID(date), "userContextId": Chat.userContext]),
        "deleteKey": String(messageID(date)), "source": "tmpcore_work",
    ]
    if reply {
        info["textInputsend_action"] = "send"
        info["textInputsend_type"] = "chats"
        info["textInputsend_options"] = json(["actionType": "quickReply", "convId": conversation, "userContextId": Chat.userContext])
    }
    return info
}

func channelInfo(_ date: Date) -> [String: Any] {
    [
        "default_action": "view", "default_type": "channels", "source": "tmpcore_work", "deleteKey": String(messageID(date)),
        "default_id": json(["channelId": Chat.channel, "replyChainId": messageID(date)]),
        "default_options": json(["actionType": "view", "deepLinkId": "demo", "focusOnLoad": "DoNotMove",
                                 "messageId": messageID(date), "userContextId": Chat.userContext]),
    ]
}

struct Note {
    var app = "com.microsoft.teams2"
    var title: String
    var body: String
    var info: [String: Any]
    var date: Date
}

let notes: [Note] = [
    // Unread: after the last run.
    Note(title: "Avery Quinn", body: "Are we still on for the 3 pm review?", info: chatInfo(Chat.avery, minutesAgo(25)), date: minutesAgo(25)),
    Note(title: "Avery Quinn", body: "I moved the deck to the shared folder.", info: chatInfo(Chat.avery, minutesAgo(12)), date: minutesAgo(12)),
    Note(title: "Sam Rivera", body: "Can you look at my pull request when you get a chance?", info: chatInfo(Chat.sam, minutesAgo(40)), date: minutesAgo(40)),
    Note(title: "Launch crew & Design", body: "Jordan Lee: Staging is green 🎉", info: chatInfo(Chat.launchCrew, minutesAgo(50)), date: minutesAgo(50)),
    Note(title: "Launch crew & Design", body: "Maya Chen: I'll update the release notes.", info: chatInfo(Chat.launchCrew, minutesAgo(30)), date: minutesAgo(30)),
    Note(title: "Launch crew & Design", body: "Jordan Lee: Shipping at 5 unless someone objects.", info: chatInfo(Chat.launchCrew, minutesAgo(5)), date: minutesAgo(5)),
    Note(title: "Weekly sync", body: "Priya Patel: Notes and action items are in the chat.", info: chatInfo(Chat.weeklySync, minutesAgo(70)), date: minutesAgo(70)),
    // Read: before the last run, so they're under Recent.
    Note(title: "Noah Kim", body: "Thanks, that worked!", info: chatInfo(Chat.noah, minutesAgo(300)), date: minutesAgo(300)),
    Note(title: "Design reviews", body: "Maya Chen: New mocks are up for Thursday.", info: chatInfo(Chat.designReviews, minutesAgo(360)), date: minutesAgo(360)),
    // Not unread messages: a reaction, channel posts and a kind BriefBar doesn't know.
    Note(title: "👍 Avery Quinn reacted to your message", body: "", info: chatInfo(Chat.avery, minutesAgo(20), reply: false), date: minutesAgo(20)),
    Note(title: "Priya Patel posted a new message", body: "The Q4 planning doc is ready for comments.", info: channelInfo(minutesAgo(35)), date: minutesAgo(35)),
    Note(title: "Noah Kim replied to a conversation", body: "+1, looks good.", info: channelInfo(minutesAgo(15)), date: minutesAgo(15)),
    Note(title: "Missed call", body: "Noah Kim tried to call you", info: ["default_type": "calls", "source": "tmpcore_work"], date: minutesAgo(120)),
    // Another app's notification, which BriefBar never reads.
    Note(app: "com.apple.mail", title: "Newsletter", body: "This week in gardening", info: [:], date: minutesAgo(10)),
]

func recordData(_ note: Note) -> Data {
    let usda = try! NSKeyedArchiver.archivedData(withRootObject: note.info as NSDictionary, requiringSecureCoding: true)
    let request: [String: Any] = [
        "titl": note.title, "body": note.body, "iden": UUID().uuidString, "cate": "actions:demo", "usda": usda,
        "soun": ["nam": "default"],
    ]
    let record: [String: Any] = [
        "app": note.app, "date": note.date.timeIntervalSinceReferenceDate, "req": request, "srce": note.app, "styl": 1,
        "uuid": withUnsafeBytes(of: UUID().uuid) { Data($0) },
    ]
    return try! PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
}

var handle: OpaquePointer?
guard sqlite3_open(database.path, &handle) == SQLITE_OK else { fatalError("Can't create \(database.path)") }
func exec(_ sql: String) {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
        fatalError(message.map { String(cString: $0) } ?? "SQLite error")
    }
}
exec("""
    PRAGMA journal_mode=WAL;
    CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL);
    CREATE TABLE categories (app_id INTEGER PRIMARY KEY, categories BLOB);
    CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
    CREATE TABLE delivered (app_id INTEGER PRIMARY KEY, list BLOB);
    CREATE TABLE displayed (app_id INTEGER PRIMARY KEY, list BLOB);
    CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL,
                         request_last_date REAL, delivered_date REAL, presented BOOL, style INTEGER, snooze_fire_date REAL);
    CREATE TABLE requests (app_id INTEGER PRIMARY KEY, list BLOB);
    INSERT INTO app (app_id, identifier) VALUES (1, 'com.microsoft.teams2'), (2, 'com.apple.mail');
    """)

let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
for note in notes {
    var statement: OpaquePointer?
    let sql = """
        INSERT INTO record (app_id, uuid, data, request_date, request_last_date, delivered_date, presented, style)
        VALUES (?, ?, ?, ?, ?, ?, 0, 1)
        """
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { fatalError("Can't prepare the insert") }
    sqlite3_bind_int64(statement, 1, note.app == "com.microsoft.teams2" ? 1 : 2)
    let uuid = withUnsafeBytes(of: UUID().uuid) { Data($0) }
    _ = uuid.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
    let data = recordData(note)
    _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
    for column: Int32 in 4...6 {
        sqlite3_bind_double(statement, column, note.date.timeIntervalSinceReferenceDate)
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { fatalError("Can't insert a record") }
    sqlite3_finalize(statement)
}
sqlite3_close(handle)

let formatter = ISO8601DateFormatter()
let state = """
    {
      "firstLaunchAt" : "\(formatter.string(from: now.addingTimeInterval(-7 * 86_400)))",
      "hadAccess" : true,
      "lastRunAt" : "\(formatter.string(from: lastRun))"
    }
    """
try Data(state.utf8).write(to: stateDirectory.appendingPathComponent("state.json"))
print("Wrote \(notes.count) made-up notifications to \(database.path)")
