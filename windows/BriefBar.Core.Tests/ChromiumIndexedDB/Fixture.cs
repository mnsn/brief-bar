namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// `Tests/Fixtures/ChromiumIndexedDB`, which the Mac's tests read too: an IndexedDB that Microsoft Edge wrote, with made-up
/// data shaped like Teams' (see make-fixture.html there). The first run wrote every record; the second, appended to the
/// same log, read Avery's chat, added a message to Sam's and deleted the channel.
internal static class Fixture
{
    /// Where the second run's writes start in the log.
    public const int FirstRunLength = 39_357;

    public const string Tenant = "00000000-1111-4222-8333-444444444444";
    public const string Me = "99999999-ffff-4fff-8fff-999999999999";
    public const string ConversationsDatabase = "Teams:conversation-manager:react-web-client:" + Tenant + ":" + Me + ":en-us";
    public const string ReplyChainsDatabase = "Teams:replychain-manager:react-web-client:" + Tenant + ":" + Me + ":en-us";

    public const string Avery = "19:11111111-aaaa-4aaa-8aaa-111111111111_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces";
    public const string Sam = "19:22222222-bbbb-4bbb-8bbb-222222222222_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces";
    public const string Crew = "19:0123456789abcdef0123456789abcdef@thread.v2";
    public const string Sync = "19:meeting_ZmFrZS1tZWV0aW5nLWlkLWZvci10ZXN0cw@thread.v2";
    public const string Channel = "19:abcdefabcdefabcdefabcdefabcdef12@thread.tacv2";
    public const string Big = "19:bigbigbigbigbigbigbigbigbigbig12@thread.v2";
    public const string Wrapped = "19:wrapwrapwrapwrapwrapwrapwrapwrap@thread.v2";

    /// 2026-10-18T10:00:00Z, in milliseconds: the made-up message IDs count from it.
    public const long Base = 1_792_317_600_000;

    public static string Folder { get; } = Path.Combine(path1: RepositoryFolder(), path2: "Tests", path3: "Fixtures", path4: "ChromiumIndexedDB");

    public static string IndexedDB { get; } = Path.Combine(path1: Folder, path2: "IndexedDB");

    public static string LevelDB { get; } = Path.Combine(path1: IndexedDB, path2: "http_teams.localhost_8766.indexeddb.leveldb");

    public static string Blob { get; } = Path.Combine(path1: IndexedDB, path2: "http_teams.localhost_8766.indexeddb.blob");

    public static string Log { get; } = Path.Combine(path1: LevelDB, path2: "000003.log");

    /// The repository's root, found from where the tests run: the folder that has windows/ in it.
    static string RepositoryFolder()
    {
        for (var folder = new DirectoryInfo(path: AppContext.BaseDirectory); folder is not null; folder = folder.Parent)
        {
            if (File.Exists(path: Path.Combine(path1: folder.FullName, path2: "windows", path3: "BriefBar.Windows.slnx")))
            {
                return folder.FullName;
            }
        }
        throw new InvalidOperationException(message: "The tests run outside the repository, so they can't read its fixtures.");
    }
}
