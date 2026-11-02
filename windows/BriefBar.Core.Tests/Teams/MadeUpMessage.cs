using BriefBar.Core.Tests.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.Teams;

/// A made-up message: its ID (when it arrived, in milliseconds since 1970), who sent it, what it says, in HTML, whether you
/// sent it, Teams' type for it, and whether it was deleted.
internal sealed record MadeUpMessage(long Id, string Sender, string Html, bool FromMe = false, string Type = "RichText/Html", bool Deleted = false)
{
    /// Its sender's user ID, as Teams names them: the account's own for yours.
    public string UserId => FromMe ? Fixture.Me : TeamsData.SomeoneElse;

    /// As a conversation's `lastMessage`.
    public void WriteAsLast(V8Writer writer)
    {
        ArgumentNullException.ThrowIfNull(argument: writer);
        writer.Members(properties:
        [
            ("id", value => value.Text(text: TeamsData.Digits(value: Id))),
            ("messagetype", value => value.Text(text: Type)),
            ("content", value => value.Text(text: Html)),
            ("imdisplayname", value => value.Text(text: Sender)),
            ("from", value => value.Text(text: "https://example.invalid/v1/users/ME/contacts/8:orgid:" + UserId)),
        ]);
    }

    /// As a reply chain's `messageMap` holds it.
    public void WriteInReplyChain(V8Writer writer, string conversationId)
    {
        ArgumentNullException.ThrowIfNull(argument: writer);
        List<(string Name, Action<V8Writer> Value)> members =
        [
            ("id", value => value.Text(text: TeamsData.Digits(value: Id))),
            ("conversationId", value => value.Text(text: conversationId)),
            ("creator", value => value.Text(text: "8:orgid:" + UserId)),
            ("imDisplayName", value => value.Text(text: Sender)),
            ("content", value => value.Text(text: Deleted ? string.Empty : Html)),
            ("messageType", value => value.Text(text: Type)),
            ("isSentByCurrentUser", value => value.Flag(value: FromMe)),
            ("originalArrivalTime", value => value.Real(value: Id)),
        ];
        if (Deleted)
        {
            members.Add(item: ("deletionInfo", value => value.Members(properties: [("deletionTime", time => time.Real(value: Id + 1000))])));
        }
        writer.Members(properties: [.. members]);
    }
}
