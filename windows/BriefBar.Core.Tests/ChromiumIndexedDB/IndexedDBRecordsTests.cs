using BriefBar.Core.ChromiumIndexedDB;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// Reading only some records of an object store keyed by arrays, as Teams' message cache is (`[conversation, reply
/// chain]`): only the blocks that may hold them, and only them.
public sealed class IndexedDBRecordsTests
{
    const long Database = 2;
    const long Store = 5;

    [Fact]
    public void ReadsOnlyTheRecordsAskedFor()
    {
        using var folder = new TemporaryFolder();
        string[] chats = ["19:aaaa@thread.v2", "19:bbbb@thread.v2", "19:cccc@thread.v2", "19:dddd@thread.v2"];
        var entries = new List<TableEntry>();
        ulong sequence = 1;
        foreach (var chat in chats)
        {
            for (var message = 0; message < 6; message++)
            {
                var key = IDBKey.FromArray(items: [IDBKey.FromString(text: chat), IDBKey.FromString(text: (1000 + message).ToString(provider: System.Globalization.CultureInfo.InvariantCulture))]);
                entries.Add(item: new TableEntry(Key: IndexedDBKeys.Record(database: Database, objectStore: Store, key: key), Sequence: sequence++, Value: V8Writer.Record(body: value => value.Whole(value: message))));
            }
        }
        // Another store's records after this one's.
        entries.Add(item: new TableEntry(Key: IndexedDBKeys.Record(database: Database, objectStore: Store + 1, key: "other"), Sequence: sequence++, Value: V8Writer.Record(body: value => value.Whole(value: 0))));
        File.WriteAllBytes(path: folder.Combine("000007.ldb"), bytes: TableWriter.Table(entries: entries, perBlock: 3));
        var indexedDB = new IndexedDBFolder(path: folder.Path);
        var wanted = new HashSet<string>(collection: [chats[1]], comparer: StringComparer.Ordinal);

        var records = indexedDB.Records(
            store: new IndexedDBStoreId(Database: Database, ObjectStore: Store),
            wanted: key => key.Items is [{ Text: { } chat }, ..] && wanted.Contains(item: chat),
            mayHoldKeys: (from, to) => wanted.Any(predicate: chat =>
                (from?.Items is not [{ Text: { } low }, ..] || string.CompareOrdinal(strA: low, strB: chat) <= 0)
                && (to?.Items is not [{ Text: { } high }, ..] || string.CompareOrdinal(strA: chat, strB: high) <= 0)));

        Assert.Equal(expected: 6, actual: records.Values.Count);
        Assert.All(collection: records.Values.Keys, action: key => Assert.Equal(expected: chats[1], actual: key.Key.Items[0].Text));
        // 25 records in 9 blocks of 3: the second chat's are in the third and fourth; the fifth starts after one of them,
        // so may hold more; the last, which ends in another store, may hold blob entries. The other five are skipped.
        Assert.Equal(expected: 4, actual: records.Read.BlocksRead);
        Assert.Equal(expected: 5, actual: records.Read.BlocksSkipped);
    }

    [Fact]
    public void OrdersKeysAsChromiumDoes()
    {
        IDBKey[] ordered =
        [
            IDBKey.MinKey,
            IDBKey.FromNumber(number: -1),
            IDBKey.FromNumber(number: 2),
            IDBKey.FromDate(milliseconds: 0),
            IDBKey.FromString(text: "A"),
            IDBKey.FromString(text: "a"),
            IDBKey.FromString(text: "ab"),
            IDBKey.FromBinary(bytes: [0]),
            IDBKey.FromArray(items: [IDBKey.FromString(text: "a")]),
            IDBKey.FromArray(items: [IDBKey.FromString(text: "a"), IDBKey.FromNumber(number: 1)]),
            IDBKey.FromArray(items: [IDBKey.FromString(text: "b")]),
        ];

        Assert.Equal(expected: ordered, actual: ordered.Reverse().Order());
        Assert.Equal(expected: IDBKey.FromArray(items: [IDBKey.FromString(text: "x")]), actual: IDBKey.FromArray(items: [IDBKey.FromString(text: "x")]));
        Assert.Equal(
            expected: IDBKey.FromArray(items: [IDBKey.FromString(text: "x")]).GetHashCode(),
            actual: IDBKey.FromArray(items: [IDBKey.FromString(text: "x")]).GetHashCode());
    }
}
