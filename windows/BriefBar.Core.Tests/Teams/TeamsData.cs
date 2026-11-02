using System.Globalization;
using BriefBar.Core.ChromiumIndexedDB;
using BriefBar.Core.Teams;
using BriefBar.Core.Tests.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.Teams;

/// Teams' data, made up, laid out as the new Teams app keeps its own (`EBWebView\WV2Profile_tfw\IndexedDB`): a copy of the
/// IndexedDB that Microsoft Edge wrote (`Tests/Fixtures/ChromiumIndexedDB`), whose second run read Avery's chat, added a
/// message to Sam's and deleted the channel; or Teams' databases as these tests write them, with its message cache too.
/// The Mac's test support's `TeamsData`.
internal static class TeamsData
{
    public const string FolderName = "http_teams.localhost_8766.indexeddb.leveldb";
    public const string LogName = "000003.log";

    /// Where the fixture's batch with the chat that's in a blob file starts, and where the later batch with its blob
    /// entry does.
    public const int WrappedRecord = 37_545;
    public const int WrappedBlobEntry = 38_436;

    public const long ConversationsDatabase = 1;
    public const long ReplyChainsDatabase = 2;
    public const long Store = 1;

    /// Everyone else's made-up user ID: who sent a message matters only as far as whether it was you.
    public const string SomeoneElse = "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa";

    /// A copy of the fixture laid out as Teams keeps its own, with only the first `logLength` bytes of its log if given.
    /// Returns where it is, and its log.
    public static (TeamsCacheLocation Location, string Log) Copy(string folder, int? logLength = null)
    {
        var indexedDB = IndexedDBFolder(folder: folder);
        CopyFolder(from: Fixture.LevelDB, to: Path.Combine(path1: indexedDB, path2: FolderName));
        CopyFolder(from: Fixture.Blob, to: Path.Combine(path1: indexedDB, path2: "http_teams.localhost_8766.indexeddb.blob"));
        var log = Path.Combine(path1: indexedDB, path2: FolderName, path3: LogName);
        if (logLength is { } length)
        {
            File.WriteAllBytes(path: log, bytes: File.ReadAllBytes(path: log)[..length]);
        }
        return (Location(folder: folder), log);
    }

    /// The fixture's log after the first run's writes.
    public static byte[] SecondRun() => File.ReadAllBytes(path: Fixture.Log)[Fixture.FirstRunLength..];

    /// Teams' databases as these tests write them: one log, whose first batch names the databases and object stores, then
    /// a batch for each conversation and reply chain. Returns where it is, and its log.
    public static (TeamsCacheLocation Location, string Log) Write(string folder, IEnumerable<MadeUpChat> chats, IEnumerable<MadeUpReplyChain> replyChains)
    {
        var leveldb = Path.Combine(path1: IndexedDBFolder(folder: folder), path2: FolderName);
        Directory.CreateDirectory(path: leveldb);
        var log = new LogWriter();
        ulong sequence = 1;
        log.Add(batch: LogWriter.Batch(
            sequence: sequence++,
            (IndexedDBKeys.DatabaseName(name: Fixture.ConversationsDatabase), IndexedDBKeys.DatabaseId(id: ConversationsDatabase)),
            (IndexedDBKeys.ObjectStoreName(database: ConversationsDatabase, objectStore: Store), IndexedDBKeys.Name(name: "conversations")),
            (IndexedDBKeys.DatabaseName(name: Fixture.ReplyChainsDatabase), IndexedDBKeys.DatabaseId(id: ReplyChainsDatabase)),
            (IndexedDBKeys.ObjectStoreName(database: ReplyChainsDatabase, objectStore: Store), IndexedDBKeys.Name(name: "replychains-2"))));
        foreach (var chat in chats)
        {
            log.Add(batch: Batch(sequence: sequence++, chat: chat));
        }
        foreach (var replyChain in replyChains)
        {
            log.Add(batch: Batch(sequence: sequence++, replyChain: replyChain));
        }
        var path = Path.Combine(path1: leveldb, path2: LogName);
        File.WriteAllBytes(path: path, bytes: log.Bytes);
        return (Location(folder: folder), path);
    }

    /// Appends `batches` to the log at `path`, as LevelDB does, after what's there: the log's blocks continue where its
    /// bytes end.
    public static void Append(string path, params byte[][] batches)
    {
        var existing = File.ReadAllBytes(path: path);
        var log = new LogWriter();
        // LevelDB's blocks are counted from the log's start: pad a writer to where the log ends, then keep what it adds.
        log.Pad(count: existing.Length);
        foreach (var batch in batches)
        {
            log.Add(batch: batch);
        }
        AppendBytes(path: path, bytes: log.Bytes[existing.Length..]);
    }

