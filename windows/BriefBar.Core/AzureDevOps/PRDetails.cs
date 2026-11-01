namespace BriefBar.Core.AzureDevOps;

/// What a pull request's policies and threads say, read apart from the lists, two requests a pull request. The Mac's
/// `PRDetails`.
public sealed record PRDetails
{
    public required DateTimeOffset FetchedAt { get; init; }

    /// The pull request's fingerprint when these were read.
    public required string Fingerprint { get; init; }

    public ValueList<Check> Checks { get; init; } = [];

    /// False when the project doesn't let you read its policies: then nobody can tell whether the pull request is ready,
    /// and `Checks` is empty.
    public bool ChecksKnown { get; init; } = true;

    /// Conversations between people: system threads and deleted comments are left out.
    public ValueList<ReviewThread> Threads { get; init; } = [];

    /// Pushes, votes and reviewer changes, from the system threads, the oldest first.
    public ValueList<Activity> Activity { get; init; } = [];

    /// The latest comment, push, vote or other change.
    public DateTimeOffset? LastActivity { get; init; }

    /// Whether a check is still going, so its details are worth reading more often.
    public bool HasChecksInProgress => Checks.Any(predicate: check => check.IsBlocking && check.State is CheckState.Running or CheckState.Queued);

    /// What `evaluations` and `threads` say about `pullRequest`. `evaluations` is null when its policies couldn't be read.
    public static PRDetails From(DateTimeOffset fetchedAt, PullRequest pullRequest, IReadOnlyList<ADOPolicyEvaluation>? evaluations, IReadOnlyList<ADOThread> threads)
    {
        ArgumentNullException.ThrowIfNull(argument: pullRequest);
        ArgumentNullException.ThrowIfNull(argument: threads);
        var names = new Dictionary<string, string>(comparer: StringComparer.Ordinal);
        foreach (var reviewer in pullRequest.Reviewers)
        {
            names[reviewer.Person.Id] = reviewer.Person.Name;
        }
        names[pullRequest.Author.Id] = pullRequest.Author.Name;

        var reviewThreads = new List<ReviewThread>();
        var activity = new List<Activity>();
        DateTimeOffset? latest = null;
        foreach (var thread in threads.Where(predicate: thread => thread.IsDeleted != true))
        {
            foreach (var date in new[] { thread.PublishedDate, thread.LastUpdatedDate })
            {
                latest = Later(first: latest, second: date);
            }
            if (thread.ActivityType is { } kind)
            {
                if (AzureDevOps.Activity.From(thread: thread, type: kind) is { } item)
                {
                    activity.Add(item: item);
                }
            }
            else if (ReviewThread.From(thread: thread, names: names) is { } conversation)
            {
                reviewThreads.Add(item: conversation);
                foreach (var comment in conversation.Comments)
                {
                    latest = Later(first: latest, second: comment.PublishedAt);
                }
            }
        }
        return new PRDetails
        {
            FetchedAt = fetchedAt,
            Fingerprint = pullRequest.Fingerprint,
            Checks = new ValueList<Check>(items: (evaluations ?? []).Select(selector: Check.From).OfType<Check>()),
            ChecksKnown = evaluations is not null,
            Threads = new ValueList<ReviewThread>(items: reviewThreads),
            Activity = new ValueList<Activity>(items: activity.OrderBy(keySelector: item => item.At)),
            LastActivity = latest,
        };
    }

    static DateTimeOffset? Later(DateTimeOffset? first, DateTimeOffset? second) =>
        first is { } one && second is { } two ? (one > two ? one : two) : first ?? second;
}
