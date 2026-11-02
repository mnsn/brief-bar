namespace BriefBar.Core.ChromiumIndexedDB;

/// Which databases and object stores there are, by ID. The Mac's `IndexedDBFolder.Catalog`.
public sealed class IndexedDBCatalog : IEquatable<IndexedDBCatalog>
{
    public Dictionary<long, string> Databases { get; } = [];

    public Dictionary<IndexedDBStoreId, string> ObjectStores { get; } = [];

    /// The object stores whose database's name and own name `matches` accepts.
    public HashSet<IndexedDBStoreId> Stores(Func<string, string, bool> matches)
    {
        ArgumentNullException.ThrowIfNull(argument: matches);
        return ObjectStores
            .Where(predicate: pair => Databases.TryGetValue(key: pair.Key.Database, value: out var database) && matches(arg1: database, arg2: pair.Value))
            .Select(selector: pair => pair.Key)
            .ToHashSet();
    }

    /// Takes in a write to a metadata key; returns whether it named or renamed something.
    public bool Take(IndexedDBKey key, byte[]? value)
    {
        ArgumentNullException.ThrowIfNull(argument: key);
        switch (key.Kind)
        {
            case IndexedDBKeyKind.DatabaseName when key.Name is { } name:
                if (value is null)
                {
                    return false;
                }
                long id;
                try
                {
                    id = IndexedDBKey.DatabaseId(value: value);
                }
                catch (FormatErrorException)
                {
                    return false;
                }
                var renamed = !Databases.TryGetValue(key: id, value: out var known) || known != name;
                Databases[id] = name;
                return renamed;
            case IndexedDBKeyKind.ObjectStoreName:
                var store = new IndexedDBStoreId(Database: key.Database, ObjectStore: key.ObjectStore);
                var storeName = value is null ? null : IndexedDBKey.StringValue(value: value);
                var had = ObjectStores.TryGetValue(key: store, value: out var previous);
                if (storeName is null)
                {
                    ObjectStores.Remove(key: store);
                    return had;
                }
                ObjectStores[store] = storeName;
                return !had || previous != storeName;
            default:
                return false;
        }
    }

    public bool Equals(IndexedDBCatalog? other) =>
        other is not null
        && Databases.Count == other.Databases.Count
        && Databases.All(predicate: pair => other.Databases.TryGetValue(key: pair.Key, value: out var name) && name == pair.Value)
        && ObjectStores.Count == other.ObjectStores.Count
        && ObjectStores.All(predicate: pair => other.ObjectStores.TryGetValue(key: pair.Key, value: out var name) && name == pair.Value);

    public override bool Equals(object? obj) => obj is IndexedDBCatalog other && Equals(other: other);

    public override int GetHashCode() => HashCode.Combine(value1: Databases.Count, value2: ObjectStores.Count);

    /// A copy, to change without changing this one.
    public IndexedDBCatalog Copy()
    {
        var copy = new IndexedDBCatalog();
        foreach (var (id, name) in Databases)
        {
            copy.Databases[id] = name;
        }
        foreach (var (store, name) in ObjectStores)
        {
            copy.ObjectStores[store] = name;
        }
        return copy;
    }
}
