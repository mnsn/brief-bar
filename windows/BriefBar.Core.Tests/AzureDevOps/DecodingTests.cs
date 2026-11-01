using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

public sealed class DecodingTests
{
    [Fact]
    public void DecodesAPullRequestList()
    {
        var json = Fixture.List(items:
        [
            Fixture.PullRequest(
                id: 7,
                reviewers: [Fixture.Reviewer(person: People.Sam, vote: 10, required: true), Fixture.Reviewer(person: People.Priya, vote: -5)],
                draft: true),
        ]);
        var list = Fixture.Read(json: json, read: element => ADOList<ADOPullRequest>.Read(element: element, read: ADOPullRequest.Read));
        Assert.NotNull(@object: list);
        var pr = PullRequest.From(organization: "contoso", dto: Assert.Single(collection: list.Value));
        Assert.Equal(expected: new PRKey(Organization: "contoso", Number: 7), actual: pr.Key);
        Assert.Equal(expected: "Fix the checkout total", actual: pr.Title);
        Assert.Equal(expected: PullRequestStatus.Active, actual: pr.Status);
        Assert.True(condition: pr.IsDraft);
        Assert.Equal(expected: "fix-total", actual: pr.SourceBranch);
        Assert.Equal(expected: "main", actual: pr.TargetBranch);
        Assert.Equal(expected: People.Me, actual: pr.Author);
        Assert.Equal(expected: TestTimes.T(seconds: -2 * Make.Day), actual: pr.CreatedAt);
        Assert.Equal(expected: [Vote.Approved, Vote.WaitingForAuthor], actual: pr.Reviewers.Select(selector: reviewer => reviewer.Vote));
        Assert.True(condition: pr.Reviewers[0].IsRequired);
        Assert.Equal(expected: "Priya Shah", actual: pr.FindReviewer(id: People.Priya.Id.ToUpperInvariant())?.Person.Name);
        Assert.Equal(expected: "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7", actual: pr.WebUrl.AbsoluteUri);
        Assert.Equal(expected: "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7?discussionId=42", actual: pr.ThreadUrl(threadId: 42).AbsoluteUri);
    }

    [Fact]
    public void SkipsAnElementItCannotDecode()
    {
        var broken = Fixture.PullRequest(id: 8);
        broken["creationDate"] = "yesterday";
        var list = Fixture.Read(
            json: Fixture.List(items: [Fixture.PullRequest(id: 7), broken, Fixture.PullRequest(id: 9)]),
            read: element => ADOList<ADOPullRequest>.Read(element: element, read: ADOPullRequest.Read));
        Assert.NotNull(@object: list);
        Assert.Equal(expected: [7, 9], actual: list.Value.Select(selector: pr => pr.PullRequestId));
        Assert.Equal(expected: 1, actual: list.Skipped);
    }

    [Fact]
    public void ToleratesMissingOptionalFields()
    {
        var minimal = new JsonObject
        {
            ["pullRequestId"] = 3,
            ["title"] = "Minimal",
            ["status"] = "completed",
            ["createdBy"] = new JsonObject { ["id"] = "ABC" },
            ["creationDate"] = "2026-10-18T10:00:00Z",
            ["repository"] = new JsonObject { ["id"] = "r", ["name"] = "repo", ["project"] = new JsonObject { ["id"] = "p", ["name"] = "Project" } },
        };
        var dto = Fixture.Read(json: minimal, read: ADOPullRequest.Read);
        Assert.NotNull(@object: dto);
        var pr = PullRequest.From(organization: "contoso", dto: dto);
        Assert.Equal(expected: PullRequestStatus.Completed, actual: pr.Status);
        Assert.Empty(collection: pr.Reviewers);
        Assert.False(condition: pr.IsDraft);
        Assert.Equal(expected: "Someone", actual: pr.Author.Name);
        Assert.Equal(expected: "abc", actual: pr.Author.Id);
    }

    [Fact]
    public void ReadsThreadPropertiesOfAnyType()
    {
        var json = new JsonObject
        {
            ["id"] = 1,
            ["comments"] = new JsonArray(),
            ["properties"] = new JsonObject
            {
                ["CodeReviewThreadType"] = new JsonObject { ["$type"] = "System.String", ["$value"] = "RefUpdate" },
                ["CodeReviewRefNewCommitsCount"] = new JsonObject { ["$type"] = "System.Int32", ["$value"] = 3 },
                ["SupportsMarkdown"] = new JsonObject { ["$type"] = "System.Boolean", ["$value"] = true },
                ["Odd"] = "not an object",
            },
        };
        var thread = Fixture.Read(json: json, read: ADOThread.Read);
        Assert.NotNull(@object: thread);
        Assert.Equal(expected: "RefUpdate", actual: thread.ActivityType);
        Assert.Equal(expected: "3", actual: thread.Property(name: "CodeReviewRefNewCommitsCount"));
        Assert.Equal(expected: "true", actual: thread.Property(name: "SupportsMarkdown"));
        Assert.Null(@object: thread.Property(name: "Odd"));
    }

    [Fact]
    public void PolicySettingsOfAnUnexpectedTypeAreIgnored()
    {
        var json = Fixture.Evaluation(
            type: "Minimum number of reviewers", status: "queued", settings: new JsonObject { ["minimumApproverCount"] = "two", ["creatorVoteCounts"] = false });
        var evaluation = Fixture.Read(json: json, read: ADOPolicyEvaluation.Read);
        Assert.NotNull(@object: evaluation);
        Assert.Null(@object: evaluation.Configuration.Settings?.MinimumApproverCount);
        Assert.Equal(expected: "queued", actual: evaluation.Status);
    }
}
