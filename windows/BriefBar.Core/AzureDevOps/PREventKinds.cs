namespace BriefBar.Core.AzureDevOps;

/// What the kinds of events mean.
public static class PREventKinds
{
    /// Everything but an approval needs you.
    public static bool NeedsYou(this PREventKind kind) => kind != PREventKind.Approved;

    /// Which event names the pull request's reason when it has several: the lowest.
    public static int Priority(this PREventKind kind) => kind switch
    {
        PREventKind.Mention => 0,
        PREventKind.SentInChat => 1,
        PREventKind.Reply => 2,
        PREventKind.Rejected => 3,
        PREventKind.ChangesRequested => 4,
        PREventKind.Comment => 5,
        PREventKind.ReviewRequest => 6,
        PREventKind.NewCommits => 7,
        PREventKind.Approved => 8,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(kind), actualValue: kind, message: "Not a kind of event."),
    };
}
