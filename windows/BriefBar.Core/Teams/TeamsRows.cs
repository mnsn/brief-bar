using System.Globalization;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Teams;

/// What the Teams sections show, from the store: how they stand, their groups and rows, their brief, and what their panels
/// can do. The Mac's `TeamsSource` menu-bar parts, `MenuPanelView` and `ConversationRowView`, as data.
public static class TeamsRows
{
    public const string UnreadGroup = "unread";
    public const string RecentGroup = "recent";

    /// How many unread messages a chat's tooltip shows at most, as on the Mac.
    const int ToolTipMessages = 5;

    /// The section that lists `group`'s chats.
    public static SectionInfo Info(ChatGroup group) => group == ChatGroup.Chats ? Sections.TeamsChats : Sections.TeamsGroupChats;

    /// What `group`'s section shows as `store` and `settings` stand now.
    public static SectionSnapshot Snapshot(TeamsStore store, TeamsSettings settings, ChatGroup group)
    {
        ArgumentNullException.ThrowIfNull(argument: store);
        ArgumentNullException.ThrowIfNull(argument: settings);
        var info = Info(group: group);
        if (!store.HasLoaded)
        {
            return SectionSnapshot.Starting(info: info);
        }
        var unread = store.Unread(group: group);
        var recent = store.Recent(group: group);
        var showPreviews = settings.ShowMessagePreviews;
        List<ItemRow> rows =
        [
            .. unread.Select(selector: conversation => Row(conversation: conversation, info: info, groupKey: UnreadGroup, showPreviews: showPreviews)),
            .. recent.Select(selector: conversation => Row(conversation: conversation, info: info, groupKey: RecentGroup, showPreviews: showPreviews)),
        ];
        var problem = store.Problem;
        var blocking = problem is TeamsProblem.NotFound or TeamsProblem.DataChanged or TeamsProblem.ReadFailed;
        return new SectionSnapshot(
            Info: info,
            Status: Status(problem: problem, hasChats: rows.Count > 0),
            Groups: Groups(group: group),
            Rows: rows,
            BriefLines: unread.Select(selector: conversation => new BriefLine(
                Id: conversation.Id,
                Section: info.Id,
                State: ItemState.NeedsYou,
                Date: conversation.Date,
                Sentence: ChatBrief.Sentence(conversation: conversation, showsText: showPreviews))).ToList())
        {
            Commands = [new PanelCommand(Key: TeamsCommands.OpenApp, Title: "Open Teams", Opens: true)],
            Quiet = unread.Count == 0 && !blocking ? new QuietNote(Title: NoneUnread(group: group), Detail: RecentWords(count: recent.Count)) : null,
            Notices = problem == TeamsProblem.PartlyUnreadable
                ? [new SectionNotice(Message: "Some of Teams' data couldn't be read, so some chats may be missing, or stay unread here until you open them.")]
                : [],
        };
    }

    /// Each group, in the list's order: Unread, whose chats can all be marked read, then Recent, folded, as the Mac's is.
    public static IReadOnlyList<RowGroup> Groups(ChatGroup group) =>
    [
        new RowGroup(Key: UnreadGroup, Title: "Unread", State: ItemState.NeedsYou)
        {
            Commands =
            [
                new PanelCommand(
                    Key: TeamsCommands.MarkAllRead,
                    Title: "Mark all read",
                    Help: group == ChatGroup.Chats ? "Mark every chat here as read" : "Mark every group chat here as read"),
            ],
        },
        new RowGroup(Key: RecentGroup, Title: "Recent", State: null) { IsFolded = true },
    ];

    /// One chat's row: its initials or kind, its name, its newest unread message (with its sender in a group chat), when,
    /// how many messages are unread, and what clicking it does.
    public static ItemRow Row(ConversationSummary conversation, SectionInfo info, string groupKey, bool showPreviews)
    {
        ArgumentNullException.ThrowIfNull(argument: conversation);
        ArgumentNullException.ThrowIfNull(argument: info);
        return new ItemRow
        {
            Id = conversation.Id,
            Section = info.Id,
            Group = groupKey,
            State = conversation.IsUnread ? ItemState.NeedsYou : null,
            Icon = conversation.Kind == ConversationKind.OneOnOne ? IconKey.Person : IconKey.People,
            Initials = conversation.Kind == ConversationKind.OneOnOne ? Initials(name: conversation.Title) : null,
            Title = conversation.Title,
            Status = Preview(conversation: conversation, showPreviews: showPreviews),
            StatusTone = StatusTone.Quote,
            Date = conversation.Date,
            Unread = conversation.Unread.Count,
            Commands =
            [
                new PanelCommand(Key: TeamsCommands.Open, Title: "Open in Teams", Opens: true),
                .. conversation.IsUnread ? [new PanelCommand(Key: TeamsCommands.MarkRead, Title: "Mark as read")] : Array.Empty<PanelCommand>(),
            ],
            ToolTip = ToolTip(conversation: conversation, showPreviews: showPreviews),
        };
    }

