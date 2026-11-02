namespace BriefBar.Core.AzureDevOps;

/// One thing Azure DevOps requires of one of your pull requests, met or not. The Mac's `PRReadiness.Item`.
/// - `State`: done; failing; waiting on you, such as comments to resolve; running; or null while it waits on someone
///   else, such as a reviewer.
/// - `Label`: in a few words, "1 of 2 approvals", "Build failed", "Resolve 2 comments".
/// - `Detail`: more about it, for its tooltip, "Approved by Priya Shah", "shop-web CI · Run unit tests: 2 tests failed".
/// - `IsRequired`: whether it holds the pull request up until it's done; open comments that no policy requires resolving
///   don't.
public sealed record PRReadinessItem(PRReadinessItemKind Kind, ItemState? State, string Label, string? Detail = null, bool IsRequired = true)
{
    public bool IsDone => State == ItemState.Done;

    /// Where it shows: what waits on you, what failed, what's running, what waits on someone else, what doesn't hold the
    /// pull request up, then what's done.
    internal int Rank => (IsRequired, State) switch
    {
        (false, ItemState.Done) => 5,
        (false, _) => 4,
        (true, ItemState.NeedsYou) => 0,
        (true, ItemState.Failing) => 1,
        (true, ItemState.Running) => 2,
        (true, null) => 3,
        (true, ItemState.Done) => 5,
        _ => throw new InvalidOperationException(message: "An item in an unknown state."),
    };
}
