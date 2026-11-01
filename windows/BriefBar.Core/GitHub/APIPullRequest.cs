using System.Text.Json;

namespace BriefBar.Core.GitHub;

/// A pull request as `PullRequestQuery` reads it. What it may leave out is optional; one without its ID, number, title,
/// link, draft flag, dates or repository can't be read, and is left out of its list, as on the Mac. The Mac's
/// `APIPullRequest`, with its author's login, its repository's `nameWithOwner` and its latest commit's checks in place of
/// the objects that hold them.
public sealed record APIPullRequest(
    string Id,
    int Number,
    string Title,
    Uri Url,
    bool IsDraft,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    string Repository)
{
    /// Its author's login: null for a deleted account.
    public string? Author { get; init; }

    /// The branch it merges.
    public string? HeadRefName { get; init; }

    /// `APPROVED`, `CHANGES_REQUESTED` or `REVIEW_REQUIRED`; null when the repository doesn't require reviews.
    public string? ReviewDecision { get; init; }

    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`.
    public string? Mergeable { get; init; }

    /// Its latest commit's checks, all together (`statusCheckRollup`'s state): `SUCCESS`, `FAILURE`, `ERROR`, `PENDING`
    /// or `EXPECTED`; null when nothing checks it.
    public string? StatusCheckRollup { get; init; }

    public ValueList<APIPullRequestReview> LatestOpinionatedReviews { get; init; } = [];

    /// The pull request in `element`, or null when it can't be read, as a node GitHub couldn't give is null.
    internal static APIPullRequest? Read(JsonElement element)
    {
        if (LenientJson.Text(element: element, name: "id") is not { } id
            || LenientJson.WholeNumber(element: element, name: "number") is not { } number
            || LenientJson.Text(element: element, name: "title") is not { } title
            || LenientJson.Text(element: element, name: "url") is not { } link || !Uri.TryCreate(uriString: link, uriKind: UriKind.Absolute, result: out var url)
            || LenientJson.Flag(element: element, name: "isDraft") is not { } isDraft
            || LenientJson.Date(element: element, name: "createdAt") is not { } created
            || LenientJson.Date(element: element, name: "updatedAt") is not { } updated
            || LenientJson.Text(element: LenientJson.Node(element: element, name: "repository"), name: "nameWithOwner") is not { } repository)
        {
            return null;
        }
        return new APIPullRequest(Id: id, Number: number, Title: title, Url: url, IsDraft: isDraft, CreatedAt: created, UpdatedAt: updated, Repository: repository)
        {
            Author = LenientJson.Text(element: LenientJson.Node(element: element, name: "author"), name: "login"),
            HeadRefName = LenientJson.Text(element: element, name: "headRefName"),
            ReviewDecision = LenientJson.Text(element: element, name: "reviewDecision"),
            Mergeable = LenientJson.Text(element: element, name: "mergeable"),
            StatusCheckRollup = LatestRollup(commits: LenientJson.Node(element: element, name: "commits")),
            LatestOpinionatedReviews = new ValueList<APIPullRequestReview>(
                items: LenientJson.Items(element: LenientJson.Node(element: element, name: "latestOpinionatedReviews"), name: "nodes", read: APIPullRequestReview.Read) ?? []),
        };
    }

    /// The state of the last commit's checks, of the commits that could be read, as the Mac's
    /// `commits?.nodes.last?.commit.statusCheckRollup?.state`: a commit node without its commit is left out.
    static string? LatestRollup(JsonElement? commits)
    {
        if (LenientJson.Member(element: commits, name: "nodes") is not { ValueKind: JsonValueKind.Array } nodes)
        {
            return null;
        }
        JsonElement? last = null;
        foreach (var node in nodes.EnumerateArray())
        {
            if (LenientJson.Node(element: node, name: "commit") is { } commit)
            {
                last = commit;
            }
        }
        return LenientJson.Text(element: LenientJson.Node(element: last, name: "statusCheckRollup"), name: "state");
    }
}
