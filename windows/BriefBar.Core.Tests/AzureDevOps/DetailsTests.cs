using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Ported from the `DetailsTests` suite in Tests/AzureDevOpsCoreTests/ClassifierTests.swift: what a pull request's
/// policies, threads and people read as.
public sealed class DetailsTests
{
    [Fact]
    public void BuildPolicies()
    {
        static CheckState? Build(string status, JsonObject? context) =>
            CheckFrom(evaluation: Fixture.Evaluation(type: "Build", status: status, settings: new JsonObject { ["displayName"] = "CI" }, context: context))?.State;

        Assert.Equal(expected: CheckState.Passed, actual: Build(status: "approved", context: RunContext()));
        Assert.Equal(expected: CheckState.Failed, actual: Build(status: "rejected", context: RunContext()));
        Assert.Equal(expected: CheckState.Failed, actual: Build(status: "broken", context: RunContext()));
        Assert.Equal(expected: CheckState.Running, actual: Build(status: "running", context: RunContext()));
        Assert.Equal(expected: CheckState.Queued, actual: Build(status: "queued", context: RunContext()));
        Assert.Equal(expected: CheckState.Expired, actual: Build(status: "queued", context: RunContext(expired: true)));
        Assert.Equal(expected: CheckState.Expired, actual: Build(status: "rejected", context: RunContext(expired: true)));
        Assert.Equal(expected: CheckState.NotRun, actual: Build(status: "queued", context: null));
        Assert.Equal(expected: CheckState.NotApplicable, actual: Build(status: "notApplicable", context: RunContext()));

        var named = CheckFrom(evaluation: Fixture.Evaluation(type: "Build", status: "approved", context: new JsonObject { ["buildDefinitionName"] = "web-ci" }));
        Assert.NotNull(@object: named);
        Assert.Equal(expected: "web-ci", actual: named.Name);
        Assert.Equal(expected: CheckKind.Build, actual: named.Kind);
        var unnamed = CheckFrom(evaluation: Fixture.Evaluation(type: "Build", status: "approved"));
        Assert.NotNull(@object: unnamed);
        Assert.Equal(expected: "Build", actual: unnamed.Name);
    }

    [Fact]
    public void StatusPolicies()
    {
        var failed = CheckFrom(evaluation: Fixture.Evaluation(type: "Status", status: "rejected", settings: new JsonObject { ["statusGenre"] = "security", ["statusName"] = "scan" }));
        Assert.NotNull(@object: failed);
        Assert.Equal(expected: CheckKind.Status, actual: failed.Kind);
        Assert.Equal(expected: CheckState.Failed, actual: failed.State);
        Assert.Equal(expected: "security/scan", actual: failed.Name);
        var named = CheckFrom(evaluation: Fixture.Evaluation(type: "Status", status: "queued", settings: new JsonObject { ["defaultDisplayName"] = "License check" }));
        Assert.NotNull(@object: named);
        Assert.Equal(expected: "License check", actual: named.Name);
        Assert.Equal(expected: CheckState.Pending, actual: named.State);
    }

    /// Requirements that aren't met yet are reported as "rejected": they're pending, not failures.
    [Fact]
    public void RequirementPolicies()
    {
        (string Type, CheckKind Kind)[] cases =
        [
            ("Minimum number of reviewers", CheckKind.Reviewers), ("Required reviewers", CheckKind.Reviewers), ("Proof Of Presence", CheckKind.Reviewers),
            ("Work item linking", CheckKind.Requirement), ("Comment requirements", CheckKind.Requirement), ("Something new", CheckKind.Requirement),
            ("Require a merge strategy", CheckKind.Completion),
        ];
        foreach (var (type, kind) in cases)
        {
            var pending = CheckFrom(evaluation: Fixture.Evaluation(type: type, status: "rejected"));
            Assert.NotNull(@object: pending);
            Assert.Equal(expected: kind, actual: pending.Kind);
            Assert.Equal(expected: CheckState.Pending, actual: pending.State);
            Assert.Equal(expected: CheckState.Passed, actual: CheckFrom(evaluation: Fixture.Evaluation(type: type, status: "approved"))?.State);
        }
        var minimum = CheckFrom(evaluation: Fixture.Evaluation(
            type: "Minimum number of reviewers", status: "queued", blocking: false, settings: new JsonObject { ["minimumApproverCount"] = 2 }));
        Assert.Equal(expected: 2, actual: minimum?.MinimumApprovers);
        Assert.False(condition: minimum?.IsBlocking);
        // Disabled policies are left out.
        Assert.Null(@object: CheckFrom(evaluation: Fixture.Evaluation(type: "Build", status: "rejected", enabled: false)));
    }

