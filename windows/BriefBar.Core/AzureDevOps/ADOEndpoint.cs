using System.Globalization;
using System.Text;

namespace BriefBar.Core.AzureDevOps;

/// The REST endpoints BriefBar reads, and the web pages it opens. Every name and ID travels percent-encoded, so that
/// names with spaces and IDs such as `vstfs:///…` arrive intact. The Mac's `ADOEndpoint`.
public static class ADOEndpoint
{
    const string ApiVersion = "7.1";
    const string Organizations = "https://dev.azure.com";
    const string Profiles = "https://app.vssps.visualstudio.com";

    /// Your profile, to find your organizations with.
    public static Uri Profile { get; } = Url(baseUrl: Profiles, segments: ["_apis", "profile", "profiles", "me"], query: [("api-version", ApiVersion)]);

    public static Uri ConnectionData(string organization) =>
        Url(baseUrl: Organizations, segments: [organization, "_apis", "connectionData"], query: []);

    /// Pull requests across every project in the organization: yours (`creatorId`) or those you review (`reviewerId`).
    /// With `closedSince`, those closed since then.
    public static Uri PullRequests(
        string organization, string status, string? creatorId = null, string? reviewerId = null, DateTimeOffset? closedSince = null, int top = 200)
    {
        var query = new List<(string Name, string Value)>();
        if (creatorId is not null)
        {
            query.Add(item: ("searchCriteria.creatorId", creatorId));
        }
        if (reviewerId is not null)
        {
            query.Add(item: ("searchCriteria.reviewerId", reviewerId));
        }
        query.Add(item: ("searchCriteria.status", status));
        if (closedSince is { } since)
        {
            query.Add(item: ("searchCriteria.minTime", Iso(date: since)));
            query.Add(item: ("searchCriteria.queryTimeRangeType", "closed"));
        }
        query.Add(item: ("$top", Text(number: top)));
        query.Add(item: ("api-version", ApiVersion));
        return Url(baseUrl: Organizations, segments: [organization, "_apis", "git", "pullrequests"], query: query);
    }

    public static Uri PullRequest(string organization, int id) =>
        Url(baseUrl: Organizations, segments: [organization, "_apis", "git", "pullrequests", Text(number: id)], query: [("api-version", ApiVersion)]);

    /// Branch policies, such as builds, status checks and reviewer rules, and how each stands.
    public static Uri PolicyEvaluations(string organization, string projectId, int pullRequestId) =>
        Url(
            baseUrl: Organizations,
            segments: [organization, projectId, "_apis", "policy", "evaluations"],
            query: [("artifactId", "vstfs:///CodeReview/CodeReviewId/" + projectId + "/" + Text(number: pullRequestId)), ("api-version", "7.1-preview.1")]);

    public static Uri Threads(string organization, string projectId, string repositoryId, int pullRequestId) =>
        Url(
            baseUrl: Organizations,
            segments: [organization, projectId, "_apis", "git", "repositories", repositoryId, "pullRequests", Text(number: pullRequestId), "threads"],
            query: [("api-version", ApiVersion)]);

    /// The organizations of the member `memberId`.
    public static Uri Accounts(string memberId) =>
        Url(baseUrl: Profiles, segments: ["_apis", "accounts"], query: [("memberId", memberId), ("api-version", ApiVersion)]);

    /// A run's stages, jobs and tasks.
    public static Uri Timeline(string organization, string projectId, int buildId) =>
        Url(baseUrl: Organizations, segments: [organization, projectId, "_apis", "build", "builds", Text(number: buildId), "timeline"], query: [("api-version", ApiVersion)]);

    /// A repository branch's runs queued since a time, the oldest first: among them, those that build a merge.
    public static Uri BranchBuilds(string organization, string projectId, string repositoryId, string branch, DateTimeOffset queuedSince, int top = 50) =>
        Url(
            baseUrl: Organizations,
            segments: [organization, projectId, "_apis", "build", "builds"],
            query:
            [
                ("repositoryId", repositoryId),
                ("repositoryType", "TfsGit"),
                ("branchName", branch.StartsWith(value: "refs/", comparisonType: StringComparison.Ordinal) ? branch : "refs/heads/" + branch),
                ("minTime", Iso(date: queuedSince)),
                ("queryOrder", "queueTimeAscending"),
                ("$top", Text(number: top)),
                ("api-version", ApiVersion),
            ]);

