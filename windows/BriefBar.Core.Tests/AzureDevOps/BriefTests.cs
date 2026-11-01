using System.Globalization;
using BriefBar.Core.AzureDevOps;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Ported from the sentence checks of `briefSummarizesAcrossGroupsAndPromptsOneItemAtATime`, in the `NotificationTests`
/// suite of Tests/AzureDevOpsCoreTests/EngineTests.swift, with a test for each kind of sentence the Mac's `Brief.item` says.
/// BriefBar for Windows has only those sentences: not `Brief.items`, which picks what a brief says, nor the prompts its
/// summaries are worded with.
public sealed class BriefTests
{
    /// The Mac's brief says the newest of each group, 3, 4 and 5, rather than everything that needs you; with fewer groups,
    /// more of what needs you, 3 and 6. These are their sentences.
    [Fact]
    public void BriefSummarizesAcrossGroupsAndPromptsOneItemAtATime()
    {
        var mention = new PREvent(
            Id: "c1.1", Kind: PREventKind.Mention, At: T(seconds: 0), Actor: "Priya Shah", Text: "@Robin Diaz can you check the cache headers?", ThreadId: 1);
        PRSnapshot[] snapshots =
        [
            Snapshot(number: 1, group: PRGroup.Waiting),
            Snapshot(number: 2, group: PRGroup.Ready, reason: PRReason.ReadyToComplete, since: T(seconds: -10)),
            Snapshot(number: 3, group: PRGroup.NeedsYou, reason: PRReason.Mentioned, events: [mention], since: T(seconds: -5)),
            Snapshot(number: 4, group: PRGroup.Failing, reason: PRReason.BuildFailed, detail: "web-ci", since: T(seconds: -1)),
            Snapshot(number: 5, group: PRGroup.Ready, reason: PRReason.AutoComplete, since: T(seconds: -2)),
            Snapshot(number: 6, group: PRGroup.NeedsYou, reason: PRReason.ReviewRequested, since: T(seconds: -20)),
        ];
        var items = new[] { snapshots[2], snapshots[3], snapshots[4] }.Select(selector: snapshot => Brief.Item(snapshot: snapshot)).ToList();
        Assert.Equal(expected: "Priya Shah mentioned you on “Pull request 3”.", actual: items[0].Sentence);
        Assert.Equal(expected: "“Pull request 4” failed: web-ci.", actual: items[1].Sentence);
        Assert.Equal(expected: "“Pull request 5” is approved and will complete automatically.", actual: items[2].Sentence);

        // With fewer groups, more of what needs you.
        Assert.Equal(expected: "Sam Rivera asked you to review “Pull request 6”.", actual: Brief.Item(snapshot: snapshots[5]).Sentence);
    }

