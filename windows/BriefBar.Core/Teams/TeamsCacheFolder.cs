using BriefBar.Core.ChromiumIndexedDB;

namespace BriefBar.Core.Teams;

/// One of Teams' IndexedDB folders as BriefBar read it: which object stores hold conversations and messages, each chat as
/// it is now, and where reading the log stopped, to read on from there. The Mac's `TeamsCacheFolder`, which keeps only
/// read markers: this keeps each chat's names and newest message too, and reads the messages of the chats it's asked for
/// from Teams' message cache, and only those. Not thread-safe: `TeamsEngine` uses it under its lock.
internal sealed class TeamsCacheFolder(string path)
{
    readonly IndexedDBFolder folder = new(path: path);
    IndexedDBCatalog catalog = new();
    /// The conversation stores, with the account each is in.
    Dictionary<IndexedDBStoreId, TeamsDatabaseName> conversationStores = [];
    /// The message cache's stores, by account.
    Dictionary<string, (IndexedDBStoreId Store, string UserId)> replyChainStores = new(comparer: StringComparer.Ordinal);
    Dictionary<IndexedDBRecordKey, TeamsConversationRead> conversations = [];
    Dictionary<IndexedDBRecordKey, IReadOnlyList<ExternalObject>> externalObjects = [];
    /// The raw values of records in a blob file: Chromium writes their blob entry after them, often in a later batch, so
    /// they're read again when it arrives.
    Dictionary<IndexedDBRecordKey, byte[]> inBlobFiles = [];
    Dictionary<string, FileStamp?> unreadableTables = new(comparer: StringComparer.Ordinal);
    int corruptLogRecords;
    int blocksRead;
    int blocksSkipped;

    public string Path => folder.Path;

    /// Where reading the log stopped.
    public LevelDBLogPosition? Log { get; private set; }

    /// The tables that couldn't be read, by path, as they were then. LevelDB writes a table where it'll stay, so one being
    /// written reads as broken until it's done.
    public IReadOnlyDictionary<string, FileStamp?> UnreadableTables => unreadableTables;

    /// Message records that couldn't be read, since the folder was last read from scratch.
    public int UnreadableMessages { get; private set; }

    /// Each chat, with the account it's in.
    public IEnumerable<(TeamsChat Chat, string Account)> Chats => conversations.Values
        .Where(predicate: conversation => conversation.Chat is not null)
        .Select(selector: conversation => (conversation.Chat!, conversation.Account!));

    public TeamsDataReport Report
    {
        get
        {
            var read = conversations.Values.Where(predicate: conversation => conversation.Unreadable is null).ToList();
            return new TeamsDataReport
            {
                Folders = 1,
                Stores = conversationStores.Count,
                Conversations = read.Count,
                Chats = read.Count(predicate: conversation => conversation.Chat is not null),
                WithMarker = read.Count(predicate: conversation => conversation.Chat?.Marker is not null),
                Formats = Tally(values: read.Select(selector: conversation => conversation.Format)),
                Unreadable = Tally(values: conversations.Values.Select(selector: conversation => conversation.Unreadable)),
                UnreadableFiles = unreadableTables.Count,
                CorruptLogRecords = corruptLogRecords,
                BlocksRead = blocksRead,
                BlocksSkipped = blocksSkipped,
            };
        }
    }

