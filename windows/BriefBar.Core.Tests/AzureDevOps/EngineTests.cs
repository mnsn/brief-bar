using System.Diagnostics;
using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// The engine against a made-up Azure DevOps: what it reads, with GET requests only, when, and what it keeps when Azure
/// DevOps, the Azure CLI or the network fail.
public sealed class EngineTests
{
    /// Your active pull requests' list.
    static readonly IReadOnlyDictionary<string, string> yourActiveList =
        new Dictionary<string, string> { ["searchCriteria.status"] = "active", ["searchCriteria.creatorId"] = Fixture.Me };

    /// Details due on every refresh, though the pull requests don't change.
    static readonly RefreshPlannerOptions detailsEveryRefresh = new() { BusyInterval = TimeSpan.Zero, ActiveInterval = TimeSpan.Zero, QuietInterval = TimeSpan.Zero };

    [Fact]
    public async Task LoadsListsAndDetailsWithGETRequestsOnly()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        server.ServeOrganization(
            mine: [Fixture.PullRequest(id: 1, title: "Mine", reviewers: [Fixture.Reviewer(person: People.Sam, vote: 10)], created: now.AddSeconds(seconds: -Make.Day))],
            reviewing:
            [
                Fixture.PullRequest(id: 2, title: "Theirs", author: People.Sam, reviewers: [Fixture.Reviewer(person: People.Me)], created: now.AddSeconds(seconds: -Make.Hour)),
                // Your own pull request shows up here when you're a reviewer on it too; it's yours.
                Fixture.PullRequest(id: 1, title: "Mine", created: now.AddSeconds(seconds: -Make.Day)),
            ],
            completed: [Fixture.PullRequest(id: 3, title: "Merged", created: now.AddSeconds(seconds: -Make.Day), status: "completed", closed: now.AddSeconds(seconds: -Make.Hour))]);
        server.On(
            path: "/_apis/policy/evaluations",
            json: Fixture.List(items:
            [
                Fixture.Evaluation(type: "Build", status: "rejected", settings: new JsonObject { ["displayName"] = "web-ci" }, context: new JsonObject { ["buildId"] = 4, ["isExpired"] = false }),
            ]),
            query: PoliciesOf(number: 1));
        server.On(path: "/p1/_apis/build/builds/4/timeline", json: BuildFixture.Timeline(records:
        [
            BuildFixture.Record(id: "s", type: "Stage", name: "Test", result: "failed"),
            BuildFixture.Record(id: "t", type: "Task", name: "Run unit tests", parent: "s", result: "failed", issues: [BuildFixture.Issue(message: "2 tests failed in CheckoutTests.")]),
        ]));
        server.On(path: "/pullRequests/2/threads", json: Fixture.List(items:
        [
            Fixture.Thread(
                id: 7,
                comments: [Fixture.Comment(id: 1, author: People.Sam, content: "Hi @<" + People.Me.Id + ">", at: now.AddSeconds(seconds: -Make.Minute))],
                published: now.AddSeconds(seconds: -Make.Minute)),
        ]));

        using var client = server.Client();
        var snapshot = await PulseEngine.LoadOnceAsync(
            client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Null(@object: snapshot.Problem);
        Assert.True(condition: snapshot.HasLoaded);
        Assert.Equal(expected: [1, 2, 3], actual: snapshot.Records.Select(selector: record => record.Id.Number));
        Assert.Equal(expected: [PRRole.Author, PRRole.Reviewer, PRRole.Author], actual: snapshot.Records.Select(selector: record => record.Role));
        Assert.All(collection: snapshot.Records, action: record => Assert.Equal(expected: People.Me.Id, actual: record.Me));
        Assert.NotNull(@object: snapshot.Records[0].Details);
        Assert.NotNull(@object: snapshot.Records[1].Details);
        Assert.Null(@object: snapshot.Records[2].Details);

        var items = Classify(snapshot: snapshot, now: now);
        Assert.Equal(expected: PRGroup.Failing, actual: items.GetValueOrDefault(key: 1)?.Group);
        Assert.Equal(expected: "web-ci · Run unit tests: 2 tests failed in CheckoutTests.", actual: items.GetValueOrDefault(key: 1)?.Detail);
        Assert.Equal(expected: PRReason.Mentioned, actual: items.GetValueOrDefault(key: 2)?.Reason);
        Assert.Equal(expected: "Hi @Robin Diaz", actual: items.GetValueOrDefault(key: 2)?.Detail);
        Assert.Equal(expected: PRGroup.Done, actual: items.GetValueOrDefault(key: 3)?.Group);

        AssertOnlyGets(server: server);
        // connectionData, three lists, two requests for each of the two active pull requests, and the failed build's
        // timeline.
        Assert.Equal(expected: 9, actual: server.Requests.Count);
    }

