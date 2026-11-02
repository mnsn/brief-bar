using BriefBar.Core.ChromiumIndexedDB;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// The Mac's `IndexedDBFixtureTests`: reads the IndexedDB that Microsoft Edge wrote, with made-up data
/// (`Tests/Fixtures/ChromiumIndexedDB`).
public sealed class IndexedDBFixtureTests
{
    readonly IndexedDBFolder folder = new(path: Fixture.LevelDB);

    [Fact]
    public void ReadsTheCatalog()
    {
        var (catalog, read) = folder.Catalog();

        Assert.Equal(expected: new HashSet<string> { Fixture.ConversationsDatabase, Fixture.ReplyChainsDatabase }, actual: catalog.Databases.Values.ToHashSet());
        Assert.Single(collection: catalog.Stores(matches: (database, store) => database == Fixture.ConversationsDatabase && store == "conversations"));
        Assert.Equal(expected: new HashSet<string> { "conversations", "conversations-internal-data", "replychains" }, actual: catalog.ObjectStores.Values.ToHashSet());
        Assert.Equal(expected: 1, actual: read.Logs);
        Assert.Empty(collection: read.Unreadable);
        Assert.Equal(expected: 0, actual: read.CorruptLogRecords);
        Assert.Equal(expected: new FileInfo(fileName: Fixture.Log).Length, actual: read.Log?.Offset);
    }

    [Fact]
    public void ReadsEachConversationAsItIsNow()
    {
        var values = Conversations(folder: folder);
        string? Horizon(string id) => values[id].Value["properties"]?["consumptionhorizon"]?.AsString;

        Assert.Equal(
            expected: new HashSet<string> { Fixture.Avery, Fixture.Sam, Fixture.Crew, Fixture.Sync, Fixture.Big, Fixture.Wrapped, "48:notes" },
            actual: values.Keys.ToHashSet());
        // The second run read Avery's chat, and Sam sent another message.
        Assert.Equal(expected: Marker(read: 5000), actual: Horizon(id: Fixture.Avery));
        Assert.Equal(expected: Id(offset: 8000), actual: values[Fixture.Sam].Value["lastMessage"]?["id"]?.AsString);
        Assert.Equal(expected: "0;900;7", actual: Horizon(id: Fixture.Sync));
        Assert.Equal(expected: Marker(read: 100), actual: Horizon(id: Fixture.Big));
        Assert.Equal(expected: Marker(read: 300), actual: Horizon(id: Fixture.Wrapped));
        Assert.Equal(expected: new SerializedFormat(Blink: 21, V8: 16, Compressed: false), actual: values[Fixture.Avery].Format);
        Assert.True(condition: values[Fixture.Big].Format.Compressed);
        Assert.True(condition: values[Fixture.Wrapped].FromBlobFile);
        Assert.Single(collection: values.Values, predicate: value => value.FromBlobFile);
    }

    [Fact]
    public void ReadsNestedValues()
    {
        var crew = Conversations(folder: folder)[Fixture.Crew].Value;
        var nested = crew["nested"]!;

        Assert.Equal(
            expected: JSValue.FromArray(items:
            [
                JSValue.FromNumber(value: 1), JSValue.FromNumber(value: 2.5), JSValue.FromNumber(value: -3), JSValue.FromBool(value: true),
                JSValue.Null, JSValue.FromString(text: "two-byte ☃"),
            ]),
            actual: nested["list"]);
        Assert.Equal(expected: JSValue.FromDate(milliseconds: Fixture.Base), actual: nested["when"]);
        Assert.Equal(expected: JSValue.FromSet(items: [JSValue.FromString(text: "a")]), actual: nested["set"]);
        Assert.Equal(expected: JSValue.FromMap(pairs: [new JSPair(Key: JSValue.FromString(text: "k"), Value: JSValue.FromNumber(value: 1))]), actual: nested["map"]);
        Assert.Equal(expected: 40, actual: crew["members"]?.Items.Count);
    }

