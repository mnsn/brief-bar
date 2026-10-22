import BriefBarCore
import Foundation
import NotificationCenterDB

/// The Notification Center database that Teams' chats are read from, and where BriefBar keeps Teams' state.
public struct NotificationPaths: Sendable, Equatable {
    /// Notification Center's SQLite database (`db2/db`).
    public var database: URL
    /// BriefBar's own files for Teams: when it last read, and the encrypted unread chats.
    public var stateDirectory: URL
    /// Whether `database` is this Mac's real Notification Center database, rather than a fixture or
    /// the demo data. Real chats are only ever saved with the key in the keychain.
    public var isSystemDatabase: Bool

    /// Points BriefBar at another Notification Center database, such as a fixture or the demo data.
    public static let databaseVariable = "BRIEFBAR_TEAMS_DB"
    /// Where BriefBar keeps Teams' state. Defaults to a `state` folder next to an overridden database.
    public static let stateVariable = "BRIEFBAR_TEAMS_STATE_DIR"

    public init(database: URL, stateDirectory: URL, isSystemDatabase: Bool = false) {
        self.database = database
        self.stateDirectory = stateDirectory
        self.isSystemDatabase = isSystemDatabase
    }

    public var directory: URL { database.deletingLastPathComponent() }
    public var writeAheadLog: URL { URL(fileURLWithPath: database.path + "-wal") }
    public var stateFile: URL { stateDirectory.appendingPathComponent("state.json") }
    public var unreadFile: URL { stateDirectory.appendingPathComponent("unread") }

    public static func systemDatabase(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        NotificationCenterLocation.systemDatabase(home: home)
    }

    /// Notification Center's database and BriefBar's state, or what the variables name, only while BriefBar has the
    /// permissions of the app that started it (`Attribution.environment`).
    public static func `default`(
        environment: [String: String] = Attribution.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> NotificationPaths {
        let system = systemDatabase(home: home)
        let databaseOverride = environment[databaseVariable].flatMap { $0.isEmpty ? nil : expand($0) }
        let stateOverride = environment[stateVariable].flatMap { $0.isEmpty ? nil : expand($0) }
        let database = databaseOverride ?? system
        let isSystemDatabase = isSameFile(database, system)
        let state = stateOverride
            ?? (isSystemDatabase ? nil : database.deletingLastPathComponent().appendingPathComponent("state", isDirectory: true))
            ?? home.appendingPathComponent("Library/Application Support/BriefBar/Teams", isDirectory: true)
        return NotificationPaths(database: database, stateDirectory: state, isSystemDatabase: isSystemDatabase)
    }

    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        NotificationCenterLocation.isSameFile(a, b)
    }

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
