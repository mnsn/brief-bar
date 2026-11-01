using System.Text.Json;

namespace BriefBar.Core.GitHub;

/// How much of GitHub's hourly limit for the GraphQL API is left, and when it's renewed, as the query reads it. The Mac's
/// `PullRequestQueryData.RateLimit`.
public sealed record GitHubRateLimit(int Remaining, DateTimeOffset ResetAt)
{
    /// The limit in `element`, or null when it can't be read.
    internal static GitHubRateLimit? Read(JsonElement element) =>
        LenientJson.WholeNumber(element: element, name: "remaining") is { } remaining && LenientJson.Date(element: element, name: "resetAt") is { } resetAt
            ? new GitHubRateLimit(Remaining: remaining, ResetAt: resetAt)
            : null;
}
