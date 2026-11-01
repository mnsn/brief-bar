using BriefBar.Core.Tests.Copilot;
using Microsoft.Data.Sqlite;

namespace BriefBar.Core.Tests;

public sealed class SQLiteTests
{
    [Fact]
    public void ReadsEachKindOfValue()
    {
        using var folder = new TemporaryFolder();
        var path = MakeDatabase(folder: folder);
        using var connection = new SQLiteConnection(path: path);
        var rows = connection.Rows(sql: "SELECT id, name, flag, created, stamp FROM item ORDER BY id", map: row => (
            Id: row.Number(column: 0), Name: row.Text(column: 1), IdText: row.AsText(column: 0), IdAsText: row.Text(column: 0),
            Flag: row.Bool(column: 2), Created: row.Date(column: 3), Stamp: row.Date(column: 4), IsNull: row.IsNull(column: 1)));
        Assert.Equal(expected: 2, actual: rows.Count);
        Assert.Equal(expected: (1L, "one", "1", (string?)null), actual: (rows[0].Id, rows[0].Name, rows[0].IdText, rows[0].IdAsText));
        Assert.True(condition: rows[0].Flag && !rows[0].IsNull);
        Assert.Equal(expected: DateTimeOffset.FromUnixTimeSeconds(seconds: 1_792_342_807), actual: rows[0].Created);
        Assert.Equal(expected: DateTimeOffset.FromUnixTimeSeconds(seconds: 1_792_342_807), actual: rows[0].Stamp);
        Assert.True(condition: rows[1].Name is null && rows[1].IsNull && !rows[1].Flag && rows[1].Created is null);
    }

    [Fact]
    public void ReadsAClosedDatabaseImmutably()
    {
        using var folder = new TemporaryFolder();
        using var connection = new SQLiteConnection(path: MakeDatabase(folder: folder), immutable: true);
        Assert.Equal(expected: [2L], actual: connection.Rows(sql: "SELECT count(*) FROM item", map: row => row.NumberOrZero(column: 0)));
    }

    [Fact]
    public void ReportsFailures()
    {
        using var folder = new TemporaryFolder();
        Assert.Throws<SqliteException>(testCode: () => new SQLiteConnection(path: folder.Combine("missing.db")));
        Assert.False(condition: File.Exists(path: folder.Combine("missing.db")));
        using var connection = new SQLiteConnection(path: MakeDatabase(folder: folder));
        Assert.Throws<SqliteException>(testCode: () => connection.Rows(sql: "SELECT nope FROM item", map: row => row.NumberOrZero(column: 0)));
    }

    /// What a query sorts stays in memory, on every connection, rather than in a temporary file, which another program
    /// could open before SQLite deletes it. 2 is MEMORY.
    [Fact]
    public void KeepsWhatAQuerySortsInMemory()
    {
        using var folder = new TemporaryFolder();
        var path = MakeDatabase(folder: folder);
        foreach (var immutable in new[] { false, true })
        {
            using var connection = new SQLiteConnection(path: path, immutable: immutable);
            Assert.Equal(expected: [2L], actual: connection.Rows(sql: "PRAGMA temp_store", map: row => row.NumberOrZero(column: 0)));
        }
    }

    /// It never writes: the database it reads is the same, byte for byte, after it's read.
    [Fact]
    public void ChangesNothingItReads()
    {
        using var folder = new TemporaryFolder();
        var path = MakeDatabase(folder: folder);
        var before = File.ReadAllBytes(path: path);
        using (var connection = new SQLiteConnection(path: path))
        {
            connection.Rows(sql: "SELECT * FROM item ORDER BY name DESC", map: row => row.AsText(column: 1));
            Assert.Throws<SqliteException>(testCode: () => connection.Rows(sql: "DELETE FROM item", map: row => 0));
        }
        Assert.Equal(expected: before, actual: File.ReadAllBytes(path: path));
    }

    /// Every query reads the database as it was at the first: a commit by the app's writer between two of them, which can
    /// come at any moment, can't mix old and new rows into one read. The next connection reads it.
    [Fact]
    public void ReadsOneSnapshotAcrossItsQueries()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("test.db");
        using var writer = new TestDatabase(path: path, journalMode: "WAL");
        writer.Exec(statements: "CREATE TABLE item (id INTEGER); INSERT INTO item VALUES (1);");
        using (var connection = new SQLiteConnection(path: path))
        {
            Assert.Equal(expected: [1L], actual: Count(connection: connection));
            writer.Exec(statements: "INSERT INTO item VALUES (2);");
            Assert.Equal(expected: [1L], actual: Count(connection: connection));
        }
        using var next = new SQLiteConnection(path: path);
        Assert.Equal(expected: [2L], actual: Count(connection: next));
    }

    /// Writes a small database, as another app would.
    static string MakeDatabase(TemporaryFolder folder)
    {
        var path = folder.Combine("test.db");
        using var db = new TestDatabase(path: path);
        db.Exec(statements: """
            CREATE TABLE item (id INTEGER, name TEXT, flag INTEGER, created TEXT, stamp REAL);
            INSERT INTO item VALUES (1, 'one', 1, '2026-10-18T17:00:07Z', 1792342807000);
            INSERT INTO item VALUES (2, NULL, 0, NULL, NULL);
            """);
        return path;
    }

    /// How many items `connection` reads.
    static List<long> Count(SQLiteConnection connection) =>
        connection.Rows(sql: "SELECT count(*) FROM item", map: row => row.NumberOrZero(column: 0));
}
