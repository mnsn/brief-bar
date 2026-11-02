namespace BriefBar.Core;

/// Makes a `ValueList` from a collection expression, such as `["Postgres", "SQLite"]`.
public static class ValueListBuilder
{
    public static ValueList<T> Create<T>(ReadOnlySpan<T> items) => items.IsEmpty ? ValueList<T>.Empty : new ValueList<T>(items: items.ToArray());
}
