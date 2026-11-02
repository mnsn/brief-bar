namespace BriefBar.Core.Teams;

/// Everything BriefBar knows of Teams' data at one point in time: whether Teams' data was found; each chat; the messages
/// Teams' message cache has of the chats that may be unread, by chat, oldest first; how much could be read; and whether
/// reading failed unexpectedly. `ReadAt`, when the read that made it started, isn't part of equality, so an unchanged
/// read isn't news.
public sealed record TeamsSnapshot
{
    public bool Found { get; init; }

    public IReadOnlyList<TeamsChat> Chats { get; init; } = [];

    public IReadOnlyDictionary<string, IReadOnlyList<TeamsMessage>> Messages { get; init; } =
        new Dictionary<string, IReadOnlyList<TeamsMessage>>(comparer: StringComparer.Ordinal);

    public TeamsDataReport Report { get; init; } = new();

    public bool Failed { get; init; }

    public DateTimeOffset? ReadAt { get; init; }

    /// What keeps it from showing every chat as it is, if anything.
    public TeamsProblem? Problem => Failed ? TeamsProblem.ReadFailed : !Found ? TeamsProblem.NotFound : Report.Problem;

    public bool Equals(TeamsSnapshot? other) =>
        other is not null
        && Found == other.Found
        && Failed == other.Failed
        && Chats.SequenceEqual(second: other.Chats)
        && Messages.Count == other.Messages.Count
        && Messages.All(predicate: pair => other.Messages.TryGetValue(key: pair.Key, value: out var messages) && messages.SequenceEqual(second: pair.Value))
        && Report.Equals(other: other.Report);

    public override int GetHashCode() => HashCode.Combine(value1: Found, value2: Failed, value3: Chats.Count, value4: Messages.Count);
}
