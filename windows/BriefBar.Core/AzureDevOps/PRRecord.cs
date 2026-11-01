namespace BriefBar.Core.AzureDevOps;

/// A pull request as the engine knows it: from the lists, with its details once they're read. `Me` is your identity's ID
/// in its organization, lowercased; `ChatLinks`, the links to it people sent you; `Merge`, once it's merged, the
/// pipelines that ran on it; `IsWatched`, that you follow it by its link. The Mac's `PRRecord`.
public sealed record PRRecord
{
    public PRRecord(PullRequest pullRequest, PRRole role, string me, PRDetails? details = null, IEnumerable<ChatLink>? chatLinks = null, MergePipelines? merge = null, bool isWatched = false)
    {
        ArgumentNullException.ThrowIfNull(argument: pullRequest);
        ArgumentNullException.ThrowIfNull(argument: me);
        PullRequest = pullRequest;
        Role = role;
        Me = me.ToLowerInvariant();
        Details = details;
        ChatLinks = new ValueList<ChatLink>(items: chatLinks ?? []);
        Merge = merge;
        IsWatched = isWatched;
    }

    public PullRequest PullRequest { get; init; }

    public PRRole Role { get; init; }

    public string Me { get; init; }

    public PRDetails? Details { get; init; }

    public ValueList<ChatLink> ChatLinks { get; init; }

    public MergePipelines? Merge { get; init; }

    public bool IsWatched { get; init; }

    public PRKey Id => PullRequest.Key;

    /// As a pull request you watch: one you're not on is listed as if you reviewed it, rather than only while a message
    /// about it needs you.
    public PRRecord Watched() => this with { IsWatched = true, Role = Role == PRRole.Linked ? PRRole.Reviewer : Role };
}
