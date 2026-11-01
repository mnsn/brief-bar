using System.Text.Json;

namespace BriefBar.Core.GitHub;

/// The one query BriefBar sends to GitHub: who you are, the open pull requests that request your review by name, and your
/// own open pull requests, with what decides where each one goes. It reads, and changes nothing. The Mac's
/// `PullRequestQuery`.
public static class PullRequestQuery
{
    /// Review requests for you by name. A request for one of your teams alone isn't in it.
    public const string ReviewingSearch = "is:pr is:open archived:false user-review-requested:@me sort:updated-desc";

    public const string AuthoredSearch = "is:pr is:open archived:false author:@me sort:updated-desc";

    /// Each search's most recently updated; more than this is unusual, and the list says so.
    public const int Count = 50;

    /// Fixed text: only the search strings and the count are variables. Its lines end as the Mac's do, whatever the
    /// checkout's line endings.
    public static string Text { get; } = """
        query BriefBarPullRequests($reviewing: String!, $authored: String!, $count: Int!) {
          viewer { login }
          reviewing: search(query: $reviewing, type: ISSUE, first: $count) { issueCount nodes { ...BriefBarPullRequest } }
          authored: search(query: $authored, type: ISSUE, first: $count) { issueCount nodes { ...BriefBarPullRequest } }
          rateLimit { remaining resetAt }
        }
        fragment BriefBarPullRequest on PullRequest {
          id number title url isDraft createdAt updatedAt headRefName
          author { login }
          repository { nameWithOwner }
          reviewDecision
          mergeable
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
        }
        """.ReplaceLineEndings(replacementText: "\n");

    /// What's sent: the query, with its searches and count, as JSON.
    public static byte[] Body()
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(utf8Json: buffer))
        {
            json.WriteStartObject();
            json.WriteString(propertyName: "query", value: Text);
            json.WriteStartObject(propertyName: "variables");
            json.WriteString(propertyName: "reviewing", value: ReviewingSearch);
            json.WriteString(propertyName: "authored", value: AuthoredSearch);
            json.WriteNumber(propertyName: "count", value: Count);
            json.WriteEndObject();
            json.WriteEndObject();
        }
        return buffer.ToArray();
    }
}