    /// What a row says under its name: its newest unread message, else its newest, with who wrote it in a group chat, or
    /// "You"; without previews, how many messages are unread.
    public static string Preview(ConversationSummary conversation, bool showPreviews)
    {
        ArgumentNullException.ThrowIfNull(argument: conversation);
        if (!showPreviews || conversation.Shown is not { } message)
        {
            return conversation.IsUnread ? UnreadWords(count: conversation.Unread.Count) : "No new messages";
        }
        return Line(message: message, kind: conversation.Kind);
    }

    /// A person's initials: the first letters of their first and last names, as the Mac's avatars show them.
    public static string Initials(string name)
    {
        ArgumentNullException.ThrowIfNull(argument: name);
        var letters = name.Split(separator: ',')
            .SelectMany(selector: part => part.Split(separator: (char[]?)null, options: StringSplitOptions.RemoveEmptyEntries))
            .Select(selector: word => word.FirstOrDefault(predicate: char.IsLetter))
            .Where(predicate: letter => letter != default)
            .Select(selector: char.ToUpperInvariant)
            .ToList();
        return letters.Count switch
        {
            0 => "?",
            1 => new string(value: [letters[0]]),
            _ => new string(value: [letters[0], letters[^1]]),
        };
    }

    /// "1 new message", "3 new messages".
    public static string UnreadWords(int count) => count == 1
        ? "1 new message"
        : count.ToString(provider: CultureInfo.InvariantCulture) + " new messages";

    /// "No unread chats", "No unread group chats", as the Mac's lists say.
    public static string NoneUnread(ChatGroup group) => group == ChatGroup.Chats ? "No unread chats" : "No unread group chats";

    /// A message on one line: "You: …", "Jordan Lee: …" in a group chat, or what it says.
    static string Line(TeamsMessage message, ConversationKind kind)
    {
        var text = message.Text.Length > 0 ? message.Text : "Sent an attachment";
        var sender = message.IsFromMe ? "You" : kind == ConversationKind.OneOnOne ? null : message.Sender;
        return string.IsNullOrEmpty(value: sender) ? text : sender + ": " + text;
    }

    /// Under "No unread chats": how many read chats Recent lists.
    static string RecentWords(int count) => count switch
    {
        0 => "Nothing new in the last day",
        1 => "1 recent chat",
        _ => count.ToString(provider: CultureInfo.InvariantCulture) + " recent chats",
    };

    /// Everything its row shows, in full: its name, its unread messages, or its newest, and what clicking it does.
    static string ToolTip(ConversationSummary conversation, bool showPreviews)
    {
        var lines = new List<string> { conversation.FullTitle ?? conversation.Title };
        if (showPreviews)
        {
            var messages = conversation.IsUnread
                ? conversation.Unread.TakeLast(count: ToolTipMessages)
                : conversation.Latest is { } latest ? [latest] : [];
            lines.AddRange(collection: messages.Select(selector: message => Line(message: message, kind: conversation.Kind)));
        }
        else if (conversation.IsUnread)
        {
            lines.Add(item: UnreadWords(count: conversation.Unread.Count));
        }
        lines.Add(item: "Click to open in Microsoft Teams");
        return string.Join(separator: '\n', values: lines);
    }

    static SectionStatus Status(TeamsProblem? problem, bool hasChats) => problem switch
    {
        TeamsProblem.NotFound => new SectionStatus(
            Condition: hasChats ? SectionCondition.Stale : SectionCondition.Problem,
            Problem: "BriefBar can't find Teams' data on this PC. It reads the new Teams app, once you've signed in to it with a work or school account.",
            ShortProblem: "No Teams"),
        TeamsProblem.DataChanged => new SectionStatus(
            Condition: hasChats ? SectionCondition.Stale : SectionCondition.Problem,
            Problem: "Teams' data has changed, probably with an update to Teams, so BriefBar can't tell which chats are unread.",
            ShortProblem: "Can't read"),
        TeamsProblem.ReadFailed => new SectionStatus(
            Condition: hasChats ? SectionCondition.Stale : SectionCondition.Problem,
            Problem: "BriefBar couldn't read Teams' data. It tries again as Teams writes, and every 10 minutes.",
            ShortProblem: "Can't read"),
        _ => SectionStatus.Live,
    };
}
