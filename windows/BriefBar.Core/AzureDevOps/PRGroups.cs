namespace BriefBar.Core.AzureDevOps;

/// What the groups mean, and how they're said.
public static class PRGroups
{
    /// Every group, in the panel's order.
    public static IReadOnlyList<PRGroup> All { get; } = Enum.GetValues<PRGroup>();

    /// The state it counts in, the same for every source, or null for the groups the bar doesn't count: Answered,
    /// Waiting, Done and Idle. To review needs you too, but only while you show it in the bar.
    public static ItemState? State(this PRGroup group, bool showToReview) => group switch
    {
        PRGroup.NeedsYou => ItemState.NeedsYou,
        PRGroup.ToReview => showToReview ? ItemState.NeedsYou : null,
        PRGroup.Failing => ItemState.Failing,
        PRGroup.Ready => ItemState.Done,
        PRGroup.Answered or PRGroup.Waiting or PRGroup.Done or PRGroup.Idle => null,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(group), actualValue: group, message: "Not a group."),
    };

    /// Its title, in sentence case: "Needs you", "Ready to complete".
    public static string Title(this PRGroup group) => group switch
    {
        PRGroup.NeedsYou => "Needs you",
        PRGroup.Answered => "Answered",
        PRGroup.Failing => "Failing",
        PRGroup.Ready => "Ready to complete",
        PRGroup.ToReview => "To review",
        PRGroup.Waiting => "Waiting",
        PRGroup.Done => "Done",
        PRGroup.Idle => "Idle",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(group), actualValue: group, message: "Not a group."),
    };

    /// The Mac's name for it, as its counts are logged and saved: `needsYou`, `toReview`.
    public static string RawValue(this PRGroup group) => group switch
    {
        PRGroup.NeedsYou => "needsYou",
        PRGroup.Answered => "answered",
        PRGroup.Failing => "failing",
        PRGroup.Ready => "ready",
        PRGroup.ToReview => "toReview",
        PRGroup.Waiting => "waiting",
        PRGroup.Done => "done",
        PRGroup.Idle => "idle",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(group), actualValue: group, message: "Not a group."),
    };
}
