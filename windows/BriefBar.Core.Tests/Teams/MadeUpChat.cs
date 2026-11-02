using BriefBar.Core.Tests.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.Teams;

/// A made-up conversation record: its ID, Teams' type for it ("Chat", "Meeting", "Topic"…), how far it was read in Teams
/// (0 for never), its newest message, its topic and titles, and whether its alerts are on, as Teams spells them.
internal sealed record MadeUpChat(
    string Id,
    string Type,
    long ReadUpTo,
    MadeUpMessage? Newest,
    string? Topic = null,
    string? ShortTitle = null,
    string? LongTitle = null,
    string? Alerts = null)
{
    public void Write(V8Writer writer)
    {
        ArgumentNullException.ThrowIfNull(argument: writer);
        var horizon = ReadUpTo > 0
            ? TeamsData.Digits(value: ReadUpTo) + ";" + TeamsData.Digits(value: ReadUpTo + 900) + ";" + TeamsData.Digits(value: ReadUpTo + 7)
            : "0;0;0";
        List<(string Name, Action<V8Writer> Value)> properties = [("consumptionhorizon", value => value.Text(text: horizon))];
        if (Alerts is not null)
        {
            properties.Add(item: ("alerts", value => value.Text(text: Alerts)));
        }
        List<(string Name, Action<V8Writer> Value)> thread = [("threadType", value => value.Text(text: Type == "Meeting" ? "meeting" : "chat"))];
        if (Topic is not null)
        {
            thread.Add(item: ("topic", value => value.Text(text: Topic)));
        }
        if (Newest is not null)
        {
            thread.Add(item: ("isLastMessageFromMe", value => value.Flag(value: Newest.FromMe)));
        }
        List<(string Name, Action<V8Writer> Value)> titles = [];
        if (ShortTitle is not null)
        {
            titles.Add(item: ("shortTitle", value => value.Text(text: ShortTitle)));
        }
        if (LongTitle is not null)
        {
            titles.Add(item: ("longTitle", value => value.Text(text: LongTitle)));
        }
        List<(string Name, Action<V8Writer> Value)> members =
        [
            ("id", value => value.Text(text: Id)),
            ("type", value => value.Text(text: Type)),
            ("properties", value => value.Members(properties: [.. properties])),
            ("threadProperties", value => value.Members(properties: [.. thread])),
            ("chatTitle", value => value.Members(properties: [.. titles])),
        ];
        if (Newest is not null)
        {
            members.Add(item: ("lastMessage", Newest.WriteAsLast));
        }
        writer.Members(properties: [.. members]);
    }
}