    [Fact]
    public async Task ReadsWhereEachFailedBuildFailedOnce()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1, created: now.AddSeconds(seconds: -Make.Day)), Fixture.PullRequest(id: 2, created: now.AddSeconds(seconds: -Make.Day))]);
        static JsonObject FailedBuildEvaluation(int id, DateTimeOffset completed) =>
            Fixture.Evaluation(type: "Build", status: "rejected", settings: new JsonObject { ["displayName"] = "web-ci" }, context: new JsonObject { ["buildId"] = id }, completed: completed);
        server.On(path: "/_apis/policy/evaluations", json: Fixture.List(items: [FailedBuildEvaluation(id: 4, completed: now.AddSeconds(seconds: -Make.Hour))]), query: PoliciesOf(number: 1));
        server.On(path: "/_apis/policy/evaluations", json: Fixture.List(items: [FailedBuildEvaluation(id: 5, completed: now.AddSeconds(seconds: -Make.Hour))]), query: PoliciesOf(number: 2));
        server.On(path: "/builds/4/timeline", json: BuildFixture.Timeline(records:
        [
            BuildFixture.Record(id: "t", type: "Task", name: "Compile", result: "failed", issues: [BuildFixture.Issue(message: "CS0103")]),
        ]));
        // Build 5's timeline isn't there.
        using var client = server.Client();
        using var engine = new PulseEngine(
            client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org], Planner = detailsEveryRefresh }, onChange: _ => { });
        int TimelineRequests(int build) =>
            server.Requests.Count(predicate: request => request.Path.EndsWith(value: "/builds/" + Fixture.Text(number: build) + "/timeline", comparisonType: StringComparison.Ordinal));

        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var items = Classify(snapshot: engine.CurrentSnapshot(), now: now);
        Assert.Equal(expected: "web-ci · Compile: CS0103", actual: items.GetValueOrDefault(key: 1)?.Detail);
        Assert.Equal(expected: "web-ci", actual: items.GetValueOrDefault(key: 2)?.Detail);
        Assert.Null(@object: items.GetValueOrDefault(key: 2)?.Failure);

        // Neither is read again while the builds stay as they were, though the details are.
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 1, actual: TimelineRequests(build: 4));
        Assert.Equal(expected: 1, actual: TimelineRequests(build: 5));
        Assert.Equal(expected: "Compile", actual: Classify(snapshot: engine.CurrentSnapshot(), now: now).GetValueOrDefault(key: 1)?.Failure?.Step);

        // Retried, build 4 fails again later, somewhere else: its timeline is read again.
        server.On(path: "/_apis/policy/evaluations", json: Fixture.List(items: [FailedBuildEvaluation(id: 4, completed: now)]), query: PoliciesOf(number: 1));
        server.On(path: "/builds/4/timeline", json: BuildFixture.Timeline(records: [BuildFixture.Record(id: "t", type: "Task", name: "Run unit tests", result: "failed")]));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 2, actual: TimelineRequests(build: 4));
        items = Classify(snapshot: engine.CurrentSnapshot(), now: now);
        Assert.Equal(expected: "web-ci · Run unit tests failed", actual: items.GetValueOrDefault(key: 1)?.Detail);
        Assert.All(collection: server.Requests, action: request => Assert.Equal(expected: HttpMethod.Get, actual: request.Method));
    }

    [Fact]
    public async Task ATimelineThatCantBeReadIsTriedAgainLater()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1, created: now.AddSeconds(seconds: -Make.Day))]);
        server.On(path: "/_apis/policy/evaluations", json: Fixture.List(items:
        [
            Fixture.Evaluation(type: "Build", status: "rejected", settings: new JsonObject { ["displayName"] = "web-ci" }, context: new JsonObject { ["buildId"] = 4 }),
        ]));
        server.On(path: "/builds/4/timeline", reply: _ => StubReply.Code(status: 500));
        using var client = server.Client();
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, onChange: _ => { });
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: "web-ci", actual: Classify(snapshot: engine.CurrentSnapshot(), now: now).GetValueOrDefault(key: 1)?.Detail);

        server.On(path: "/builds/4/timeline", json: BuildFixture.Timeline(records: [BuildFixture.Record(id: "t", type: "Task", name: "Compile", result: "failed")]));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: "web-ci · Compile failed", actual: Classify(snapshot: engine.CurrentSnapshot(), now: now).GetValueOrDefault(key: 1)?.Detail);
    }

    [Fact]
    public async Task PoliciesYouCantReadAreUnknownNotNone()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1, reviewers: [Fixture.Reviewer(person: People.Sam, vote: 10)], created: now.AddSeconds(seconds: -Make.Day))]);
        server.On(path: "/_apis/policy/evaluations", reply: _ => StubReply.Code(status: 403));
        using var client = server.Client();
        var snapshot = await PulseEngine.LoadOnceAsync(
            client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, cancellationToken: TestContext.Current.CancellationToken);
        var details = First(snapshot: snapshot)?.Details;
        Assert.NotNull(@object: details);
        Assert.False(condition: details.ChecksKnown);
        Assert.Equal(expected: PRGroup.Waiting, actual: Classify(snapshot: snapshot, now: now).GetValueOrDefault(key: 1)?.Group);
    }

    [Fact]
    public async Task WhatThePoliciesSayCountsEvenWhenTheThreadsCantBeRead()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1, reviewers: [Fixture.Reviewer(person: People.Sam, vote: 10)], created: now.AddSeconds(seconds: -5 * Make.Day))]);
        static JsonObject Approvals() => Fixture.Evaluation(type: "Minimum number of reviewers", status: "approved", settings: new JsonObject { ["minimumApproverCount"] = 1 });
        server.On(path: "/_apis/policy/evaluations", json: Fixture.List(items: [Approvals()]));
        // A comment from before the first run's lookback: not news.
        server.On(path: "/threads", json: Fixture.List(items:
        [
            Fixture.Thread(
                id: 7,
                comments: [Fixture.Comment(id: 1, author: People.Sam, content: "Looks good", at: now.AddSeconds(seconds: -4 * Make.Day))],
                published: now.AddSeconds(seconds: -4 * Make.Day)),
        ]));
        // Details are due on every refresh, though the pull request doesn't change.
        using var client = server.Client();
        using var engine = new PulseEngine(
            client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org], Planner = detailsEveryRefresh }, onChange: _ => { });
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: PRGroup.Ready, actual: Classify(snapshot: engine.CurrentSnapshot(), now: now).GetValueOrDefault(key: 1)?.Group);

        // The project stops letting you read its policies, and reading the threads fails this time.
        server.On(path: "/_apis/policy/evaluations", reply: _ => StubReply.Code(status: 403));
        server.On(path: "/threads", reply: _ => StubReply.Code(status: 500));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var denied = engine.CurrentSnapshot();
        var details = First(snapshot: denied)?.Details;
        Assert.NotNull(@object: details);
        Assert.False(condition: details.ChecksKnown);
        // The threads read before are kept.
        Assert.Equal(expected: [7], actual: details.Threads.Select(selector: thread => thread.Id));
        Assert.Equal(expected: PRGroup.Waiting, actual: Classify(snapshot: denied, now: now).GetValueOrDefault(key: 1)?.Group);
        Assert.Equal(expected: "Can't read its policies", actual: Classify(snapshot: denied, now: now).GetValueOrDefault(key: 1)?.Headline);

        // Then its build fails, and the threads still can't be read.
        server.On(path: "/_apis/policy/evaluations", json: Fixture.List(items:
        [
            Approvals(),
            Fixture.Evaluation(type: "Build", status: "rejected", settings: new JsonObject { ["displayName"] = "web-ci" }, context: new JsonObject { ["buildId"] = 4, ["isExpired"] = false }),
        ]));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: PRReason.BuildFailed, actual: Classify(snapshot: engine.CurrentSnapshot(), now: now).GetValueOrDefault(key: 1)?.Reason);
    }

    [Fact]
    public async Task ReportsSigningInProblems()
    {
        var server = new StubServer();
        server.ServeOrganization();
        using var signedOutClient = server.Client(tokens: new FakeTokens(value: "made-up-token", error: AuthError.SignedOut(message: "Run az login")));
        var signedOut = await PulseEngine.LoadOnceAsync(
            client: signedOutClient, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: new PulseProblem(Kind: PulseProblemKind.SignedOut, Detail: "Run az login"), actual: signedOut.Problem);
        Assert.True(condition: signedOut.Problem?.NeedsSignIn);
        Assert.Empty(collection: server.Requests);

        using var missingClient = server.Client(tokens: new FakeTokens(value: "made-up-token", error: AuthError.CliNotFound));
        var missing = await PulseEngine.LoadOnceAsync(
            client: missingClient, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: PulseProblem.CliNotFound, actual: missing.Problem);

        using var client = server.Client();
        var none = await PulseEngine.LoadOnceAsync(client: client, configuration: new PulseEngineConfiguration { Organizations = [] }, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: PulseProblem.NoOrganizations, actual: none.Problem);
    }

    [Fact]
    public async Task KeepsTheLastListWhenAzureDevOpsCannotBeReached()
    {
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)]);
        using var client = server.Client();
        using var engine = Engine(client: client);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Single(collection: engine.CurrentSnapshot().Records);

        server.On(path: "/_apis/git/pullrequests", reply: _ => StubReply.Offline());
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var offline = engine.CurrentSnapshot();
        Assert.Equal(expected: PulseProblem.Offline, actual: offline.Problem);
        Assert.Single(collection: offline.Records);
    }

    [Fact]
    public async Task ReportsAnOrganizationThatCannotBeRead()
    {
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)]);
        server.On(path: "/locked/_apis/connectionData", reply: _ => StubReply.Code(status: 403));
        using var client = server.Client();
        var snapshot = await PulseEngine.LoadOnceAsync(
            client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org, "locked"] }, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Single(collection: snapshot.Records);
        Assert.Equal(
            expected: new PulseProblem(Kind: PulseProblemKind.SomeOrganizations, Detail: "Couldn't read locked (No access to this organization.)."),
            actual: snapshot.Problem);
    }

    [Fact]
    public async Task AnOrganizationRemovedDuringARefreshStaysRemoved()
    {
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)]);
        server.ServeOrganization(organization: "slow", mine: [Fixture.PullRequest(id: 2)]);
        // The slow organization's lists come only once it's no longer watched, rather than after a wait the refresh may
        // outlast on a busy machine.
        var listing = new TaskCompletionSource(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
        using var removed = new ManualResetEventSlim(initialState: false);
        server.On(path: "/slow/_apis/git/pullrequests", reply: _ =>
        {
            listing.TrySetResult();
            // As the Mac's test does, it answers after a while all the same.
            removed.Wait(timeout: TimeSpan.FromSeconds(value: 30));
            return StubReply.Json(body: Fixture.List(items: [Fixture.PullRequest(id: 2)]));
        });
        using var client = server.Client();
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org, "slow"] }, onChange: _ => { });
        var refresh = Task.Run(function: () => engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken), cancellationToken: TestContext.Current.CancellationToken);
        await listing.Task.WaitAsync(timeout: TimeSpan.FromSeconds(value: 30), cancellationToken: TestContext.Current.CancellationToken);
        engine.SetConfiguration(newConfiguration: new PulseEngineConfiguration { Organizations = [Fixture.Org] });
        removed.Set();
        await refresh;
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 1)], actual: snapshot.Records.Select(selector: record => record.Id));
        Assert.Equal(expected: [Fixture.Org], actual: snapshot.FirstLoaded.Keys);
    }

    /// Spelled another way, as when finding your organizations again spells one as Azure DevOps does, an organization is the
    /// same one: what was read there stays listed, even while it can't be read.
    [Fact]
    public async Task AnOrganizationSpelledAnotherWayKeepsItsPullRequests()
    {
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)]);
        server.ServeOrganization(organization: "fabrikam");
        using var client = server.Client();
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org, "fabrikam"] }, onChange: _ => { });
        var cancellationToken = TestContext.Current.CancellationToken;
        await engine.RefreshNowAsync(cancellationToken: cancellationToken);
        Assert.Equal(expected: [1], actual: engine.CurrentSnapshot().Records.Select(selector: record => record.Id.Number));

        server.On(path: "/Contoso/_apis", reply: _ => StubReply.Code(status: 500));
        engine.SetConfiguration(newConfiguration: new PulseEngineConfiguration { Organizations = ["Contoso", "fabrikam"] });
        Assert.Equal(expected: [1], actual: engine.CurrentSnapshot().Records.Select(selector: record => record.Id.Number));
        await engine.RefreshNowAsync(cancellationToken: cancellationToken);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: Fixture.Org, actual: Assert.Single(collection: snapshot.Records).Id.Organization);
        Assert.Equal(expected: 1, actual: snapshot.Records[0].Id.Number);
        Assert.Equal(expected: PulseProblemKind.SomeOrganizations, actual: snapshot.Problem?.Kind);
    }

    /// Spelled another way while its lists load, an organization keeps what they had.
    [Fact]
    public async Task AnOrganizationSpelledAnotherWayDuringARefreshKeepsItsPullRequests()
    {
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)]);
        using var client = server.Client();
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, onChange: _ => { });
        var respelled = 0;
        server.On(
            path: "/" + Fixture.Org + "/_apis/git/pullrequests",
            reply: _ =>
            {
                if (Interlocked.Exchange(location1: ref respelled, value: 1) == 0)
                {
                    engine.SetConfiguration(newConfiguration: new PulseEngineConfiguration { Organizations = ["Contoso"] });
                }
                return StubReply.Json(body: Fixture.List(items: [Fixture.PullRequest(id: 1)]));
            },
            query: new Dictionary<string, string> { ["searchCriteria.creatorId"] = Fixture.Me, ["searchCriteria.status"] = "active" });
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 1, actual: respelled);
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 1)], actual: engine.CurrentSnapshot().Records.Select(selector: record => record.Id));
    }

    /// Spelled another way, an organization was first read when it was first read under its old spelling, and nothing's
    /// kept under that spelling, however a pull request read before spells it.
    [Fact]
    public async Task AnOrganizationSpelledAnotherWayWasFirstReadWhenItWasFirstRead()
    {
        var clock = new TestClock(start: TestTimes.T(seconds: 0));
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)], completed: [Fixture.PullRequest(id: 3, status: "completed", closed: TestTimes.T(seconds: -10 * Make.Minute))]);
        // Its completed pull request from before is past the ones the list gives.
        server.ServeOrganization(organization: "Contoso", mine: [Fixture.PullRequest(id: 1)]);
        using var client = server.Client(time: clock);
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, onChange: _ => { }, time: clock);
        var cancellationToken = TestContext.Current.CancellationToken;
        await engine.RefreshNowAsync(cancellationToken: cancellationToken);
        Assert.Equal(expected: new KeyValuePair<string, DateTimeOffset>(key: Fixture.Org, value: TestTimes.T(seconds: 0)), actual: Assert.Single(collection: engine.CurrentSnapshot().FirstLoaded));

        clock.Set(time: TestTimes.T(seconds: Make.Minute));
        engine.SetConfiguration(newConfiguration: new PulseEngineConfiguration { Organizations = ["Contoso"] });
        await engine.RefreshNowAsync(cancellationToken: cancellationToken);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: new KeyValuePair<string, DateTimeOffset>(key: "Contoso", value: TestTimes.T(seconds: 0)), actual: Assert.Single(collection: snapshot.FirstLoaded));
        Assert.Equal(expected: ["Contoso/1", "contoso/3"], actual: snapshot.Records.Select(selector: record => record.Id.ToString()).Order(comparer: StringComparer.Ordinal));
        Assert.Equal(expected: TestTimes.T(seconds: 0), actual: snapshot.FirstRead(organization: Fixture.Org));
        Assert.Null(@object: snapshot.FirstRead(organization: "fabrikam"));
    }

    [Fact]
    public async Task FetchesDetailsOnABudgetAfterTheFirstLoad()
    {
        var server = new StubServer();
        server.ServeOrganization(mine: Enumerable.Range(start: 1, count: 5).Select(selector: number => Fixture.PullRequest(id: number)));
        using var client = server.Client();
        using var engine = Engine(client: client, budget: 2);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        int DetailRequests() => server.Requests.Count(predicate: request => request.Path.EndsWith(value: "/threads", comparisonType: StringComparison.Ordinal));
        Assert.Equal(expected: 5, actual: DetailRequests());

        // Nothing changed and nothing's due: only the lists.
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 5, actual: DetailRequests());

        // Two pushes: at most two details per refresh.
        server.On(
            path: "/_apis/git/pullrequests",
            json: Fixture.List(items: Enumerable.Range(start: 1, count: 5).Select(selector: number => Fixture.PullRequest(id: number, sourceCommit: number <= 3 ? "pushed" : "abc"))),
            query: yourActiveList);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 7, actual: DetailRequests());
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 8, actual: DetailRequests());
    }

    /// A comment changes nothing in the lists, so a pull request's threads are read again on a schedule: an active one's
    /// every 3 minutes, a draft's every quarter of an hour. A new comment shows within that.
    [Fact]
    public async Task ReadsThreadsAgainOnAScheduleThoughTheListsDontChange()
    {
        var clock = new TestClock(start: TestTimes.T(seconds: 0));
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1), Fixture.PullRequest(id: 2, draft: true)]);
        using var client = server.Client();
        using var engine = new PulseEngine(
            client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, onChange: _ => { }, time: clock);
        int ThreadReads(int number) =>
            server.Requests.Count(predicate: request => request.Path.EndsWith(value: "/pullRequests/" + Fixture.Text(number: number) + "/threads", comparisonType: StringComparison.Ordinal));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: (1, 1), actual: (ThreadReads(number: 1), ThreadReads(number: 2)));

        clock.Set(time: TestTimes.T(seconds: 2 * Make.Minute));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: (1, 1), actual: (ThreadReads(number: 1), ThreadReads(number: 2)));

        // Sam comments on the first: its next read, past 3 minutes, has it.
        server.On(
            path: "/pullRequests/1/threads",
            json: Fixture.List(items: [Fixture.Thread(id: 7, comments: [Fixture.Comment(id: 1, author: People.Sam, content: "Looks off by one", at: TestTimes.T(seconds: 150))], published: TestTimes.T(seconds: 150))]));
        clock.Set(time: TestTimes.T(seconds: (3 * Make.Minute) + 1));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: (2, 1), actual: (ThreadReads(number: 1), ThreadReads(number: 2)));
        var details = engine.CurrentSnapshot().Records.Single(predicate: record => record.Id.Number == 1).Details;
        Assert.Equal(expected: 7, actual: Assert.Single(collection: details!.Threads).Id);

        clock.Set(time: TestTimes.T(seconds: (15 * Make.Minute) + 1));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 1, actual: ThreadReads(number: 2) - 1);
    }

    [Fact]
    public async Task FindsOutWhatHappenedToAPullRequestThatLeftTheList()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1), Fixture.PullRequest(id: 2)]);
        using var client = server.Client();
        using var engine = Engine(client: client);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);

        server.On(path: "/_apis/git/pullrequests", json: Fixture.List(items: [Fixture.PullRequest(id: 2)]), query: yourActiveList);
        server.On(path: "/_apis/git/pullrequests/1", json: Fixture.PullRequest(id: 1, status: "abandoned", closed: now.AddSeconds(seconds: -Make.Minute)));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [PullRequestStatus.Abandoned, PullRequestStatus.Active], actual: snapshot.Records.Select(selector: record => record.PullRequest.Status));
        Assert.Equal(expected: PRReason.Abandoned, actual: Classify(snapshot: snapshot, now: now).GetValueOrDefault(key: 1)?.Reason);
    }

    /// One of yours that left the list of an organization spelled another way since, as when finding your organizations
    /// again spells it as Azure DevOps does, is looked up as any other is: it's the same organization.
    [Fact]
    public async Task FindsOutWhatHappenedToAPullRequestThatLeftAnOrganizationSpelledAnotherWay()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1), Fixture.PullRequest(id: 2)]);
        using var client = server.Client();
        using var engine = Engine(client: client);
        var cancellationToken = TestContext.Current.CancellationToken;
        await engine.RefreshNowAsync(cancellationToken: cancellationToken);

        server.ServeOrganization(organization: "Contoso", mine: [Fixture.PullRequest(id: 2)]);
        server.On(path: "/" + Fixture.Org + "/_apis/git/pullrequests/1", json: Fixture.PullRequest(id: 1, status: "abandoned", closed: now.AddSeconds(seconds: -Make.Minute)));
        engine.SetConfiguration(newConfiguration: new PulseEngineConfiguration { Organizations = ["Contoso"] });
        await engine.RefreshNowAsync(cancellationToken: cancellationToken);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [PullRequestStatus.Abandoned, PullRequestStatus.Active], actual: snapshot.Records.Select(selector: record => record.PullRequest.Status));
        Assert.Equal(expected: PRReason.Abandoned, actual: Classify(snapshot: snapshot, now: now).GetValueOrDefault(key: 1)?.Reason);
    }

    [Fact]
    public async Task SigningInAsSomeoneElseStartsOver()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token");
        tokens.SignIn(signedIn: "tenant/robin");
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)]);
        using var client = server.Client(tokens: tokens);
        using var engine = Engine(client: client);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: [1], actual: engine.CurrentSnapshot().Records.Select(selector: record => record.Id.Number));

        // Sam signs in to the Azure CLI: Azure DevOps knows them by another identity, with other pull requests.
        var sam = People.Sam.Id;
        server.ServeOrganization(me: sam, mine: [Fixture.PullRequest(id: 2, author: People.Sam)]);
        tokens.SignIn(signedIn: "tenant/sam");
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [2], actual: snapshot.Records.Select(selector: record => record.Id.Number));
        Assert.All(collection: snapshot.Records, action: record => Assert.Equal(expected: sam, actual: record.Me));
    }

    [Fact]
    public async Task WhatOneAccountHasSeenDoesntHideWhatsNewForAnother()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token");
        tokens.SignIn(signedIn: "tenant/robin");
        // Robin's pull request, which Sam reviews, and Robin's comment for Sam an hour ago.
        JsonObject Robins() => Fixture.PullRequest(id: 1, reviewers: [Fixture.Reviewer(person: People.Sam)], created: now.AddSeconds(seconds: -Make.Day));
        server.ServeOrganization(mine: [Robins()]);
        server.On(path: "/threads", json: Fixture.List(items:
        [
            Fixture.Thread(
                id: 7,
                comments: [Fixture.Comment(id: 1, author: People.Me, content: "Over to you @<" + People.Sam.Id + ">", at: now.AddSeconds(seconds: -Make.Hour))],
                published: now.AddSeconds(seconds: -Make.Hour)),
        ]));
        using var client = server.Client(tokens: tokens);
        using var engine = Engine(client: client);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: "tenant/robin", actual: engine.CurrentSnapshot().Account);

        // Robin opens it from BriefBar, and takes it off Needs you.
        var book = new SeenBook(Current: SeenState.FirstRun(now: now), Others: new Dictionary<string, SeenState>());
        book = book.SigningIn(account: "tenant/robin", now: now).Book;
        book = book with { Current = book.Current.Dismissing(keys: [new PRKey(Organization: Fixture.Org, Number: 1)], date: now) };

        // Then Sam signs in to the Azure CLI on the same PC, and sees the same pull request.
        server.ServeOrganization(me: People.Sam.Id, reviewing: [Robins()]);
        tokens.SignIn(signedIn: "tenant/sam");
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: "tenant/sam", actual: snapshot.Account);
        var record = First(snapshot: snapshot);
        Assert.NotNull(@object: record);
        Assert.Equal(expected: new PRKey(Organization: Fixture.Org, Number: 1), actual: record.Id);
        Assert.Equal(expected: PRRole.Reviewer, actual: record.Role);
        Assert.Equal(expected: People.Sam.Id, actual: record.Me);

        // What Robin took off Needs you would hide the comment for Sam.
        PRGroup? Group(SeenState seen) =>
            PRClassifier.Snapshot(record: record, seenCutoff: seen.Cutoff(key: record.Id), dismissedCutoff: seen.DismissedCutoff(key: record.Id), now: now)?.Group;
        Assert.NotEqual(expected: PRGroup.NeedsYou, actual: Group(seen: book.Current));
        var (signedIn, switched) = book.SigningIn(account: "tenant/sam", now: now);
        Assert.True(condition: switched);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: Group(seen: signedIn.Current));
    }

    [Fact]
    public async Task KeepsLookingUpPullRequestsThatLeftTheList()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        var numbers = Enumerable.Range(start: 1, count: 7).ToList();
        server.ServeOrganization(mine: numbers.Select(selector: number => Fixture.PullRequest(id: number)));
        using var client = server.Client();
        using var engine = Engine(client: client);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);

        // All seven were abandoned at once, more than a refresh looks up, and reading one fails the first time.
        server.On(path: "/_apis/git/pullrequests", json: Fixture.List(items: []), query: yourActiveList);
        var attempts = 0;
        foreach (var number in numbers)
        {
            server.On(path: "/_apis/git/pullrequests/" + Fixture.Text(number: number), reply: _ =>
            {
                if (number == 1 && Interlocked.Increment(location: ref attempts) == 1)
                {
                    return StubReply.Code(status: 500);
                }
                return StubReply.Json(body: Fixture.PullRequest(id: number, status: "abandoned", closed: now.AddSeconds(seconds: -Make.Minute)));
            });
        }
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: numbers, actual: snapshot.Records.Select(selector: record => record.Id.Number));
        Assert.All(collection: snapshot.Records, action: record => Assert.Equal(expected: PullRequestStatus.Abandoned, actual: record.PullRequest.Status));
        Assert.Equal(expected: 2, actual: Volatile.Read(location: ref attempts));
    }

    [Fact]
    public async Task LookupsThatKeepFailingDontHoldUpTheRest()
    {
        var now = DateTimeOffset.UtcNow;
        var server = new StubServer();
        server.ServeOrganization(mine: Enumerable.Range(start: 1, count: 7).Select(selector: number => Fixture.PullRequest(id: number)));
        using var client = server.Client();
        using var engine = Engine(client: client);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);

        // All seven left the list at once. Looking up the first five keeps failing, and you may not read the sixth.
        server.On(path: "/_apis/git/pullrequests", json: Fixture.List(items: []), query: yourActiveList);
        for (var number = 1; number <= 5; number++)
        {
            server.On(path: "/_apis/git/pullrequests/" + Fixture.Text(number: number), reply: _ => StubReply.Code(status: 500));
        }
        server.On(path: "/_apis/git/pullrequests/6", reply: _ => StubReply.Code(status: 403));
        server.On(path: "/_apis/git/pullrequests/7", json: Fixture.PullRequest(id: 7, status: "abandoned", closed: now.AddSeconds(seconds: -Make.Minute)));
        int Lookups(int number) =>
            server.Requests.Count(predicate: request => request.Path.EndsWith(value: "/pullrequests/" + Fixture.Text(number: number), comparisonType: StringComparison.Ordinal));

        // The first five, then the two not looked up yet before them again.
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [7], actual: snapshot.Records.Select(selector: record => record.Id.Number));
        Assert.Equal(expected: PullRequestStatus.Abandoned, actual: First(snapshot: snapshot)?.PullRequest.Status);

        // Each that failed twice waits before it's looked up again, and the one you may not read isn't.
        for (var refresh = 0; refresh < 3; refresh++)
        {
            await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        }
        Assert.Equal(expected: [2, 2, 2, 2, 2], actual: Enumerable.Range(start: 1, count: 5).Select(selector: number => Lookups(number: number)));
        Assert.Equal(expected: 1, actual: Lookups(number: 6));
    }

    [Fact(Timeout = 60_000)]
    public async Task BacksOffWhenThrottled()
    {
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)]);
        server.On(path: "/threads", reply: _ => StubReply.Code(status: 429, headers: new Dictionary<string, string> { ["Retry-After"] = "120" }));
        using var client = server.Client();
        var snapshot = await PulseEngine.LoadOnceAsync(
            client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: PulseProblemKind.Throttled, actual: snapshot.Problem?.Kind);
        var until = Assert.NotNull(value: snapshot.Problem?.Until);
        Assert.True(condition: until - DateTimeOffset.UtcNow > TimeSpan.FromSeconds(value: 100));
    }

    [Fact(Timeout = 60_000)]
    public async Task RefreshesOnATimerAndWhenAsked()
    {
        var server = new StubServer();
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)]);
        var collector = new PulseCollector();
        using var client = server.Client();
        using var engine = new PulseEngine(
            client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org], Interval = TimeSpan.FromHours(value: 1) }, onChange: collector.Add);
        _ = engine.Start();
        try
        {
            await collector.WaitAsync(what: "the first load", predicate: snapshot => snapshot.HasLoaded && !snapshot.IsRefreshing && snapshot.Records.Count == 1);

            server.On(path: "/_apis/git/pullrequests", json: Fixture.List(items: [Fixture.PullRequest(id: 1), Fixture.PullRequest(id: 2)]), query: yourActiveList);
            engine.Refresh();
            await collector.WaitAsync(what: "the refresh it asked for", predicate: snapshot => snapshot.Records.Count == 2 && !snapshot.IsRefreshing);
        }
        finally
        {
            await engine.StopAsync().WaitAsync(cancellationToken: TestContext.Current.CancellationToken);
        }
    }

    [Fact(Timeout = 60_000)]
    public async Task AWakeBeforeTheWaitStillWakesIt()
    {
        var waker = new Waker();
        waker.Wake();
        var start = Stopwatch.StartNew();
        await waker.WaitAsync(delay: TimeSpan.FromSeconds(value: 30), time: TimeProvider.System, cancellationToken: TestContext.Current.CancellationToken);
        Assert.True(condition: start.Elapsed < TimeSpan.FromSeconds(value: 5));
        var timed = Stopwatch.StartNew();
        await waker.WaitAsync(delay: TimeSpan.FromSeconds(value: 0.2), time: TimeProvider.System, cancellationToken: TestContext.Current.CancellationToken);
        Assert.True(condition: timed.Elapsed >= TimeSpan.FromSeconds(value: 0.15));
    }

    /// An engine reading the organization through `client`, refreshing the details of `budget` known pull requests at
    /// most a refresh.
    static PulseEngine Engine(ADOClient client, int budget = 8) =>
        new(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org], Planner = new RefreshPlannerOptions { Budget = budget } }, onChange: _ => { });

    /// What the panel says of each pull request, by number, on a first run at `now`.
    static Dictionary<int, PRSnapshot> Classify(PulseSnapshot snapshot, DateTimeOffset now)
    {
        var seen = SeenState.FirstRun(now: now);
        var result = new Dictionary<int, PRSnapshot>();
        foreach (var record in snapshot.Records)
        {
            if (PRClassifier.Snapshot(record: record, seenCutoff: seen.Cutoff(key: record.Id), dismissedCutoff: seen.DismissedCutoff(key: record.Id), now: now) is { } item)
            {
                result[record.Id.Number] = item;
            }
        }
        return result;
    }

    /// The query of pull request `number`'s policy evaluations.
    static Dictionary<string, string> PoliciesOf(int number) => new() { ["artifactId"] = "vstfs:///CodeReview/CodeReviewId/p1/" + Fixture.Text(number: number) };

    static PRRecord? First(PulseSnapshot snapshot) => snapshot.Records.Count > 0 ? snapshot.Records[0] : null;

    static void AssertOnlyGets(StubServer server) => Assert.All(collection: server.Requests, action: request =>
    {
        Assert.Equal(expected: HttpMethod.Get, actual: request.Method);
        Assert.False(condition: request.HasBody);
    });
}
