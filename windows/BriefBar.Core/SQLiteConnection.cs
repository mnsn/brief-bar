using Microsoft.Data.Sqlite;

namespace BriefBar.Core;

/// A short-lived, read-only SQLite connection, closed as it's disposed. It never changes the database's contents. Like
/// any reader next to a WAL writer, it takes brief shared locks and updates SQLite's shared-memory index (`-shm`). What a
/// query sorts stays in memory (`temp_store`), never in a temporary file. Every query reads the database as it was at the
/// first, so a commit that lands between two of them can't mix into one read. The Mac's `SQLiteConnection`.
///
/// SQLite opens files sharing reading and writing, but not deleting, so the app that owns the database can't delete or
/// rename them while it's open: keep it open only for one read.
public sealed class SQLiteConnection : IDisposable
{
    readonly SqliteConnection connection;

    /// Opens `path`, or throws `SqliteException`, as when there's no database there: it's never created. `immutable`
    /// reads the file without any locks or `-wal`/`-shm` files. Only use it while nothing can write to the file.
    public SQLiteConnection(string path, bool immutable = false)
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = immutable ? new Uri(uriString: Path.GetFullPath(path: path)).AbsoluteUri + "?immutable=1" : path,
            Mode = SqliteOpenMode.ReadOnly,
            Cache = SqliteCacheMode.Private,
            // A pooled connection would stay open once it's disposed, and keep the app's files open with it.
            Pooling = false,
            // How long a query retries while the app's writer holds the database, in seconds: the Mac's busy timeout.
            DefaultTimeout = 2,
        };
        connection = new SqliteConnection(connectionString: builder.ToString());
        try
        {
            connection.Open();
            // What a query sorts that doesn't fit in memory would otherwise go to a temporary file. It's this connection's
            // setting: nothing is written.
            using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA temp_store = MEMORY";
            command.ExecuteNonQuery();
            // One snapshot for every query: a read transaction, which takes no lock until the first query reads. It ends as
            // the connection closes, which SQLite does itself, so disposing never fails for it.
            command.CommandText = "BEGIN DEFERRED";
            command.ExecuteNonQuery();
        }
        catch (SqliteException)
        {
            connection.Dispose();
            throw;
        }
    }

    /// Each row of `sql`, mapped. Throws `SqliteException` when the query fails, as for a table that isn't there.
    public List<T> Rows<T>(string sql, Func<SQLiteRow, T> map)
    {
        ArgumentNullException.ThrowIfNull(argument: map);
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        using var reader = command.ExecuteReader();
        var row = new SQLiteRow(reader: reader);
        var result = new List<T>();
        while (reader.Read())
        {
            result.Add(item: map(arg: row));
        }
        return result;
    }

    public void Dispose() => connection.Dispose();
}