    /// Whom a required-reviewers policy requires, by identity ID, lowercased as reviewers' are; nothing when it doesn't say,
    /// says it some other way, or isn't about reviewers.
    [Fact]
    public void RequiredReviewerPoliciesSayWhomTheyRequire()
    {
        const string Id = "6B3C1F2A-0000-4000-8000-000000000001";
        static Check Read(string type, string status, JsonObject? settings = null)
        {
            var check = CheckFrom(evaluation: Fixture.Evaluation(type: type, status: status, settings: settings));
            Assert.NotNull(@object: check);
            return check;
        }
        var required = Read(type: "Required reviewers", status: "rejected", settings: new JsonObject { ["requiredReviewerIds"] = new JsonArray(items: [Id]), ["minimumApproverCount"] = 1 });
        Assert.Equal(expected: [Id.ToLowerInvariant()], actual: required.ReviewerIds.AsEnumerable());
        Assert.Equal(expected: 1, actual: required.MinimumApprovers);
        Assert.Empty(collection: Read(type: "Required reviewers", status: "rejected").ReviewerIds);
        Assert.Empty(collection: Read(type: "Required reviewers", status: "rejected", settings: new JsonObject { ["requiredReviewerIds"] = "odd" }).ReviewerIds);
        Assert.Empty(collection: Read(type: "Build", status: "approved", settings: new JsonObject { ["requiredReviewerIds"] = new JsonArray(items: [Id]) }).ReviewerIds);
        // An ID it can't read is left out, as a list's elements are.
        Assert.Equal(
            expected: [Id.ToLowerInvariant()],
            actual: Read(type: "Required reviewers", status: "rejected", settings: new JsonObject { ["requiredReviewerIds"] = new JsonArray(items: [7, Id]) }).ReviewerIds.AsEnumerable());
    }

