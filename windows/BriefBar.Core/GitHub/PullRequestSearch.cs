using System.Text.Json;

namespace BriefBar.Core.GitHub;

/// One of the query's searches: how many pull requests match, of which `Nodes` holds those it could read of the first
/// `PullRequestQuery.Count`. The Mac's `PullRequestQueryData.Search`.
public sealed record PullRequestSearch(int IssueCount, ValueList<APIPullRequest> Nodes)
{
    /// The search in `element`: a count that's missing is none, and a pull request that's null, or that can't be read,
    /// is left out.
    internal static PullRequestSearch Read(JsonElement element) => new(
        IssueCount: LenientJson.WholeNumber(element: element, name: "issueCount") ?? 0,
        Nodes: new ValueList<APIPullRequest>(items: LenientJson.Items(element: element, name: "nodes", read: APIPullRequest.Read) ?? []));
}
