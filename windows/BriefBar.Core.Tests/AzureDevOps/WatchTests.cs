using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Pull requests you watch by their links, though you're not on them.
public sealed class WatchTests
{
    [Fact]
    public void OneYouWatchIsListedAsIfYouReviewedIt()
    {
        var pr = Make.PR(author: People.Alex);
        var record = new PRRecord(pullRequest: pr, role: PRRole.Linked, me: People.Me.Id, details: Make.Details(pr: pr, lastActivity: T(seconds: -Make.Hour)));
        // Not watched, and not sent in a chat: not listed.
        Assert.Null(@object: Classify(record: record));

        var watched = record.Watched();
        Assert.Equal(expected: PRRole.Reviewer, actual: watched.Role);
        Assert.True(condition: watched.IsWatched);
        var snapshot = Classify(record: watched);
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.ToReview, actual: snapshot.Group);
        Assert.Equal(expected: "Watching", actual: snapshot.Headline);
        Assert.Equal(expected: "By Alex Kim", actual: snapshot.Detail);
        Assert.True(condition: snapshot.IsWatched);

        // A mention there needs you, as on any review.
        var mention = new ReviewThread(Id: 3, Comments: [Make.Comment(id: 1, author: People.Alex, at: T(seconds: -Make.Minute), text: "@Robin could you look?", mentions: [People.Me])]);
        var mentioned = new PRRecord(pullRequest: pr, role: PRRole.Linked, me: People.Me.Id, details: Make.Details(pr: pr, threads: [mention])).Watched();
        Assert.Equal(expected: PRReason.Mentioned, actual: Classify(record: mentioned)?.Reason);

        // Once you're a reviewer, or it's yours, it's that.
        var named = Make.PR(author: People.Alex, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.None, IsRequired: true)]);
        var review = new PRRecord(pullRequest: named, role: PRRole.Reviewer, me: People.Me.Id, details: Make.Details(pr: named, lastActivity: T(seconds: -Make.Hour)));
        Assert.Equal(expected: "Required review", actual: Classify(record: review.Watched())?.Headline);
        Assert.Equal(expected: PRRole.Author, actual: new PRRecord(pullRequest: Make.PR(), role: PRRole.Author, me: People.Me.Id).Watched().Role);
    }

    [Fact]
    public async Task LinksToPullRequestsThatClosedOrAreGoneAreReported()
    {
        var server = new StubServer();
        server.ServeOrganization();
        server.On(path: "/contoso/_apis/git/pullrequests/8", json: Fixture.PullRequest(id: 8, author: People.Alex));
        server.On(path: "/contoso/_apis/git/pullrequests/9", json: Fixture.PullRequest(id: 9, author: People.Alex, status: "completed", closed: T(seconds: 0)));
        server.On(path: "/contoso/_apis/git/pullrequests/10", reply: _ => StubReply.Code(status: 404));
        server.On(path: "/contoso/_apis/git/pullrequests/11", reply: _ => StubReply.Code(status: 500));
        using var client = server.Client();
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, onChange: _ => { });
        engine.SetLinkedPullRequests(keys: new HashSet<PRKey> { Key(number: 8), Key(number: 9), Key(number: 10), Key(number: 11) });
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [8], actual: snapshot.Records.Select(selector: record => record.Id.Number));
        // A failure that may pass isn't a reason to stop watching.
        Assert.Equal(expected: [Key(number: 9), Key(number: 10)], actual: snapshot.ClosedLinks.Order());

        // Not asked for anymore: not reported.
        engine.SetLinkedPullRequests(keys: new HashSet<PRKey> { Key(number: 8), Key(number: 10) });
        Assert.Equal(expected: [Key(number: 10)], actual: engine.CurrentSnapshot().ClosedLinks.Order());
    }

    /// Organization names are case-insensitive in Azure DevOps: a pull request you watch by a link that spells its
    /// organization another way is the one your lists have, listed once, as they spell it.
    [Fact]
    public async Task OneYouWatchByALinkSpelledAnotherWayIsTheOneListed()
    {
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 8)]);
        // Azure DevOps would answer the link's spelling too.
        server.On(path: "/CONTOSO/_apis/connectionData", json: new JsonObject
        {
            ["authenticatedUser"] = new JsonObject { ["id"] = Fixture.Me.ToUpperInvariant() },
        });
        server.On(path: "/CONTOSO/_apis/git/pullrequests/8", json: Fixture.PullRequest(id: 8));
        using var client = server.Client();
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, onChange: _ => { });
        engine.SetLinkedPullRequests(keys: new HashSet<PRKey> { new(Organization: "CONTOSO", Number: 8) });
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);

        var record = Assert.Single(collection: engine.CurrentSnapshot().Records);
        Assert.Equal(expected: Key(number: 8), actual: record.Id);
        Assert.Equal(expected: Fixture.Org, actual: record.Id.Organization);
        Assert.Equal(expected: PRRole.Author, actual: record.Role);
        Assert.DoesNotContain(collection: server.Requests, filter: request => request.Path.Contains(value: "/CONTOSO/", comparisonType: StringComparison.Ordinal));
    }

    /// What the panel says of `record` at the reference time, when you last looked a day before.
    static PRSnapshot? Classify(PRRecord record) =>
        PRClassifier.Snapshot(record: record, seenCutoff: T(seconds: -Make.Day), dismissedCutoff: T(seconds: -Make.Day), now: T(seconds: 0));

    static PRKey Key(int number) => new(Organization: Fixture.Org, Number: number);
}
