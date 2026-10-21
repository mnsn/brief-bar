import BriefBarCore
import Foundation
import SQLite3

/// Whether BriefBar can read Notification Center's database.
public enum AccessStatus: String, Sendable, Equatable, Codable {
    case granted
    /// Privacy protection: BriefBar needs Full Disk Access.
    case denied
    /// There's no database where Notification Center keeps it.
    case missing
}

public enum DatabaseAccess {
    /// Finds out by opening the file: privacy protection only shows when you try.
    /// `FileManager.isReadableFile` checks POSIX permissions, and says yes even without access.
    public static func check(_ url: URL) -> AccessStatus {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        let error = errno
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        guard error == ENOENT || error == ENOTDIR else { return .denied }
        // Without access, macOS can hide the folder's contents too.
        let folder = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let folderError = errno
        if folder >= 0 {
            close(folder)
            return .missing
        }
        return folderError == EPERM || folderError == EACCES ? .denied : .missing
    }
}

/// The tables and columns of a database, as `PRAGMA table_info` lists them.
public struct DatabaseLayout: Sendable, Equatable, Codable {
    public var tables: [String: [String]]

    public init(tables: [String: [String]] = [:]) {
        self.tables = tables
    }

    public func has(_ table: String, _ column: String) -> Bool {
        tables[table]?.contains(column) == true
    }

    /// `table(column, …)`, one per table, sorted by name.
    public var lines: [String] {
        tables.keys.sorted().map { "\($0)(\(tables[$0, default: []].joined(separator: ", ")))" }
    }
}

/// One row of the `record` table, of one of the apps read.
public struct StoredRecord: Sendable, Equatable {
    public var recordID: Int64?
    public var uuid: Data?
    public var data: Data?
    public var deliveredDate: Date?
    public var requestDate: Date?
    public var bundleIdentifier: String

    public init(
        recordID: Int64? = nil, uuid: Data? = nil, data: Data?, deliveredDate: Date? = nil,
        requestDate: Date? = nil, bundleIdentifier: String = ""
    ) {
        self.recordID = recordID
        self.uuid = uuid
        self.data = data
        self.deliveredDate = deliveredDate
        self.requestDate = requestDate
        self.bundleIdentifier = bundleIdentifier
    }
}

/// What Notification Center has stored for the apps read.
public struct DatabaseContents: Sendable, Equatable {
    public var layout: DatabaseLayout
    /// The apps' bundle identifiers that have an entry in the `app` table.
    public var appIdentifiers: [String]
    public var records: [StoredRecord]
    /// `app.badge` for the apps, when the column exists and holds a number: the largest.
    public var badge: Int?
}

public enum NotificationDatabaseError: Error, Sendable, Equatable, CustomStringConvertible {
    case sqlite(SQLiteError)
    /// Required tables or columns are gone: Notification Center's format changed.
    case layoutChanged(missing: [String], layout: DatabaseLayout)

    public var description: String {
        switch self {
        case .sqlite(let error):
            return "Couldn't read Notification Center's database: \(error.message)"
        case .layoutChanged(let missing, _):
            return "Notification Center's database has changed: \(missing.joined(separator: ", ")) is missing"
        }
    }
}

/// Read-only access to Notification Center's database (`db2/db`). Only the rows of the apps asked for
/// are read: each source passes its own app's bundle identifiers.
public enum NotificationDatabase {
    /// Without these, nothing can be read reliably, so nothing is guessed.
    static let requiredColumns: [(table: String, column: String)] = [
        ("app", "app_id"), ("app", "identifier"), ("record", "app_id"), ("record", "data"),
    ]

    public static func load(at url: URL, bundleIdentifiers: [String]) throws -> DatabaseContents {
        do {
            return try load(from: SQLiteConnection(readOnly: url), bundleIdentifiers: bundleIdentifiers)
        } catch let error as SQLiteError where error.primaryCode == SQLITE_CANTOPEN && isClosedWALDatabase(url) {
            // A read-only connection can't recreate the write-ahead log, which SQLite removes when the
            // last writer closes the database. Without a log or journal, the file holds every committed
            // change, and a writer only changes it again through a new log, so read it as it is.
            do {
                return try load(from: SQLiteConnection(readOnly: url, immutable: true), bundleIdentifiers: bundleIdentifiers)
            } catch let fallback as SQLiteError {
                throw NotificationDatabaseError.sqlite(fallback)
            }
        } catch let error as SQLiteError {
            throw NotificationDatabaseError.sqlite(error)
        }
    }

    private static func isClosedWALDatabase(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path)
            && !fileManager.fileExists(atPath: url.path + "-wal")
            && !fileManager.fileExists(atPath: url.path + "-journal")
    }

    private static func load(from connection: SQLiteConnection, bundleIdentifiers: [String]) throws -> DatabaseContents {
        let layout = try readLayout(connection)
        let missing = requiredColumns.filter { !layout.has($0.table, $0.column) }.map { "\($0.table).\($0.column)" }
        guard missing.isEmpty else {
            throw NotificationDatabaseError.layoutChanged(missing: missing, layout: layout)
        }

        // Quoted as SQL strings: the identifiers come from code, never from the database.
        let identifiers = bundleIdentifiers.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ", ")
        let badgeColumn = layout.has("app", "badge") ? "badge" : "NULL"
        let apps = try connection.rows(
            "SELECT app_id, identifier, \(badgeColumn) FROM app WHERE identifier IN (\(identifiers))"
        ) { row in (id: row.int64(0), identifier: row.text(1) ?? "", badge: row.int64(2)) }

        let appIDs = apps.compactMap(\.id)
        guard !appIDs.isEmpty else {
            return DatabaseContents(layout: layout, appIdentifiers: [], records: [], badge: nil)
        }
        let identifierByApp = Dictionary(apps.compactMap { app in app.id.map { ($0, app.identifier) } },
                                         uniquingKeysWith: { first, _ in first })

        // Optional columns are read only if they exist; the names come from this fixed list.
        let optional = ["rec_id", "uuid", "delivered_date", "request_date"]
            .map { layout.has("record", $0) ? $0 : "NULL" }
        let sql = """
            SELECT app_id, data, \(optional.joined(separator: ", "))
            FROM record WHERE app_id IN (\(appIDs.map(String.init).joined(separator: ", ")))
            """
        let records = try connection.rows(sql) { row in
            StoredRecord(
                recordID: row.int64(2),
                uuid: row.blob(3),
                data: row.blob(1),
                deliveredDate: row.double(4).map(Date.init(timeIntervalSinceReferenceDate:)),
                requestDate: row.double(5).map(Date.init(timeIntervalSinceReferenceDate:)),
                bundleIdentifier: row.int64(0).flatMap { identifierByApp[$0] } ?? ""
            )
        }
        let badges = apps.compactMap(\.badge)
        return DatabaseContents(
            layout: layout,
            appIdentifiers: Array(Set(apps.map(\.identifier))).sorted(),
            records: records,
            badge: badges.isEmpty ? nil : Int(badges.max() ?? 0)
        )
    }

    private static func readLayout(_ connection: SQLiteConnection) throws -> DatabaseLayout {
        let tables = try connection.rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
            $0.text(0) ?? ""
        }
        var layout = DatabaseLayout()
        for table in tables where !table.isEmpty {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            layout.tables[table] = try connection.rows("PRAGMA table_info(\(quoted))") { $0.text(1) ?? "" }
        }
        return layout
    }
}
