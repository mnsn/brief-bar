using BriefBar.Core.Teams;

namespace BriefBar.Core.Demo;

/// Made-up Teams chats, as the engine would read them from Teams' own data, all minutes before `now`, with the Mac demo's
/// people: Avery and Sam wrote to you, Launch crew & Design and the Weekly sync's chat have new messages, and Noah's chat
/// and Design reviews were read a few hours ago. Nothing is read: for `--demo`, screenshots and tests.
public static class TeamsDemoData
{
    public const string Avery = "19:aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces";
    public const string Sam = "19:bbbbbbbb-2222-4bbb-8bbb-bbbbbbbbbbbb_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces";
    public const string Noah = "19:cccccccc-3333-4ccc-8ccc-cccccccccccc_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces";
    public const string LaunchCrew = "19:0123456789abcdef0123456789abcdef@thread.v2";
    public const string DesignReviews = "19:00112233445566778899aabbccddeeff@thread.v2";
    public const string WeeklySync = "19:meeting_ZGVtby1tZWV0aW5nLWlkLWZvci10ZWFtcy1wdWxzZQ@thread.v2";

    public static TeamsSnapshot Snapshot(DateTimeOffset now)
    {
        var avery = new[]
        {
            Message(chat: Avery, sender: "Avery Quinn", text: "Are we still on for the 3 pm review?", now: now, minutes: 25),
            Message(chat: Avery, sender: "Avery Quinn", text: "I moved the deck to the shared folder.", now: now, minutes: 12),
        };
        var sam = new[] { Message(chat: Sam, sender: "Sam Rivera", text: "Can you look at my pull request when you get a chance?", now: now, minutes: 40) };
        var crew = new[]
        {
            Message(chat: LaunchCrew, sender: "Jordan Lee", text: "Staging is green 🎉", now: now, minutes: 50),
            Message(chat: LaunchCrew, sender: "Maya Chen", text: "I'll update the release notes.", now: now, minutes: 30),
            Message(chat: LaunchCrew, sender: "Jordan Lee", text: "Shipping at 5 unless someone objects.", now: now, minutes: 5),
        };
        var sync = new[] { Message(chat: WeeklySync, sender: "Priya Patel", text: "Notes and action items are in the chat.", now: now, minutes: 70) };
        var noah = Message(chat: Noah, sender: "Noah Kim", text: "Thanks, that worked!", now: now, minutes: 300);
        var reviews = Message(chat: DesignReviews, sender: "Maya Chen", text: "New mocks are up for Thursday.", now: now, minutes: 360);
        return new TeamsSnapshot
        {
            Found = true,
            IsComplete = true,
            Chats =
            [
                Chat(id: Avery, kind: ConversationKind.OneOnOne, title: "Avery Quinn", newest: avery[^1], readUpTo: Id(now: now, minutes: 180)),
                Chat(id: Sam, kind: ConversationKind.OneOnOne, title: "Sam Rivera", newest: sam[^1], readUpTo: Id(now: now, minutes: 180)),
                Chat(id: Noah, kind: ConversationKind.OneOnOne, title: "Noah Kim", newest: noah, readUpTo: noah.Id),
                Chat(id: LaunchCrew, kind: ConversationKind.Group, title: "Launch crew & Design", newest: crew[^1], readUpTo: Id(now: now, minutes: 180)),
                Chat(id: DesignReviews, kind: ConversationKind.Group, title: "Design reviews", newest: reviews, readUpTo: reviews.Id),
                Chat(id: WeeklySync, kind: ConversationKind.Meeting, title: "Weekly sync", newest: sync[^1], readUpTo: Id(now: now, minutes: 180)),
            ],
            Messages = new Dictionary<string, IReadOnlyList<TeamsMessage>>(comparer: StringComparer.Ordinal)
            {
                [Avery] = avery,
                [Sam] = sam,
                [LaunchCrew] = crew,
                [WeeklySync] = sync,
            },
            Report = new TeamsDataReport { Folders = 1, Stores = 1, Conversations = 6, Chats = 6, WithMarker = 6, WithHorizon = 6 },
            ReadAt = now,
        };
    }

    static TeamsChat Chat(string id, ConversationKind kind, string title, TeamsMessage newest, long readUpTo) => new(
        Id: id, Kind: kind, Title: title, FullTitle: null, Marker: new ReadMarker(MessageId: readUpTo), Newest: newest, IsMuted: false);

    static TeamsMessage Message(string chat, string sender, string text, DateTimeOffset now, int minutes) => new(
        ConversationId: chat,
        Id: Id(now: now, minutes: minutes),
        Sender: sender,
        IsFromMe: false,
        Type: "RichText/Html",
        Text: text,
        ArrivedAt: DateTimeOffset.FromUnixTimeMilliseconds(milliseconds: Id(now: now, minutes: minutes)));

    /// A message's ID: when it arrived, in milliseconds since 1970.
    static long Id(DateTimeOffset now, int minutes) => now.AddMinutes(minutes: -minutes).ToUnixTimeMilliseconds();
}
