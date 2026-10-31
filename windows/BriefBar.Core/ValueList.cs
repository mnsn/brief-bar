using System.Collections;
using System.Runtime.CompilerServices;

namespace BriefBar.Core;

/// A read-only list that's equal to another with the same items in the same order, so that records holding one compare
/// by value, as Swift's arrays do: a session's choices, the sessions it asks for.
[CollectionBuilder(builderType: typeof(ValueListBuilder), methodName: nameof(ValueListBuilder.Create))]
public sealed class ValueList<T> : IReadOnlyList<T>, IEquatable<ValueList<T>>
{
    readonly T[] items;

    public ValueList(IEnumerable<T> items)
    {
        ArgumentNullException.ThrowIfNull(argument: items);
        this.items = [.. items];
    }

    internal static ValueList<T> Empty { get; } = new(items: []);

    public int Count => items.Length;

    public T this[int index] => items[index];

    public IEnumerator<T> GetEnumerator() => ((IEnumerable<T>)items).GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    public bool Equals(ValueList<T>? other) =>
        other is not null && (ReferenceEquals(objA: this, objB: other) || items.SequenceEqual(second: other.items));

    public override bool Equals(object? obj) => Equals(other: obj as ValueList<T>);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var item in items)
        {
            hash.Add(value: item);
        }
        return hash.ToHashCode();
    }

    public override string ToString() => "[" + string.Join(separator: ", ", values: items) + "]";
}