    [Fact]
    public void AMentionSaysWhoMentionedYou()
    {
        var mention = new PREvent(
            Id: "c1.1", Kind: PREventKind.Mention, At: T(seconds: 0), Actor: "Priya Shah", Text: "@Robin Diaz can you check the cache headers?", ThreadId: 1);
        Assert.Equal(
            expected: "Priya Shah mentioned you on “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.Mentioned, events: [mention])));
    }

    [Fact]
    public void AReplySaysWhoReplied()
    {
        var reply = new PREvent(Id: "c1.2", Kind: PREventKind.Reply, At: T(seconds: 10), Actor: "Sam Rivera", Text: "Cap it at 30 s", ThreadId: 1);
        Assert.Equal(
            expected: "Sam Rivera replied on “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.Replied, events: [reply])));
    }

    [Fact]
    public void ACommentSaysWhoCommented()
    {
        var comment = new PREvent(Id: "c2.1", Kind: PREventKind.Comment, At: T(seconds: 10), Actor: "Alex Kim", Text: "Nit: typo", ThreadId: 2);
        Assert.Equal(
            expected: "Alex Kim commented on “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.Commented, events: [comment])));
    }

    /// Who did it is who did what its reason says, or else who did the newest of what needs you, or else someone: an
    /// approval is news, but doesn't need you.
    [Fact]
    public void TheEventOfItsReasonSaysWhoDidIt()
    {
        var approval = new PREvent(Id: "v4", Kind: PREventKind.Approved, At: T(seconds: 30), Actor: "Alex Kim");
        var mention = new PREvent(Id: "c2.1", Kind: PREventKind.Mention, At: T(seconds: 20), Actor: "Priya Shah", ThreadId: 2);
        var changes = new PREvent(Id: "v3", Kind: PREventKind.ChangesRequested, At: T(seconds: 15), Actor: "Priya Shah");
        var reply = new PREvent(Id: "c1.2", Kind: PREventKind.Reply, At: T(seconds: 10), Actor: "Sam Rivera", ThreadId: 1);
        Assert.Equal(
            expected: "Sam Rivera replied on “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.Replied, events: [approval, mention, reply])));
        Assert.Equal(
            expected: "Priya Shah is waiting for changes on “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.ChangesRequested, events: [approval, changes, reply])));
        Assert.Equal(
            expected: "Someone commented on “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.Commented, events: [approval])));
    }

    [Fact]
    public void ALinkSentToYouSaysWhoSentItAndWhere()
    {
        var sent = new PREvent(Id: "scom.microsoft.teams2|n1#contoso/1", Kind: PREventKind.SentInChat, At: T(seconds: 0), Actor: "Dana Whitfield", App: "Teams");
        Assert.Equal(
            expected: "Dana Whitfield sent you “Pull request 1” in Teams.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.SentInChat, events: [sent])));
        // Without the app, who sent it.
        Assert.Equal(
            expected: "Dana Whitfield sent you “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.SentInChat, events: [sent with { App = null }])));
    }

    /// Its author asks you.
    [Fact]
    public void AReviewRequestSaysWhoAskedYou()
    {
        var request = new PREvent(Id: "r3", Kind: PREventKind.ReviewRequest, At: T(seconds: 20), Actor: "Sam Rivera", Text: "Required reviewer");
        Assert.Equal(
            expected: "Sam Rivera asked you to review “Pull request 6”.",
            actual: Sentence(snapshot: Snapshot(number: 6, group: PRGroup.NeedsYou, reason: PRReason.ReviewRequested, events: [request])));
    }

    [Fact]
    public void NewCommitsSinceYourVote()
    {
        var commits = new PREvent(Id: "p3", Kind: PREventKind.NewCommits, At: T(seconds: 0), Actor: "Sam Rivera", Count: 3);
        Assert.Equal(
            expected: "“Pull request 1” has new commits since your vote.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.NewCommits, events: [commits])));
    }

    [Fact]
    public void AVoteForChangesSaysWhoWaitsForThem()
    {
        var vote = new PREvent(Id: "v3", Kind: PREventKind.ChangesRequested, At: T(seconds: 15), Actor: "Alex Kim");
        Assert.Equal(
            expected: "Alex Kim is waiting for changes on “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.ChangesRequested, events: [vote])));
    }

    [Fact]
    public void ARejectionSaysWhoRejectedItWhileItNeedsYou()
    {
        var vote = new PREvent(Id: "v2", Kind: PREventKind.Rejected, At: T(seconds: 0), Actor: "Priya Shah");
        Assert.Equal(
            expected: "Priya Shah rejected “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.Rejected, events: [vote])));
        // Once you've seen it, it waits.
        Assert.Equal(
            expected: "“Pull request 1” was rejected.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.Waiting, reason: PRReason.Rejected, headline: "Rejected", detail: "Priya Shah")));
    }

    /// A vote for changes, or a rejection, names a pull request's reason before a comment does: whoever commented since,
    /// it says who voted.
    [Fact]
    public void AVoteSaysWhoVotedThoughSomeoneCommentedSince()
    {
        var comment = new PREvent(Id: "c2.1", Kind: PREventKind.Comment, At: T(seconds: 20), Actor: "Alex Kim", Text: "Nit: typo", ThreadId: 2);
        var changes = new PREvent(Id: "v3", Kind: PREventKind.ChangesRequested, At: T(seconds: 15), Actor: "Priya Shah");
        var rejection = new PREvent(Id: "v2", Kind: PREventKind.Rejected, At: T(seconds: 15), Actor: "Priya Shah");
        Assert.Equal(
            expected: "Priya Shah is waiting for changes on “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.ChangesRequested, events: [comment, changes])));
        Assert.Equal(
            expected: "Priya Shah rejected “Pull request 1”.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.NeedsYou, reason: PRReason.Rejected, events: [comment, rejection])));
    }

    [Fact]
    public void AFailedBuildSaysWhereItFailed()
    {
        var failed = Snapshot(
            number: 1, group: PRGroup.Failing, reason: PRReason.BuildFailed, headline: "Build failed", detail: "web-ci · Run unit tests: 2 tests failed in CheckoutTests.") with
        {
            Failure = new PipelineFailure(Stage: "Test", Step: "Run unit tests", Message: "2 tests failed in CheckoutTests."),
        };
        Assert.Equal(expected: "“Pull request 1” failed at Run unit tests.", actual: Sentence(snapshot: failed));
    }

    /// Until its timeline says where it failed, what failed, when that's said.
    [Fact]
    public void AFailedBuildWithoutWhereItFailedSaysWhatFailed()
    {
        Assert.Equal(
            expected: "“Pull request 4” failed: web-ci.",
            actual: Sentence(snapshot: Snapshot(number: 4, group: PRGroup.Failing, reason: PRReason.BuildFailed, headline: "Build failed", detail: "web-ci")));
        Assert.Equal(
            expected: "“Pull request 4” failed.",
            actual: Sentence(snapshot: Snapshot(number: 4, group: PRGroup.Failing, reason: PRReason.BuildFailed, headline: "Build failed")));
    }

    [Fact]
    public void AFailedCheckSaysWhatFailed() =>
        Assert.Equal(
            expected: "“Pull request 1” failed: scan.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.Failing, reason: PRReason.CheckFailed, headline: "Check failed", detail: "scan")));

    [Fact]
    public void MergeConflicts() =>
        Assert.Equal(
            expected: "“Pull request 1” has merge conflicts.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.Failing, reason: PRReason.Conflicts, headline: "Merge conflicts", detail: "fix-total into main")));

    [Fact]
    public void AnExpiredBuildIsQueuedAgain() =>
        Assert.Equal(
            expected: "“Pull request 1” needs its build queued again.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.Failing, reason: PRReason.BuildExpired, headline: "Build expired", detail: "web-ci · queue it again")));

    [Fact]
    public void ReadyToComplete() =>
        Assert.Equal(
            expected: "“Pull request 2” is approved and ready to complete.",
            actual: Sentence(snapshot: Snapshot(number: 2, group: PRGroup.Ready, reason: PRReason.ReadyToComplete, headline: "Ready to complete", detail: "Approved by Sam Rivera")));

    [Fact]
    public void CompletingAutomatically() =>
        Assert.Equal(
            expected: "“Pull request 5” is approved and will complete automatically.",
            actual: Sentence(snapshot: Snapshot(number: 5, group: PRGroup.Ready, reason: PRReason.AutoComplete, headline: "Completing automatically")));

    [Fact]
    public void APipelineThatFailedAfterTheMergeIsNamed()
    {
        var merge = new MergeSummary(
            Outcome: MergeOutcome.Failed,
            Total: 2,
            Pipeline: "shop-web deploy",
            Stage: "Deploy",
            Failure: new PipelineFailure(Stage: "Deploy", Step: "Swap slots", Message: null),
            RunId: 88);
        var failed = Snapshot(number: 1, group: PRGroup.Failing, reason: PRReason.FailedAfterMerge, headline: "Failed after merge", detail: "shop-web deploy · Swap slots failed") with
        {
            Merge = merge,
        };
        Assert.Equal(expected: "“shop-web deploy” failed after “Pull request 1” merged.", actual: Sentence(snapshot: failed));
        // Without its name, a pipeline.
        Assert.Equal(expected: "A pipeline failed after “Pull request 1” merged.", actual: Sentence(snapshot: failed with { Merge = merge with { Pipeline = null } }));
    }

    [Fact]
    public void APipelineThatWaitsForApprovalAfterTheMergeIsNamed()
    {
        var merge = new MergeSummary(Outcome: MergeOutcome.Waiting, Total: 1, Running: 1, Pipeline: "shop-web release", Stage: "Production", RunId: 90);
        var waiting = Snapshot(number: 1, group: PRGroup.Done, reason: PRReason.WaitingForApproval, headline: "Waiting for approval", detail: "shop-web release · Production") with
        {
            Merge = merge,
        };
        Assert.Equal(expected: "“shop-web release” waits for approval after “Pull request 1” merged.", actual: Sentence(snapshot: waiting));
        // Without its name, a pipeline.
        Assert.Equal(expected: "A pipeline waits for approval after “Pull request 1” merged.", actual: Sentence(snapshot: waiting with { Merge = merge with { Pipeline = null } }));
    }

    /// The rest say their headline.
    [Fact]
    public void AnythingElseSaysItsHeadline()
    {
        Assert.Equal(
            expected: "“Pull request 1”: Waiting for reviewers.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.Waiting, reason: PRReason.WaitingForReviewers, headline: "Waiting for reviewers")));
        Assert.Equal(
            expected: "“Pull request 1”: You approved.",
            actual: Sentence(snapshot: Snapshot(number: 1, group: PRGroup.Idle, reason: PRReason.YouApproved, headline: "You approved")));
    }

    /// An item is its pull request's, named by the news it says: the same news is the same item, and newer news another.
    [Fact]
    public void AnItemIsNamedByItsPullRequestAndItsNews()
    {
        var mention = new PREvent(Id: "c1.1", Kind: PREventKind.Mention, At: T(seconds: 0), Actor: "Priya Shah", ThreadId: 1);
        var snapshot = Snapshot(number: 3, group: PRGroup.NeedsYou, reason: PRReason.Mentioned, events: [mention]);
        var item = Brief.Item(snapshot: snapshot);
        Assert.Equal(expected: snapshot.Key, actual: item.Key);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: item.Group);
        Assert.Equal(expected: PRReason.Mentioned, actual: item.Reason);
        Assert.Equal(expected: snapshot.Url, actual: item.Url);
        Assert.StartsWith(expectedStartString: "contoso/3:", actualString: item.Id, comparisonType: StringComparison.Ordinal);
        Assert.EndsWith(expectedEndString: ":c1.1", actualString: item.Id, comparisonType: StringComparison.Ordinal);
        Assert.Equal(expected: item.Id, actual: Brief.Item(snapshot: snapshot with { Since = T(seconds: 60) }).Id);
        var another = mention with { Id = "c2.1", At = T(seconds: 30), ThreadId = 2 };
        Assert.NotEqual(expected: item.Id, actual: Brief.Item(snapshot: snapshot with { Events = [another, mention] }).Id);
    }

    /// Pull request `number` in contoso's shop-web, by Sam Rivera, as the Mac's `NotificationTests` make one.
    static PRSnapshot Snapshot(
        int number,
        PRGroup group,
        PRReason reason = PRReason.WaitingForReviewers,
        IEnumerable<PREvent>? events = null,
        string headline = "Headline",
        string? detail = null,
        DateTimeOffset? since = null) => new()
        {
            Key = new PRKey(Organization: "contoso", Number: number),
            Title = "Pull request " + Text(number: number),
            Repository = "shop-web",
            Project = "Shop",
            Author = "Sam Rivera",
            Role = PRRole.Author,
            Group = group,
            Reason = reason,
            Headline = headline,
            Detail = detail,
            Since = since ?? T(seconds: 0),
            Url = new Uri(uriString: "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/" + Text(number: number)),
            Events = new ValueList<PREvent>(items: events ?? []),
            HasDetails = true,
        };

    static string Sentence(PRSnapshot snapshot) => Brief.Item(snapshot: snapshot).Sentence;

    static string Text(int number) => number.ToString(provider: CultureInfo.InvariantCulture);
}