    [Fact]
    public void SeparatesConversationsFromActivity()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved)]);
        var threads = Fixture.Read(
            json: Fixture.List(items:
            [
                Fixture.Thread(
                    id: 1,
                    comments:
                    [
                        Fixture.Comment(id: 1, author: People.Sam, content: "Please **rename** `x`", at: T(seconds: -3 * Make.Hour)),
                        Fixture.Comment(id: 2, author: People.Me, content: "Done", at: T(seconds: -2 * Make.Hour)),
                        Fixture.Comment(id: 3, author: People.Sam, content: "Deleted", at: T(seconds: -90 * Make.Minute), deleted: true),
                        Fixture.Comment(id: 4, author: People.Sam, content: "Status changed", at: T(seconds: -80 * Make.Minute), type: "system"),
                    ],
                    published: T(seconds: -3 * Make.Hour),
                    status: "fixed",
                    filePath: "/src/Cart/Total.cs"),
                Fixture.Activity(
                    id: 2, type: "VoteUpdate", at: T(seconds: -Make.Hour), by: People.Sam, properties: new Dictionary<string, string> { ["CodeReviewVoteResult"] = "10" }),
                Fixture.Activity(
                    id: 3,
                    type: "RefUpdate",
                    at: T(seconds: -30 * Make.Minute),
                    by: People.Me,
                    properties: new Dictionary<string, string> { ["CodeReviewRefNewCommitsCount"] = "2" }),
                Fixture.Activity(
                    id: 4,
                    type: "ReviewersUpdate",
                    at: T(seconds: -4 * Make.Hour),
                    by: People.Me,
                    properties: new Dictionary<string, string> { ["CodeReviewReviewersUpdatedAddedIdentity"] = "2" },
                    identities: new Dictionary<string, JsonNode> { ["2"] = Fixture.Identity(person: People.Priya) }),
                Fixture.Activity(id: 5, type: "ResetMultipleVotes", at: T(seconds: -20 * Make.Minute), by: People.Me),
                Fixture.Thread(
                    id: 6,
                    comments: [Fixture.Comment(id: 1, author: People.Sam, content: "Only deleted", at: T(seconds: -Make.Hour), deleted: true)],
                    published: T(seconds: -Make.Hour)),
            ]),
            read: element => ADOList<ADOThread>.Read(element: element, read: ADOThread.Read));
        Assert.NotNull(@object: threads);
        var details = PRDetails.From(fetchedAt: T(seconds: 0), pullRequest: pr, evaluations: [], threads: threads.Value);

        var thread = Assert.Single(collection: details.Threads);
        Assert.Equal(expected: ["Please rename x", "Done"], actual: thread.Comments.Select(selector: comment => comment.Text));
        Assert.Equal(expected: "Total.cs", actual: thread.FileName);
        Assert.Equal(expected: 12, actual: thread.Line);
        Assert.True(condition: thread.IsResolved);
        Assert.Equal(expected: "Sam Rivera", actual: thread.Comments[0].Author.Name);

        Assert.Equal(
            expected: [ActivityKind.ReviewersChanged, ActivityKind.Vote, ActivityKind.Push, ActivityKind.VotesReset],
            actual: details.Activity.Select(selector: item => item.Kind));
        Assert.Equal(expected: [People.Priya.Id], actual: details.Activity[0].Added);
        Assert.Equal(expected: Vote.Approved, actual: details.Activity[1].Vote);
        Assert.Equal(expected: People.Sam, actual: details.Activity[1].Actor);
        Assert.Equal(expected: 2, actual: details.Activity[2].CommitCount);
        Assert.Equal(expected: T(seconds: -20 * Make.Minute), actual: details.LastActivity);
        Assert.Equal(expected: pr.Fingerprint, actual: details.Fingerprint);
    }

    [Fact]
    public void RecognizesServiceIdentities()
    {
        Assert.True(condition: Person.From(identity: new ADOIdentity(Id: "1", DisplayName: "Shop Build Service (contoso)", UniqueName: "Build\\1234")).IsBot);
        Assert.True(condition: Person.From(identity: new ADOIdentity(Id: "1", DisplayName: "Release Bot", UniqueName: null)).IsBot);
        Assert.True(condition: Person.From(identity: new ADOIdentity(Id: "1", DisplayName: "Team", UniqueName: "[Shop]\\Team", IsContainer: true)).IsBot);
        Assert.False(condition: Person.From(identity: new ADOIdentity(Id: "1", DisplayName: "Sam Rivera", UniqueName: "sam@contoso.com")).IsBot);
        Assert.False(condition: Person.From(identity: new ADOIdentity(Id: "1", DisplayName: "Sam Rivera", UniqueName: null)).IsBot);
    }

    [Theory]
    [InlineData("Sam Rivera", "Sam")]
    [InlineData("Rivera, Sam", "Sam")]
    [InlineData("Sam", "Sam")]
    [InlineData("  ", "")]
    public void FirstNames(string name, string expected) =>
        Assert.Equal(expected: expected, actual: new Person(id: "1", name: name).FirstName);

    [Fact]
    public void PlainCommentText()
    {
        var names = new Dictionary<string, string> { [People.Me.Id] = "Robin Diaz" };
        var nobody = new Dictionary<string, string>();
        var mention = "@<" + People.Me.Id.ToUpperInvariant() + "> can you **check** [the docs](https://example.com)?";
        Assert.Equal(expected: "@Robin Diaz can you check the docs?", actual: CommentText.Plain(markdown: mention, names: names));
        Assert.Equal(expected: [People.Me.Id], actual: CommentText.MentionedIds(markdown: mention));
        Assert.Equal(expected: "@someone hi", actual: CommentText.Plain(markdown: "@<" + People.Sam.Id + "> hi", names: nobody));
        Assert.Equal(expected: "Use Task & await", actual: CommentText.Plain(markdown: "<div>Use&nbsp;<b>Task</b> &amp; await</div>", names: nobody));
        Assert.Equal(expected: "Try: var x = 1; thanks", actual: CommentText.Plain(markdown: "Try:\n```csharp\nvar x = 1;\n```\nthanks", names: nobody));
        var text = string.Concat(values: Enumerable.Repeat(element: "word ", count: 200));
        var shortened = CommentText.Plain(markdown: text, names: nobody, limit: 50);
        Assert.Equal(expected: 50, actual: shortened.Length);
        Assert.EndsWith(expectedEndString: "…", actualString: shortened, comparisonType: StringComparison.Ordinal);
    }

    [Fact]
    public void FingerprintFollowsWhatTheListReports()
    {
        var listed = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.None)]);
        var voted = listed with { Reviewers = [listed.Reviewers[0] with { Vote = Vote.Approved }] };
        var pushed = listed with { SourceCommit = "new" };
        var conflicted = listed with { MergeStatus = "conflicts" };
        var prints = new[] { listed, voted, pushed, conflicted }.Select(selector: pr => pr.Fingerprint);
        Assert.Equal(expected: 4, actual: prints.Distinct(comparer: StringComparer.Ordinal).Count());
        Assert.Equal(expected: Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.None)]).Fingerprint, actual: listed.Fingerprint);
    }

    /// A build policy's context once it has queued a run: run 1, which has expired or not.
    static JsonObject RunContext(bool expired = false) => new() { ["buildId"] = 1, ["isExpired"] = expired };

    /// The check `evaluation` reads as, as Azure DevOps would send it: null for a disabled policy.
    static Check? CheckFrom(JsonObject evaluation)
    {
        var read = Fixture.Read(json: evaluation, read: ADOPolicyEvaluation.Read);
        Assert.NotNull(@object: read);
        return Check.From(evaluation: read);
    }
}
