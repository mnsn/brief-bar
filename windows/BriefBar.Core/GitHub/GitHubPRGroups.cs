namespace BriefBar.Core.GitHub;

/// What the groups mean, and how they're said: the Mac's `GitHubPRGroup` and its `GroupStyle`.
public static class GitHubPRGroups
{
    /// Every group, in the list's order.
    public static IReadOnlyList<GitHubPRGroup> All { get; } = Enum.GetValues<GitHubPRGroup>();

    /// The state it counts in, the same for every source: To review and Changes requested need you, Failing went wrong,
    /// and Ready to merge is done or ready. Waiting isn't counted.
    public static ItemState? State(this GitHubPRGroup group) => group switch
    {
        GitHubPRGroup.ToReview or GitHubPRGroup.ChangesRequested => ItemState.NeedsYou,
        GitHubPRGroup.Failing => ItemState.Failing,
        GitHubPRGroup.Ready => ItemState.Done,
        GitHubPRGroup.Waiting => null,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(group), actualValue: group, message: "Not a group."),
    };

    /// Its title, in sentence case: "To review", "Ready to merge".
    public static string Title(this GitHubPRGroup group) => group switch
    {
        GitHubPRGroup.ToReview => "To review",
        GitHubPRGroup.ChangesRequested => "Changes requested",
        GitHubPRGroup.Failing => "Failing",
        GitHubPRGroup.Ready => "Ready to merge",
        GitHubPRGroup.Waiting => "Waiting",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(group), actualValue: group, message: "Not a group."),
    };

    /// The Mac's name for it, as its counts are logged: `toReview`, `changesRequested`.
    public static string RawValue(this GitHubPRGroup group) => group switch
    {
        GitHubPRGroup.ToReview => "toReview",
        GitHubPRGroup.ChangesRequested => "changesRequested",
        GitHubPRGroup.Failing => "failing",
        GitHubPRGroup.Ready => "ready",
        GitHubPRGroup.Waiting => "waiting",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(group), actualValue: group, message: "Not a group."),
    };
}
