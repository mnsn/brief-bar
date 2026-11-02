namespace BriefBar.Core.Teams;

/// How much of Teams' data BriefBar could read: counts and formats, never names, messages or IDs. The Mac's
/// `ReadMarkerReport`, which reads the same data, with its chats.
public sealed record TeamsDataReport
{
    /// The Teams site's IndexedDB folders.
    public int Folders { get; init; }

    /// Their databases with conversations (`Teams:conversation-manager:…`, object store `conversations`).
    public int Stores { get; init; }

    /// Conversations: chats, channels and Teams' own threads.
    public int Conversations { get; init; }

    /// Of them, 1:1, group and meeting chats.
    public int Chats { get; init; }

    /// Chats with a read marker.
    public int WithMarker { get; init; }

    /// Conversations whose read marker field is in its form, read or not: none at all, as after an update to Teams that
    /// renames it, says BriefBar can't tell what's read.
    public int WithHorizon { get; init; }

    /// Values read, by format.
    public IReadOnlyDictionary<string, int> Formats { get; init; } = new Dictionary<string, int>(comparer: StringComparer.Ordinal);

    /// Values that couldn't be read, by why.
    public IReadOnlyDictionary<string, int> Unreadable { get; init; } = new Dictionary<string, int>(comparer: StringComparer.Ordinal);

    public int UnreadableFiles { get; init; }

    /// Chats that may be unread whose messages couldn't all be read from Teams' message cache: they may have more unread
    /// messages than they show.
    public int ChatsPartlyRead { get; init; }

    public int CorruptLogRecords { get; init; }

    public int BlocksRead { get; init; }

    public int BlocksSkipped { get; init; }

    public int UnreadableCount => Unreadable.Values.Sum();

    /// Teams' data was found but not understood, as after an update that changed it, or only partly. Nothing found at all
    /// is `TeamsProblem.NotFound`, which `TeamsSnapshot` says.
    public TeamsProblem? Problem
    {
        get
        {
            var total = Conversations + UnreadableCount;
            if (Folders > 0 && Stores == 0)
            {
                return TeamsProblem.DataChanged;
            }
            // Chats never opened, as on a new account, have no read marker, but have the field that holds one.
            if (total > 0 && WithHorizon == 0)
            {
                return TeamsProblem.DataChanged;
            }
            if (UnreadableCount * 4 > total || UnreadableFiles > 0 || ChatsPartlyRead > 0)
            {
                return TeamsProblem.PartlyUnreadable;
            }
            return null;
        }
    }

    /// This report's counts and another's together, as for the folders of several profiles.
    public TeamsDataReport Adding(TeamsDataReport other)
    {
        ArgumentNullException.ThrowIfNull(argument: other);
        return new TeamsDataReport
        {
            Folders = Folders + other.Folders,
            Stores = Stores + other.Stores,
            Conversations = Conversations + other.Conversations,
            Chats = Chats + other.Chats,
            WithMarker = WithMarker + other.WithMarker,
            WithHorizon = WithHorizon + other.WithHorizon,
            Formats = Merged(first: Formats, second: other.Formats),
            Unreadable = Merged(first: Unreadable, second: other.Unreadable),
            UnreadableFiles = UnreadableFiles + other.UnreadableFiles,
            ChatsPartlyRead = ChatsPartlyRead + other.ChatsPartlyRead,
            CorruptLogRecords = CorruptLogRecords + other.CorruptLogRecords,
            BlocksRead = BlocksRead + other.BlocksRead,
            BlocksSkipped = BlocksSkipped + other.BlocksSkipped,
        };
    }

    public bool Equals(TeamsDataReport? other) =>
        other is not null
        && Folders == other.Folders
        && Stores == other.Stores
        && Conversations == other.Conversations
        && Chats == other.Chats
        && WithMarker == other.WithMarker
        && WithHorizon == other.WithHorizon
        && SameCounts(first: Formats, second: other.Formats)
        && SameCounts(first: Unreadable, second: other.Unreadable)
        && UnreadableFiles == other.UnreadableFiles
        && ChatsPartlyRead == other.ChatsPartlyRead
        && CorruptLogRecords == other.CorruptLogRecords;

    public override int GetHashCode() => HashCode.Combine(value1: Folders, value2: Stores, value3: Conversations, value4: Chats, value5: WithMarker);

    static Dictionary<string, int> Merged(IReadOnlyDictionary<string, int> first, IReadOnlyDictionary<string, int> second)
    {
        var merged = new Dictionary<string, int>(collection: first, comparer: StringComparer.Ordinal);
        foreach (var (key, count) in second)
        {
            merged[key] = merged.GetValueOrDefault(key: key) + count;
        }
        return merged;
    }

    static bool SameCounts(IReadOnlyDictionary<string, int> first, IReadOnlyDictionary<string, int> second) =>
        first.Count == second.Count && first.All(predicate: pair => second.TryGetValue(key: pair.Key, value: out var count) && count == pair.Value);
}
