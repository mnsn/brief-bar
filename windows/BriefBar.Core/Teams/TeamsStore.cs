namespace BriefBar.Core.Teams;

/// Teams' chats as the sections list them, from what `TeamsEngine` read, the chats you marked read in BriefBar, and Teams'
/// settings: each section's unread chats, the newest first, and the ones read recently. Not thread-safe: `TeamsSource`
/// uses it under its lock. The Mac's `ConversationStore`.
public sealed class TeamsStore
{
    /// How long a read chat stays under Recent, as on the Mac.
    public static readonly TimeSpan RecentWindow = TimeSpan.FromDays(value: 1);

    /// How many chats Recent lists at most, as on the Mac.
    public const int RecentLimit = 10;

    readonly TeamsSettings settings;
    readonly TeamsReadMarks marks;
    Dictionary<ChatGroup, IReadOnlyList<ConversationSummary>> unread = [];
    Dictionary<ChatGroup, IReadOnlyList<ConversationSummary>> recent = [];

    public TeamsStore(TeamsSettings settings, TeamsReadMarks marks)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: marks);
        this.settings = settings;
        this.marks = marks;
    }

    /// What the engine read last; null until it has read.
    public TeamsSnapshot? Snapshot { get; private set; }

    public bool HasLoaded => Snapshot is not null;

    public TeamsProblem? Problem => Snapshot?.Problem;

    /// Takes in what the engine read: the marks Teams' own markers have passed are forgotten, and those of chats Teams no
    /// longer has, once Teams' data was read in full, which alone says which chats are gone.
    public void Receive(TeamsSnapshot snapshot, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshot);
        Snapshot = snapshot;
        marks.Prune(chats: snapshot.Chats, dropAbsent: snapshot.IsComplete);
        Recompute(now: now);
    }

    /// Decides again which chats are unread and recent, as time passes or settings change. A muted chat is in neither,
    /// as Teams doesn't notify you of it.
    public void Recompute(DateTimeOffset now)
    {
        var keep = settings.KeepUnreadFor;
        var summaries = (Snapshot?.Chats ?? [])
            .Where(predicate: chat => !chat.IsMuted)
            .Select(selector: chat => Summary(chat: chat, now: now, keep: keep))
            .ToList();
        unread = Enum.GetValues<ChatGroup>().ToDictionary(
            keySelector: group => group,
            elementSelector: group => (IReadOnlyList<ConversationSummary>)summaries
                .Where(predicate: summary => summary.Group == group && summary.IsUnread)
                .OrderByDescending(keySelector: summary => summary.Date)
                .ToList());
        recent = Enum.GetValues<ChatGroup>().ToDictionary(
            keySelector: group => group,
            elementSelector: group => (IReadOnlyList<ConversationSummary>)summaries
                .Where(predicate: summary => summary.Group == group
                    && !summary.IsUnread
                    && summary.Latest is { IsContent: true }
                    && summary.LastActivity is { } active
                    && now - active <= RecentWindow)
                .OrderByDescending(keySelector: summary => summary.LastActivity)
                .Take(count: RecentLimit)
                .ToList());
    }

    /// `group`'s chats with unread messages, the newest message first.
    public IReadOnlyList<ConversationSummary> Unread(ChatGroup group) => unread.GetValueOrDefault(key: group) ?? [];

    /// `group`'s read chats with something new in the last day, the newest first.
    public IReadOnlyList<ConversationSummary> Recent(ChatGroup group) => recent.GetValueOrDefault(key: group) ?? [];

    /// The chat `id`, as a list shows it, or null when no list does.
    public ConversationSummary? Find(string id) => unread.Values.Concat(second: recent.Values)
        .SelectMany(selector: list => list)
        .FirstOrDefault(predicate: summary => summary.Id == id);

    /// Reads `conversation` in BriefBar, up to its newest message, as opening it from BriefBar or Mark as Read does, until
    /// Teams' own marker gets there; and a Mark as unread that Teams has for it now, until it's opened in Teams.
    public void MarkRead(ConversationSummary conversation, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: conversation);
        Mark(conversation: conversation, now: now);
        Recompute(now: now);
    }

    /// Reads every chat that `group` lists as unread.
    public void MarkAllRead(ChatGroup group, DateTimeOffset now)
    {
        foreach (var conversation in Unread(group: group))
        {
            Mark(conversation: conversation, now: now);
        }
        Recompute(now: now);
    }

    /// Reads `conversation` up to its newest message, and a Mark as unread that Teams has for it now, even without one.
    void Mark(ConversationSummary conversation, DateTimeOffset now)
    {
        var upTo = Math.Max(val1: conversation.Unread.Count > 0 ? conversation.Unread[^1].Id : 0, val2: conversation.Latest?.Id ?? 0);
        if (upTo > 0 || conversation.IsMarkedUnread)
        {
            marks.Mark(chat: conversation.Id, messageId: upTo, at: now);
        }
    }

    /// `chat`'s newest message that wasn't deleted: the cache may have one the chat's record doesn't name yet, or the
    /// other way round, and only the cache says a message was deleted.
    static TeamsMessage? Latest(TeamsChat chat, IReadOnlyList<TeamsMessage> messages)
    {
        var cached = messages.LastOrDefault(predicate: message => !message.IsDeleted);
        var named = chat.Newest is { } newest && !messages.Any(predicate: message => message.IsDeleted && message.Id == newest.Id) ? newest : null;
        return cached is not null && cached.Id > (named?.Id ?? 0) ? cached : named ?? cached;
    }

    ConversationSummary Summary(TeamsChat chat, DateTimeOffset now, TimeSpan? keep)
    {
        var messages = Snapshot?.Messages.GetValueOrDefault(key: chat.Id) ?? [];
        var unread = ChatReading.Unread(chat: chat, messages: messages, mark: marks.Marks.GetValueOrDefault(key: chat.Id), keepUnreadFor: keep, now: now);
        var latest = Latest(chat: chat, messages: messages);
        return new ConversationSummary(
            Id: chat.Id,
            Kind: chat.Kind,
            Title: chat.Title,
            FullTitle: chat.FullTitle,
            Unread: unread.Messages,
            Latest: latest,
            LastActivity: latest?.ArrivedAt,
            IsMarkedUnread: unread.IsMarkedUnread);
    }
}
