using System.Globalization;
using Microsoft.Data.Sqlite;

namespace BriefBar.Core;

/// The row a query is on, read by column, each value as SQLite stored it. The Mac's `SQLiteRow`.
public sealed class SQLiteRow
{
    readonly SqliteDataReader reader;

    internal SQLiteRow(SqliteDataReader reader)
    {
        this.reader = reader;
    }

    public bool IsNull(int column) => reader.IsDBNull(ordinal: column);

    /// A TEXT value; null for any other type.
    public string? Text(int column) => reader.GetValue(ordinal: column) as string;

    /// Any value but NULL, as text: numbers as SQLite writes them.
    public string? AsText(int column) => IsNull(column: column) ? null : reader.GetString(ordinal: column);

    /// An INTEGER or REAL value, or TEXT that's an integer; null otherwise.
    public long? Number(int column) => reader.GetValue(ordinal: column) switch
    {
        long integer => integer,
        double real => (long)real,
        string text when long.TryParse(s: text.Trim(), style: NumberStyles.AllowLeadingSign, provider: CultureInfo.InvariantCulture, result: out var parsed) => parsed,
        _ => null,
    };

    /// The value as an integer, 0 for NULL, as SQLite converts it.
    public long NumberOrZero(int column) => IsNull(column: column) ? 0 : reader.GetInt64(ordinal: column);

    /// Whether the value is non-zero, as SQLite converts it.
    public bool Bool(int column) => NumberOrZero(column: column) != 0;

    /// ISO-8601 text; numeric epoch values (seconds or milliseconds) are accepted too.
    public DateTimeOffset? Date(int column) => reader.GetValue(ordinal: column) switch
    {
        long integer => FromEpoch(value: integer),
        double real => FromEpoch(value: real),
        string text => Timestamp.Parse(text: text),
        _ => null,
    };

    /// Seconds since 1970, or milliseconds for a value too large to be seconds.
    static DateTimeOffset? FromEpoch(double value)
    {
        if (!double.IsFinite(d: value))
        {
            return null;
        }
        var unitTicks = value > 100_000_000_000 ? TimeSpan.TicksPerMillisecond : TimeSpan.TicksPerSecond;
        var epoch = DateTimeOffset.UnixEpoch.UtcTicks;
        var whole = Math.Floor(d: value);
        if (whole > (DateTimeOffset.MaxValue.UtcTicks - epoch) / unitTicks || whole < (DateTimeOffset.MinValue.UtcTicks - epoch) / unitTicks)
        {
            return null;
        }
        var utcTicks = epoch + ((long)whole * unitTicks) + (long)Math.Round(a: (value - whole) * unitTicks);
        if (utcTicks < DateTimeOffset.MinValue.UtcTicks || utcTicks > DateTimeOffset.MaxValue.UtcTicks)
        {
            return null;
        }
        return new DateTimeOffset(ticks: utcTicks, offset: TimeSpan.Zero);
    }
}
