import Foundation
import SQLite3
import Testing
@testable import BriefBarCore

@Suite struct SQLiteTests {
    /// Writes a small database with sqlite3 itself, the way another app would.
    private func makeDatabase(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("test.db")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE item (id INTEGER, name TEXT, flag INTEGER, data BLOB, created TEXT, stamp REAL);
            INSERT INTO item VALUES (1, 'one', 1, x'0102', '2026-10-18T17:00:07Z', 1792342807000);
            INSERT INTO item VALUES (2, NULL, 0, NULL, NULL, NULL);
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func readsEachKindOfValue() throws {
        try withTemporaryDirectory { directory in
            let url = try makeDatabase(in: directory)
            let connection = try SQLiteConnection(readOnly: url)
            let rows = try connection.rows("SELECT id, name, flag, data, created, stamp FROM item ORDER BY id") { row in
                (id: row.int64(0), name: row.text(1), idText: row.string(0), idAsText: row.text(0), flag: row.bool(2),
                 data: row.blob(3), created: row.date(4), stamp: row.date(5), isNull: row.isNull(1))
            }
            #expect(rows.count == 2)
            #expect(rows[0].id == 1 && rows[0].name == "one" && rows[0].idText == "1" && rows[0].idAsText == nil)
            #expect(rows[0].flag && rows[0].data == Data([1, 2]) && !rows[0].isNull)
            #expect(rows[0].created == Date(timeIntervalSince1970: 1_792_342_807))
            #expect(rows[0].stamp == Date(timeIntervalSince1970: 1_792_342_807))
            #expect(rows[1].name == nil && rows[1].isNull && !rows[1].flag && rows[1].data == nil && rows[1].created == nil)
        }
    }

    @Test func readsAClosedDatabaseImmutably() throws {
        try withTemporaryDirectory { directory in
            let url = try makeDatabase(in: directory)
            let connection = try SQLiteConnection(readOnly: url, immutable: true)
            #expect(try connection.rows("SELECT count(*) FROM item") { $0.int(0) } == [2])
        }
    }

    @Test func reportsFailures() throws {
        try withTemporaryDirectory { directory in
            #expect(throws: SQLiteError.self) {
                try SQLiteConnection(readOnly: directory.appendingPathComponent("missing.db"))
            }
            let connection = try SQLiteConnection(readOnly: try makeDatabase(in: directory))
            #expect(throws: SQLiteError.self) { try connection.rows("SELECT nope FROM item") { $0.int(0) } }
        }
    }

    /// What a query sorts stays in memory, on every connection, rather than in a temporary file, which a program
    /// running as you could open before SQLite deletes it. 2 is MEMORY.
    @Test func keepsWhatAQuerySortsInMemory() throws {
        try withTemporaryDirectory { directory in
            let url = try makeDatabase(in: directory)
            for immutable in [false, true] {
                let connection = try SQLiteConnection(readOnly: url, immutable: immutable)
                #expect(try connection.rows("PRAGMA temp_store") { $0.int(0) } == [2], "immutable: \(immutable)")
            }
        }
    }

    /// So every connection BriefBar opens is a `SQLiteConnection`.
    @Test func opensDatabasesOnlyThroughSQLiteConnection() throws {
        #expect(try sourcesMatching(/sqlite3_open/) == ["BriefBarCore/SQLite.swift"])
    }
}
