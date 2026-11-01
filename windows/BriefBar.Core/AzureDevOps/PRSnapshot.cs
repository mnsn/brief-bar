namespace BriefBar.Core.AzureDevOps;

/// What the panel shows for one pull request: where it is, why, and what's new. The Mac's `PRSnapshot`.
public sealed record PRSnapshot
{
    public required PRKey Key { get; init; }

    public required string Title { get; init; }

    public required string Repository { get; init; }

    public required string Project { get; init; }

    public required string Author { get; init; }

    public required PRRole Role { get; init; }

    public bool IsDraft { get; init; }

    public required PRGroup Group { get; init; }

    public required PRReason Reason { get; init; }

    public required string Headline { get; init; }

    /// A comment, the names of failed checks, who approved…
    public string? Detail { get; init; }

    /// When it got to this state, or its latest activity.
    public DateTimeOffset? Since { get; init; }

    /// The pull request, or the thread of the comment that needs you.
    public required Uri Url { get; init; }

    /// What you haven't seen yet, and the comments you have that still wait on you, the newest first.
    public ValueList<PREvent> Events { get; init; } = [];

    /// The people who approved.
    public ValueList<string> Approvals { get; init; } = [];

    /// The state of the required builds and status checks together, the worst first; null without any.
    public CheckState? CheckState { get; init; }

    public bool HasDetails { get; init; }

    /// Where it was sent to you: while that needs you, and until you've seen that you answered it.
    public ChatSource? ChatSource { get; init; }

    /// Where its build failed, and the first error there, when it's failing because of a build whose timeline says.
    public PipelineFailure? Failure { get; init; }

    /// Once it's merged, how the pipelines that ran on it stand.
    public MergeSummary? Merge { get; init; }

    /// You watch it, by its link.
    public bool IsWatched { get; init; }

    /// `organization/number`, unique among pull requests.
    public string Id => Key.ToString();

    /// Events that need you, rather than news such as approvals.
    public IEnumerable<PREvent> PendingEvents => Events.Where(predicate: item => item.Kind.NeedsYou());

    /// Something that needs you is new: in Needs you, it's marked until you open the pull request. Without it, what's
    /// there is what you've seen and haven't answered.
    public bool HasNews => PendingEvents.Any(predicate: item => item.IsNew);

    /// Whether its headline and detail say what only the notifications of the app someone sent it in know: who sent it,
    /// and in which app.
    public bool IsFromChat => Reason == PRReason.SentInChat || (Reason == PRReason.Answered && ChatSource is not null);

    /// The pull request's page, at a comment thread when there's one.
    public Uri PageUrl(int? thread = null) =>
        ADOEndpoint.PullRequestPage(organization: Key.Organization, project: Project, repository: Repository, id: Key.Number, threadId: thread);
}