    [Fact]
    public void SkipsWhatItDoesntNeedInATable()
    {
        // A table of the fixture's newest writes: metadata, two object stores' records, their exists entries and more.
        using var temporary = new TemporaryFolder();
        var read = new LevelDBFolder(path: Fixture.LevelDB).Read();
        var entries = read.Latest.Values
            .OrderBy(keySelector: entry => KeyPrefix.Of(key: entry.Key)!.Value)
            .ThenBy(keySelector: entry => entry.Key, comparer: Comparer<byte[]>.Create(comparison: (a, b) => a.AsSpan().SequenceCompareTo(other: b)))
            .Select(selector: entry => new TableEntry(Key: entry.Key, Sequence: entry.Sequence, Value: entry.Value))
            .ToList();
        var leveldb = temporary.Combine("made_up.indexeddb.leveldb");
        Directory.CreateDirectory(path: leveldb);
        File.WriteAllBytes(path: Path.Combine(path1: leveldb, path2: "000009.ldb"), bytes: TableWriter.Table(entries: entries, perBlock: 4, compress: true));
        CopyFolder(from: Fixture.Blob, to: temporary.Combine("made_up.indexeddb.blob"));
        var copy = new IndexedDBFolder(path: leveldb);

        var (catalog, catalogRead) = copy.Catalog();
        Assert.Equal(expected: folder.Catalog().Catalog, actual: catalog);
        Assert.True(condition: catalogRead.BlocksSkipped > 0);
        var stores = catalog.Stores(matches: (_, store) => store == "conversations");
        var records = copy.Records(stores: stores);
        Assert.Equal(expected: 7, actual: records.Values.Count);
        Assert.True(condition: records.Read.BlocksSkipped > 10 * records.Read.BlocksRead);
        var wrapped = new IndexedDBRecordKey(Store: stores.Single(), Key: IDBKey.FromString(text: Fixture.Wrapped));
        var value = copy.Value(raw: records.Values[wrapped], key: wrapped, externalObjects: records.ExternalObjects.GetValueOrDefault(key: wrapped));
        Assert.True(condition: value.FromBlobFile);
    }

    [Fact]
    public void GoesOnReadingTheLogWhereItStopped()
    {
        var (bytes, _) = LevelDBFolder.Contents(path: Fixture.Log);
        var first = LevelDBLog.Parse(bytes: bytes[..Fixture.FirstRunLength]);
        Assert.Equal(expected: Fixture.FirstRunLength, actual: first.End);
        Assert.Equal(expected: 0, actual: first.Corrupt);

        var (rest, _) = LevelDBFolder.Contents(path: Fixture.Log, offset: first.End);
        var second = LevelDBLog.Parse(bytes: rest, fileOffset: first.End);
        Assert.Equal(expected: bytes.Length, actual: second.End);
        var records = second.Entries
            .Select(selector: entry => (Key: IndexedDBFolder.TryParse(key: entry.Key), entry.Value))
            .Where(predicate: entry => entry.Key is { Kind: IndexedDBKeyKind.Record } && entry.Key.Key?.Text is not null)
            .Select(selector: entry => (Id: entry.Key!.Key!.Text!, Written: entry.Value is not null))
            .ToList();
        Assert.Equal(expected: [Fixture.Avery, Fixture.Sam, Fixture.Channel], actual: records.Select(selector: record => record.Id));
        Assert.Equal(expected: [true, true, false], actual: records.Select(selector: record => record.Written));
    }

    /// Each conversation's value, by its ID.
    internal static Dictionary<string, IndexedDBValue> Conversations(IndexedDBFolder folder)
    {
        var (catalog, _) = folder.Catalog();
        var stores = catalog.Stores(matches: (database, store) => database == Fixture.ConversationsDatabase && store == "conversations");
        var records = folder.Records(stores: stores);
        Assert.Equal(expected: 0, actual: records.UnreadableKeys);
        return records.Values.ToDictionary(
            keySelector: pair => pair.Key.Key.Text!,
            elementSelector: pair => folder.Value(raw: pair.Value, key: pair.Key, externalObjects: records.ExternalObjects.GetValueOrDefault(key: pair.Key)));
    }

    static string Id(long offset) => (Fixture.Base + offset).ToString(provider: System.Globalization.CultureInfo.InvariantCulture);

    /// The fixture's markers: read at `read`, 900 ms after, with a client message ID 7 after.
    static string Marker(long read) => Id(offset: read) + ";" + Id(offset: read + 900) + ";" + Id(offset: read + 7);

    static void CopyFolder(string from, string to)
    {
        Directory.CreateDirectory(path: to);
        foreach (var file in Directory.EnumerateFiles(path: from, searchPattern: "*", searchOption: SearchOption.AllDirectories))
        {
            var target = Path.Combine(path1: to, path2: Path.GetRelativePath(relativeTo: from, path: file));
            Directory.CreateDirectory(path: Path.GetDirectoryName(path: target)!);
            File.Copy(sourceFileName: file, destFileName: target);
        }
    }
}
