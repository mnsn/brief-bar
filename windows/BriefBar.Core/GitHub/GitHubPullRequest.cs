using System.Globalization;

namespace BriefBar.Core.GitHub;

/// An open pull request on GitHub, with what decides where it goes: `Id` is GitHub's node ID, the same wherever the pull
/// request is found; `Repository` is owner/name; `Author` is null for a deleted account. The Mac's `GitHubPullRequest`.
public sealed record GitHubPullRequest(
    string Id,
    int Number,
    string Title,
    Uri Url,
    string Repository,
    string? Author,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    public bool IsDraft { get; init; }

    /// Null when the repository doesn't require reviews.
    public GitHubReviewDecision? ReviewDecision { get; init; }

    public bool HasConflicts { get; init; }

    /// Null when nothing checks the latest commit.
    public GitHubChecks? Checks { get; init; }

    public ValueList<GitHubReview> Reviews { get; init; } = [];

    /// The branch it merges, such as `robin/tax-rounding`.
    public string? Branch { get; init; }

    /// owner/name#number.
    public string Reference => Repository + "#" + Number.ToString(provider: CultureInfo.InvariantCulture);

    /// From what the query read. Values BriefBar doesn't know count as unknown.
    public static GitHubPullRequest From(APIPullRequest api)
    {
        ArgumentNullException.ThrowIfNull(argument: api);
        return new GitHubPullRequest(
            Id: api.Id, Number: api.Number, Title: api.Title, Url: api.Url, Repository: api.Repository, Author: api.Author, CreatedAt: api.CreatedAt, UpdatedAt: api.UpdatedAt)
        {
            IsDraft = api.IsDraft,
            ReviewDecision = DecisionOf(value: api.ReviewDecision),
            HasConflicts = api.Mergeable == "CONFLICTING",
            Checks = ChecksOf(rollup: api.StatusCheckRollup),
            Reviews = new ValueList<GitHubReview>(items: api.LatestOpinionatedReviews
                .Select(selector: review => ReviewStateOf(value: review.State) is { } state ? new GitHubReview(Reviewer: review.Author, State: state) : null)
                .OfType<GitHubReview>()),
            Branch = api.HeadRefName,
        };
    }

    /// GitHub's `StatusState`: SUCCESS, FAILURE, ERROR, PENDING or EXPECTED; null for none, or one BriefBar doesn't know.
    public static GitHubChecks? ChecksOf(string? rollup) => rollup switch
    {
        "SUCCESS" => GitHubChecks.Passing,
        "FAILURE" or "ERROR" => GitHubChecks.Failing,
        "PENDING" or "EXPECTED" => GitHubChecks.Running,
        _ => null,
    };

    /// GitHub's `PullRequestReviewDecision`; null for none, or one BriefBar doesn't know.
    public static GitHubReviewDecision? DecisionOf(string? value) => value switch
    {
        "APPROVED" => GitHubReviewDecision.Approved,
        "CHANGES_REQUESTED" => GitHubReviewDecision.ChangesRequested,
        "REVIEW_REQUIRED" => GitHubReviewDecision.ReviewRequired,
        _ => null,
    };

    /// Whether a reviewer's latest review says `state`, a deleted account's too.
    internal bool HasReview(GitHubReviewState state) => Reviews.Any(predicate: review => review.State == state);

    /// The reviewers whose latest review says `state`, each once, in order: those with names, so not deleted accounts.
    internal IReadOnlyList<string> Reviewers(GitHubReviewState state)
    {
        var seen = new HashSet<string>(comparer: StringComparer.Ordinal);
        return Reviews.Where(predicate: review => review.State == state)
            .Select(selector: review => review.Reviewer)
            .OfType<string>()
            .Where(predicate: seen.Add)
            .ToList();
    }

    /// A review's state that counts, APPROVED or CHANGES_REQUESTED; null for the others, such as DISMISSED.
    static GitHubReviewState? ReviewStateOf(string value) => value switch
    {
        "APPROVED" => GitHubReviewState.Approved,
        "CHANGES_REQUESTED" => GitHubReviewState.ChangesRequested,
        _ => null,
    };
}