    /// The project's runs that other runs started since a time, through pipeline-completion and resource triggers, the
    /// oldest first.
    public static Uri TriggeredBuilds(string organization, string projectId, DateTimeOffset queuedSince, int top = 50) =>
        Url(
            baseUrl: Organizations,
            segments: [organization, projectId, "_apis", "build", "builds"],
            query:
            [
                ("reasonFilter", "buildCompletion,resourceTrigger"),
                ("minTime", Iso(date: queuedSince)),
                ("queryOrder", "queueTimeAscending"),
                ("$top", Text(number: top)),
                ("api-version", ApiVersion),
            ]);

    /// A pull request's page, at one comment thread with `threadId`.
    public static Uri PullRequestPage(string organization, string project, string repository, int id, int? threadId = null) =>
        Url(
            baseUrl: Organizations,
            segments: [organization, project, "_git", repository, "pullrequest", Text(number: id)],
            query: threadId is { } thread ? [("discussionId", Text(number: thread))] : []);

    /// The organization's "My pull requests" page.
    public static Uri MyPullRequestsPage(string organization) => Url(baseUrl: Organizations, segments: [organization, "_pulls"], query: []);

    /// A run's page.
    public static Uri BuildPage(string organization, string project, int buildId) =>
        Url(baseUrl: Organizations, segments: [organization, project, "_build", "results"], query: [("buildId", Text(number: buildId))]);

    /// A URL from unencoded path segments and query items, everything but letters, digits and `-._~$` percent-encoded.
    public static Uri Url(string baseUrl, IReadOnlyList<string> segments, IReadOnlyList<(string Name, string Value)> query)
    {
        ArgumentNullException.ThrowIfNull(argument: baseUrl);
        ArgumentNullException.ThrowIfNull(argument: segments);
        ArgumentNullException.ThrowIfNull(argument: query);
        var text = new StringBuilder(value: baseUrl);
        foreach (var segment in segments)
        {
            text.Append(value: '/').Append(value: Encode(text: segment));
        }
        for (var index = 0; index < query.Count; index++)
        {
            text.Append(value: index == 0 ? '?' : '&').Append(value: Encode(text: query[index].Name)).Append(value: '=').Append(value: Encode(text: query[index].Value));
        }
        return new Uri(uriString: text.ToString(), uriKind: UriKind.Absolute);
    }

    /// `text`, UTF-8, with everything but letters, digits and `-._~$` percent-encoded.
    public static string Encode(string text)
    {
        ArgumentNullException.ThrowIfNull(argument: text);
        var encoded = new StringBuilder(capacity: text.Length);
        foreach (var value in Encoding.UTF8.GetBytes(s: text))
        {
            if (value is (>= (byte)'A' and <= (byte)'Z') or (>= (byte)'a' and <= (byte)'z') or (>= (byte)'0' and <= (byte)'9')
                or (byte)'-' or (byte)'.' or (byte)'_' or (byte)'~' or (byte)'$')
            {
                encoded.Append(value: (char)value);
            }
            else
            {
                encoded.Append(value: '%').Append(value: value.ToString(format: "X2", provider: CultureInfo.InvariantCulture));
            }
        }
        return encoded.ToString();
    }

    /// `2026-10-18T10:00:00Z`: a time as Azure DevOps takes it, to the second, in UTC.
    static string Iso(DateTimeOffset date) =>
        date.UtcDateTime.ToString(format: "yyyy-MM-dd'T'HH:mm:ss'Z'", provider: CultureInfo.InvariantCulture);

    static string Text(int number) => number.ToString(provider: CultureInfo.InvariantCulture);
}
