namespace BriefBar.Core.AzureDevOps;

/// Something that happened on a pull request, recorded by Azure DevOps as a system thread: a push, a vote, reviewers
/// added or removed, the draft published… `Added` holds the lowercased IDs of the reviewers added. The Mac's `Activity`.
public sealed record Activity
{
    public Activity(int threadId, ActivityKind kind, DateTimeOffset at, Person? actor = null, Vote? vote = null, int? commitCount = null, IEnumerable<string>? added = null)
    {
        ThreadId = threadId;
        Kind = kind;
        At = at;
        Actor = actor;
        Vote = vote;
        CommitCount = commitCount;
        Added = new ValueList<string>(items: (added ?? []).Select(selector: id => id.ToLowerInvariant()));
    }

    public int ThreadId { get; }

    public ActivityKind Kind { get; }

    public DateTimeOffset At { get; }

    public Person? Actor { get; }

    public Vote? Vote { get; }

    public int? CommitCount { get; }

    public ValueList<string> Added { get; }

    /// What the system thread `thread`, of `type`, recorded; null when it says neither when.
    public static Activity? From(ADOThread thread, string type)
    {
        ArgumentNullException.ThrowIfNull(argument: thread);
        if ((thread.PublishedDate ?? (thread.Comments is { Count: > 0 } comments ? comments[0].PublishedDate : null)) is not { } at)
        {
            return null;
        }
        ADOIdentity? actor = null;
        Vote? vote = null;
        int? commitCount = null;
        var added = new List<string>();
        ActivityKind kind;
        switch (type)
        {
            case "RefUpdate":
                kind = ActivityKind.Push;
                actor = thread.Identity(name: "CodeReviewRefUpdatedByIdentity");
                commitCount = int.TryParse(s: thread.Property(name: "CodeReviewRefNewCommitsCount"), provider: System.Globalization.CultureInfo.InvariantCulture, result: out var count) ? count : null;
                break;
            case "VoteUpdate":
                kind = ActivityKind.Vote;
                actor = thread.Identity(name: "CodeReviewVotedByIdentity");
                vote = Votes.From(raw: thread.Property(name: "CodeReviewVoteResult"));
                break;
            case "ReviewersUpdate":
                kind = ActivityKind.ReviewersChanged;
                actor = thread.Identity(name: "CodeReviewReviewersUpdatedByIdentity");
                // One identity key, or several separated by commas.
                var keys = (thread.Property(name: "CodeReviewReviewersUpdatedAddedIdentity") ?? string.Empty)
                    .Split(separator: ',')
                    .Select(selector: key => key.Trim())
                    .Where(predicate: key => key.Length > 0);
                foreach (var key in keys)
                {
                    if (thread.Identities is not null && thread.Identities.TryGetValue(key: key, value: out var identity))
                    {
                        added.Add(item: identity.Id);
                    }
                }
                break;
            case "ResetMultipleVotes" or "ResetAllVotes":
                kind = ActivityKind.VotesReset;
                break;
            case "IsDraftUpdate":
                kind = ActivityKind.DraftChanged;
                actor = thread.Identity(name: "CodeReviewIsDraftUpdatedByIdentity");
                break;
            case "AutoCompleteUpdate":
                kind = ActivityKind.AutoComplete;
                break;
            default:
                kind = ActivityKind.Other;
                break;
        }
        return new Activity(
            threadId: thread.Id,
            kind: kind,
            at: at,
            actor: actor is null ? null : Person.From(identity: actor),
            vote: vote,
            commitCount: commitCount,
            added: added);
    }
}