    /// Reads the folder: its catalog, then only its conversations. Throws `IOException` when the folder can't be listed.
    public void Scan()
    {
        var (newCatalog, catalogRead) = folder.Catalog();
        catalog = newCatalog;
        FindStores();
        var records = folder.Records(stores: conversationStores.Keys.ToHashSet());
        externalObjects = new Dictionary<IndexedDBRecordKey, IReadOnlyList<ExternalObject>>(dictionary: records.ExternalObjects);
        inBlobFiles = records.Values
            .Where(predicate: pair => IndexedDBFolder.IsInBlobFile(raw: pair.Value))
            .ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value);
        conversations = records.Values.ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => Read(raw: pair.Value, key: pair.Key));
        Log = records.Read.Log ?? catalogRead.Log;
        unreadableTables = catalogRead.Unreadable.Keys.Union(second: records.Read.Unreadable.Keys)
            .Select(selector: name => System.IO.Path.Combine(path1: folder.Path, path2: name))
            .ToDictionary(keySelector: table => table, elementSelector: table => FileStamp.Of(path: table), comparer: StringComparer.Ordinal);
        corruptLogRecords = records.Read.CorruptLogRecords;
        blocksRead = catalogRead.BlocksRead + records.Read.BlocksRead;
        blocksSkipped = catalogRead.BlocksSkipped + records.Read.BlocksSkipped;
        UnreadableMessages = 0;
    }

    /// Reads what LevelDB appended to the log since the last read: chats that changed, and messages that arrived in the
    /// chats `watched`, which it adds to `touched`.
    public TeamsLogRead ReadLog(IReadOnlySet<string> watched, ISet<string> touched)
    {
        ArgumentNullException.ThrowIfNull(argument: watched);
        ArgumentNullException.ThrowIfNull(argument: touched);
        if (Log is not { } log)
        {
            return TeamsLogRead.Rescan;
        }
        var newest = LevelDBFolder.NewestLog(folder: folder.Path);
        if (newest != System.IO.Path.GetFileName(path: log.Path))
        {
            return TeamsLogRead.Rescan;
        }
        byte[] bytes;
        try
        {
            (bytes, var file) = LevelDBFolder.Contents(path: log.Path, offset: log.Offset);
            if (file != log.FileId)
            {
                return TeamsLogRead.Rescan;
            }
        }
        catch (IOException)
        {
            return TeamsLogRead.Rescan;
        }
        catch (UnauthorizedAccessException)
        {
            return TeamsLogRead.Rescan;
        }
        if (bytes.Length == 0)
        {
            return TeamsLogRead.Unchanged;
        }
        var replyStores = replyChainStores.Values.Select(selector: account => account.Store).ToHashSet();
        var parsed = LevelDBLog.Parse(bytes: bytes, fileOffset: log.Offset, keep: key => KeyPrefix.Of(key: key) is { } prefix
            && (prefix.Database == 0
                || prefix.ObjectStore == 0
                || conversationStores.ContainsKey(key: new IndexedDBStoreId(Database: prefix.Database, ObjectStore: prefix.ObjectStore))
                || replyStores.Contains(item: new IndexedDBStoreId(Database: prefix.Database, ObjectStore: prefix.ObjectStore))));
        Log = log with { Offset = parsed.End };
        corruptLogRecords += parsed.Corrupt;
        var changedCatalog = catalog.Copy();
        var records = new List<(IndexedDBRecordKey Key, byte[]? Raw)>();
        var newBlobEntries = new HashSet<IndexedDBRecordKey>();
        var changed = false;
        foreach (var entry in parsed.Entries)
        {
            if (IndexedDBFolder.TryParse(key: entry.Key) is not { } key)
            {
                continue;
            }
            var store = new IndexedDBStoreId(Database: key.Database, ObjectStore: key.ObjectStore);
            switch (key.Kind)
            {
                case IndexedDBKeyKind.DatabaseName or IndexedDBKeyKind.ObjectStoreName:
                    if (changedCatalog.Take(key: key, value: entry.Value))
                    {
                        return TeamsLogRead.Rescan;
                    }
                    break;
                case IndexedDBKeyKind.Record or IndexedDBKeyKind.BlobEntry when replyStores.Contains(item: store):
                    if (ChatOf(key: key.Key) is { } chat && watched.Contains(item: chat))
                    {
                        touched.Add(item: chat);
                        changed = true;
                    }
                    break;
                case IndexedDBKeyKind.Record when conversationStores.ContainsKey(key: store):
                    records.Add(item: (new IndexedDBRecordKey(Store: store, Key: key.Key!), entry.Value));
                    break;
                case IndexedDBKeyKind.BlobEntry when conversationStores.ContainsKey(key: store):
                    var record = new IndexedDBRecordKey(Store: store, Key: key.Key!);
                    if (ExternalObjectsOf(value: entry.Value) is { } objects)
                    {
                        externalObjects[record] = objects;
                    }
                    else
                    {
                        externalObjects.Remove(key: record);
                    }
                    newBlobEntries.Add(item: record);
                    break;
                default:
                    break;
            }
        }
        // Each record as it is now, with its blob entry as it is now: those come later than their record.
        foreach (var (record, raw) in records)
        {
            changed |= Take(record: record, raw: raw);
            newBlobEntries.Remove(item: record);
        }
        foreach (var record in newBlobEntries)
        {
            if (inBlobFiles.TryGetValue(key: record, value: out var raw))
            {
                changed |= Take(record: record, raw: raw);
            }
        }
        return changed ? TeamsLogRead.Changed : TeamsLogRead.Unchanged;
    }

    /// The messages Teams' message cache has of the chats `chats`, by chat, oldest first; a chat it has none of isn't in
    /// it. Reads only the blocks that may hold them.
    public Dictionary<string, List<TeamsMessage>> Messages(IReadOnlyCollection<string> chats)
    {
        ArgumentNullException.ThrowIfNull(argument: chats);
        var found = new Dictionary<string, List<TeamsMessage>>(comparer: StringComparer.Ordinal);
        var accounts = conversations.Values
            .Where(predicate: conversation => conversation.Chat is not null && chats.Contains(value: conversation.Chat.Id))
            .GroupBy(keySelector: conversation => conversation.Account!, comparer: StringComparer.Ordinal);
        foreach (var account in accounts)
        {
            if (!replyChainStores.TryGetValue(key: account.Key, value: out var replyChains))
            {
                continue;
            }
            var wanted = account.Select(selector: conversation => conversation.Chat!.Id).ToHashSet(comparer: StringComparer.Ordinal);
            var records = folder.Records(
                store: replyChains.Store,
                wanted: key => ChatOf(key: key) is { } chat && wanted.Contains(item: chat),
                mayHoldKeys: (from, to) => wanted.Any(predicate: chat =>
                    (ChatOf(key: from) is not { } low || string.CompareOrdinal(strA: low, strB: chat) <= 0)
                    && (ChatOf(key: to) is not { } high || string.CompareOrdinal(strA: chat, strB: high) <= 0)));
            foreach (var (key, raw) in records.Values)
            {
                try
                {
                    var value = folder.Value(raw: raw, key: key, externalObjects: records.ExternalObjects.GetValueOrDefault(key: key));
                    foreach (var message in TeamsRecords.Messages(value: value.Value, userId: replyChains.UserId))
                    {
                        if (!wanted.Contains(item: message.ConversationId))
                        {
                            continue;
                        }
                        if (!found.TryGetValue(key: message.ConversationId, value: out var list))
                        {
                            found[message.ConversationId] = list = [];
                        }
                        list.Add(item: message);
                    }
                }
                catch (FormatErrorException)
                {
                    UnreadableMessages += 1;
                }
            }
        }
        foreach (var list in found.Values)
        {
            list.Sort(comparison: (a, b) => a.Id.CompareTo(value: b.Id));
        }
        return found;
    }

    /// The chat a message cache key names: its first part.
    static string? ChatOf(IDBKey? key) => key?.Items is [{ Type: IDBKeyType.Text, Text: { } chat }, ..] ? chat : null;

    static IReadOnlyList<ExternalObject>? ExternalObjectsOf(byte[]? value)
    {
        if (value is null)
        {
            return null;
        }
        try
        {
            return IndexedDBKey.ExternalObjects(value: value);
        }
        catch (FormatErrorException)
        {
            return null;
        }
    }

    static Dictionary<string, int> Tally(IEnumerable<string?> values) => values
        .OfType<string>()
        .GroupBy(keySelector: value => value, comparer: StringComparer.Ordinal)
        .ToDictionary(keySelector: group => group.Key, elementSelector: group => group.Count(), comparer: StringComparer.Ordinal);

    /// Which object stores hold conversations, and which hold each account's messages.
    void FindStores()
    {
        conversationStores = [];
        replyChainStores = new Dictionary<string, (IndexedDBStoreId Store, string UserId)>(comparer: StringComparer.Ordinal);
        foreach (var (store, name) in catalog.ObjectStores)
        {
            if (!catalog.Databases.TryGetValue(key: store.Database, value: out var database) || TeamsDatabaseName.Parse(name: database) is not { } parsed)
            {
                continue;
            }
            if (parsed.Manager == TeamsDatabaseName.Conversations && name == "conversations")
            {
                conversationStores[store] = parsed;
            }
            else if (parsed.Manager == TeamsDatabaseName.ReplyChains && name == "replychains-2")
            {
                replyChainStores[parsed.Account] = (store, parsed.UserId);
            }
        }
    }

    /// Takes in a record's raw value as it is now (null once it's deleted); returns whether its chat changed.
    bool Take(IndexedDBRecordKey record, byte[]? raw)
    {
        if (raw is not null && IndexedDBFolder.IsInBlobFile(raw: raw))
        {
            inBlobFiles[record] = raw;
        }
        else
        {
            inBlobFiles.Remove(key: record);
        }
        var previous = conversations.GetValueOrDefault(key: record);
        if (raw is null)
        {
            return conversations.Remove(key: record) && previous?.Chat is not null;
        }
        var conversation = Read(raw: raw, key: record);
        conversations[record] = conversation;
        return !Equals(objA: previous, objB: conversation);
    }

    /// The conversation a record holds.
    TeamsConversationRead Read(byte[] raw, IndexedDBRecordKey key)
    {
        var account = conversationStores[key.Store];
        try
        {
            var value = folder.Value(raw: raw, key: key, externalObjects: externalObjects.GetValueOrDefault(key: key));
            return new TeamsConversationRead(
                Chat: TeamsRecords.Chat(value: value.Value, recordKey: key.Key.Text, userId: account.UserId),
                Account: account.Account,
                Format: value.Format + (value.FromBlobFile ? ", from a blob file" : string.Empty),
                Unreadable: null);
        }
        catch (FormatErrorException error)
        {
            return new TeamsConversationRead(Chat: null, Account: account.Account, Format: null, Unreadable: error.Error.ToString());
        }
    }
}
