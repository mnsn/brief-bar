using System.Text.Json;
using System.Text.Json.Nodes;
using BriefBar.Core.GitHub;

namespace BriefBar.Core.Tests.GitHub;

/// Made-up pull requests, as GitHub's GraphQL API answers them and as BriefBar keeps them: the Swift tests' `Fixture`, at
/// their times (`TestTimes`).
internal static class GitHubFixture
{
    public const string Me = "robin";

    public const double Minute = 60;

    public const double Hour = 3_600;

    /// A pull request as GitHub's GraphQL API answers it.
    public static JsonObject PullRequest(
        int number,
        string repository = "octo/app",
        string? title = null,
        string? author = "priya",
        bool isDraft = false,
        DateTimeOffset? updated = null,
        string? reviewDecision = null,
        string mergeable = "MERGEABLE",
        string? rollup = null,
        IReadOnlyList<(string State, string? Author)>? reviews = null)
    {
        var changed = updated ?? TestTimes.T(seconds: 0);
        return new JsonObject
        {
            ["id"] = "PR_" + repository + "_" + number,
            ["number"] = number,
            ["title"] = title ?? "Pull request " + number,
            ["url"] = "https://github.com/" + repository + "/pull/" + number,
            ["isDraft"] = isDraft,
            ["createdAt"] = Iso(date: changed.AddHours(hours: -1)),
            ["updatedAt"] = Iso(date: changed),
            ["author"] = author is null ? null : new JsonObject { ["login"] = author },
            ["repository"] = new JsonObject { ["nameWithOwner"] = repository },
            ["reviewDecision"] = reviewDecision,
            ["mergeable"] = mergeable,
            ["commits"] = new JsonObject
            {
                ["nodes"] = new JsonArray(new JsonObject
                {
                    ["commit"] = new JsonObject { ["statusCheckRollup"] = rollup is null ? null : new JsonObject { ["state"] = rollup } },
                }),
            },
            ["latestOpinionatedReviews"] = new JsonObject
            {
                ["nodes"] = new JsonArray([.. (reviews ?? []).Select(selector: review => (JsonNode)new JsonObject
                {
                    ["state"] = review.State,
                    ["author"] = review.Author is null ? null : new JsonObject { ["login"] = review.Author },
                })]),
            },
        };
    }

    /// The whole answer to `PullRequestQuery`.
    public static JsonObject Answer(
        string login = Me,
        IReadOnlyList<JsonNode?>? reviewing = null,
        IReadOnlyList<JsonNode?>? authored = null,
        int? reviewingCount = null,
        int? authoredCount = null,
        JsonArray? errors = null)
    {
        var answer = new JsonObject
        {
            ["data"] = new JsonObject
            {
                ["viewer"] = new JsonObject { ["login"] = login },
                ["reviewing"] = Search(nodes: reviewing ?? [], count: reviewingCount),
                ["authored"] = Search(nodes: authored ?? [], count: authoredCount),
                ["rateLimit"] = new JsonObject { ["remaining"] = 4_990, ["resetAt"] = Iso(date: TestTimes.T(seconds: Hour)) },
            },
        };
        if (errors is not null)
        {
            answer["errors"] = errors;
        }
        return answer;
    }

    /// An error GitHub answers with.
    public static JsonObject Error(string message, string? type = null) => new() { ["type"] = type, ["message"] = message };

    /// A pull request decoded from GitHub's JSON, as the app reads it.
    public static GitHubPullRequest Decoded(JsonObject pullRequest)
    {
        using var document = JsonDocument.Parse(json: pullRequest.ToJsonString());
        return GitHubPullRequest.From(api: APIPullRequest.Read(element: document.RootElement) ?? throw new InvalidOperationException(message: "Can't read the pull request."));
    }

    /// What the answer's `data` holds, as the client reads it.
    public static PullRequestQueryData QueryData(JsonObject answer)
    {
        using var document = JsonDocument.Parse(json: answer["data"]!.ToJsonString());
        return PullRequestQueryData.Read(element: document.RootElement);
    }

    /// A pull request built directly, for the classifier.
    public static GitHubPullRequest Make(
        int number = 1,
        string? author = "priya",
        bool isDraft = false,
        DateTimeOffset? updated = null,
        GitHubReviewDecision? decision = null,
        bool conflicts = false,
        GitHubChecks? checks = null,
        IReadOnlyList<GitHubReview>? reviews = null,
        string? id = null)
    {
        var changed = updated ?? TestTimes.T(seconds: 0);
        return new GitHubPullRequest(
            Id: id ?? "PR_" + number,
            Number: number,
            Title: "Pull request " + number,
            Url: new Uri(uriString: "https://github.com/octo/app/pull/" + number),
            Repository: "octo/app",
            Author: author,
            CreatedAt: changed.AddHours(hours: -1),
            UpdatedAt: changed)
        {
            IsDraft = isDraft,
            ReviewDecision = decision,
            HasConflicts = conflicts,
            Checks = checks,
            Reviews = [.. reviews ?? []],
        };
    }

    /// As GitHub writes times: `2026-10-18T10:00:00Z`.
    public static string Iso(DateTimeOffset date) =>
        date.UtcDateTime.ToString(format: "yyyy-MM-dd'T'HH:mm:ss'Z'", provider: System.Globalization.CultureInfo.InvariantCulture);

    static JsonObject Search(IReadOnlyList<JsonNode?> nodes, int? count) => new()
    {
        ["issueCount"] = count ?? nodes.Count,
        ["nodes"] = new JsonArray([.. nodes.Select(selector: node => node?.DeepClone())]),
    };
}