    public static void AppendBytes(string path, byte[] bytes)
    {
        using var file = new FileStream(path: path, mode: FileMode.Append, access: FileAccess.Write, share: FileShare.ReadWrite | FileShare.Delete);
        file.Write(buffer: bytes);
    }

    /// A batch that writes `chat`'s conversation record.
    public static byte[] Batch(ulong sequence, MadeUpChat chat) => LogWriter.Batch(
        sequence: sequence,
        (IndexedDBKeys.Record(database: ConversationsDatabase, objectStore: Store, key: chat.Id), V8Writer.Record(body: chat.Write)));

    /// A batch that writes `replyChain`'s record in the message cache.
    public static byte[] Batch(ulong sequence, MadeUpReplyChain replyChain) => LogWriter.Batch(
        sequence: sequence,
        (IndexedDBKeys.Record(database: ReplyChainsDatabase, objectStore: Store, key: replyChain.Key), V8Writer.Record(body: replyChain.Write)));

    /// A batch that writes `replyChain`'s record as Chromium writes one too large for the database: in the blob file
    /// `blobNumber`, which `WriteBlobFile` writes; with its blob entry, which names that file, unless `withBlobEntry` is
    /// false, as when Chromium writes it in a later batch (`BlobEntryBatch`).
    public static byte[] BatchInBlobFile(ulong sequence, MadeUpReplyChain replyChain, long blobNumber, bool withBlobEntry = true)
    {
        ArgumentNullException.ThrowIfNull(argument: replyChain);
        List<(byte[] Key, byte[]? Value)> writes =
        [
            (IndexedDBKeys.Record(database: ReplyChainsDatabase, objectStore: Store, key: replyChain.Key),
                [.. Encodings.Varint(value: 1), 0xFF, 0x11, 0x01, .. Encodings.Varint(value: BlobSize(replyChain: replyChain)), 0]),
        ];
        if (withBlobEntry)
        {
            writes.Add(item: BlobEntry(replyChain: replyChain, blobNumber: blobNumber));
        }
        return LogWriter.Batch(sequence: sequence, writes: [.. writes]);
    }

    /// A batch that writes `replyChain`'s blob entry, which names the blob file `blobNumber`, after its record.
    public static byte[] BlobEntryBatch(ulong sequence, MadeUpReplyChain replyChain, long blobNumber) =>
        LogWriter.Batch(sequence: sequence, writes: [BlobEntry(replyChain: replyChain, blobNumber: blobNumber)]);

    /// Writes `replyChain`'s blob file, `blobNumber`, where Chromium keeps it for the database whose log is at `log`.
    public static void WriteBlobFile(string log, MadeUpReplyChain replyChain, long blobNumber)
    {
        ArgumentNullException.ThrowIfNull(argument: replyChain);
        var file = new IndexedDBFolder(path: Path.GetDirectoryName(path: log)!).BlobFile(database: ReplyChainsDatabase, number: blobNumber);
        Directory.CreateDirectory(path: Path.GetDirectoryName(path: file)!);
        File.WriteAllBytes(path: file, bytes: V8Writer.Serialized(body: replyChain.Write));
    }

    /// A message's ID: `seconds` after `Fixture.Base`, in milliseconds.
    public static long Id(double seconds) => Fixture.Base + (long)(seconds * 1000);

    public static DateTimeOffset At(double seconds) => DateTimeOffset.FromUnixTimeMilliseconds(milliseconds: Id(seconds: seconds));

    public static string Digits(long value) => value.ToString(provider: CultureInfo.InvariantCulture);

    /// What Teams' Mark as unread leaves in a chat's record: the message it's marked unread after, when, and a 0.
    public static string Bookmark(long after, double markedAtSeconds) => Digits(value: after) + ";" + Digits(value: Id(seconds: markedAtSeconds)) + ";0";

    static TeamsCacheLocation Location(string folder) => new(Root: Path.Combine(path1: folder, path2: "EBWebView"), IsTeamsOwn: false);

    /// `replyChain`'s blob entry: one blob, with no type, in the file `blobNumber`.
    static (byte[] Key, byte[]? Value) BlobEntry(MadeUpReplyChain replyChain, long blobNumber) =>
        (IndexedDBKeys.BlobEntry(database: ReplyChainsDatabase, objectStore: Store, key: replyChain.Key),
            [(byte)ExternalObjectKind.Blob, .. Encodings.Varint(value: (ulong)blobNumber), .. IndexedDBKeys.StringWithLength(text: string.Empty), .. Encodings.Varint(value: BlobSize(replyChain: replyChain))]);

    static ulong BlobSize(MadeUpReplyChain replyChain) => (ulong)V8Writer.Serialized(body: replyChain.Write).Length;

    static string IndexedDBFolder(string folder) => Path.Combine(paths: [folder, "EBWebView", "WV2Profile_tfw", "IndexedDB"]);

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
