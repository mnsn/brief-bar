using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// The pipelines after a merge: which runs belong to it, how they add up, what the merged pull request then says, and the
/// engine's requests.
public sealed class MergeTests
{
    static readonly PipelineStage waitingStage = new(Id: "s3", Name: "Production", State: PipelineStageState.Waiting);
    static readonly PipelineFailure unitTests = new(Stage: "Test", Step: "Run unit tests", Message: "2 tests failed.");

    // Which runs

    [Fact]
    public void FindsTheRunsOnTheMergeAndTheOnesTheyStarted()
    {
        var onBranch = Decode(builds:
        [
            Build(id: 1, definition: 10, commit: "ABC", queued: T(seconds: 0)),
            // A scheduled run only happened to pick the commit up.
            Build(id: 2, definition: 11, commit: "abc", queued: T(seconds: 0), reason: "schedule"),
            Build(id: 3, definition: 12, commit: "other", queued: T(seconds: 0)),
        ]);
        var triggered = Decode(builds:
        [
            Build(id: 5, definition: 21, commit: "x", queued: T(seconds: Make.Minute), reason: "resourceTrigger", triggeredBy: 4),
            Build(id: 4, definition: 20, commit: "abc", queued: T(seconds: Make.Minute), reason: "buildCompletion", triggeredBy: 1),
            Build(id: 6, definition: 22, queued: T(seconds: Make.Minute), reason: "buildCompletion", triggeredBy: 3),
        ]);
        Assert.Equal(expected: [1, 4, 5], actual: MergeChain.Runs(onBranch: onBranch, triggered: triggered, mergeCommit: "abc").Select(selector: build => build.Id));
        Assert.Empty(collection: MergeChain.Runs(onBranch: onBranch, triggered: triggered, mergeCommit: "none"));
    }

    [Fact]
    public void FollowsAMergeWhileRunsMayStillStart()
    {
        static PipelineRun Run(PipelineRunStatus status, DateTimeOffset? finished = null) => new()
        {
            Id = 1,
            Organization = Fixture.Org,
            ProjectName = "Shop",
            Number = "1",
            Status = status,
            Trigger = PipelineTrigger.Push,
            Branch = "main",
            FinishedAt = finished,
        };
        var merged = T(seconds: 0);
        Assert.True(condition: MergeChain.IsFollowing(mergedAt: merged, runs: [], date: T(seconds: 10 * Make.Minute)));
        Assert.False(condition: MergeChain.IsFollowing(mergedAt: merged, runs: [], date: T(seconds: 31 * Make.Minute)));
        Assert.True(condition: MergeChain.IsFollowing(mergedAt: merged, runs: [Run(status: PipelineRunStatus.Queued)], date: T(seconds: 5 * Make.Hour)));
        Assert.True(condition: MergeChain.IsFollowing(
            mergedAt: merged, runs: [Run(status: PipelineRunStatus.Succeeded, finished: T(seconds: 50 * Make.Minute))], date: T(seconds: 60 * Make.Minute)));
        Assert.False(condition: MergeChain.IsFollowing(
            mergedAt: merged, runs: [Run(status: PipelineRunStatus.Succeeded, finished: T(seconds: 50 * Make.Minute))], date: T(seconds: 66 * Make.Minute)));
    }

    // How they add up

    [Fact]
    public void WhatFailedComesFirstThenWhatWaitsThenWhatRuns()
    {
        Assert.Null(@object: MergeSummary.Of(pipelines: []));

        var passed = MergeSummary.Of(pipelines:
        [
            Status(id: 1, run: PipelineRunStatus.Succeeded), Status(id: 2, run: PipelineRunStatus.PartiallySucceeded), Status(id: 3, run: PipelineRunStatus.Canceled),
        ]);
        Assert.NotNull(@object: passed);
        Assert.Equal(expected: MergeOutcome.Passed, actual: passed.Outcome);
        Assert.Equal(expected: 3, actual: passed.Total);

        var running = MergeSummary.Of(pipelines: [Status(id: 1, run: PipelineRunStatus.Succeeded), Status(id: 2, run: PipelineRunStatus.Running)]);
        Assert.NotNull(@object: running);
        Assert.Equal(expected: MergeOutcome.Running, actual: running.Outcome);
        Assert.Equal(expected: 1, actual: running.Running);

        var waiting = MergeSummary.Of(pipelines: [Status(id: 1, run: PipelineRunStatus.Running), Status(id: 2, run: PipelineRunStatus.Running, stages: [waitingStage])]);
        Assert.NotNull(@object: waiting);
        Assert.Equal(expected: MergeOutcome.Waiting, actual: waiting.Outcome);
        Assert.Equal(expected: "pipeline 2", actual: waiting.Pipeline);
        Assert.Equal(expected: "Production", actual: waiting.Stage);
        Assert.Equal(expected: 2, actual: waiting.RunId);

        var failed = MergeSummary.Of(pipelines:
        [
            Status(id: 1, run: PipelineRunStatus.Running, stages: [waitingStage]), Status(id: 2, run: PipelineRunStatus.Failed, failure: unitTests),
        ]);
        Assert.NotNull(@object: failed);
        Assert.Equal(expected: MergeOutcome.Failed, actual: failed.Outcome);
        Assert.Equal(expected: "pipeline 2", actual: failed.Pipeline);
        Assert.Equal(expected: unitTests, actual: failed.Failure);
        Assert.Contains(expectedSubstring: "buildId=2", actualString: failed.RunUrl?.AbsoluteUri, comparisonType: StringComparison.Ordinal);
    }

    // The merged pull request

    [Fact]
    public void AMergedPullRequestSaysWhatItsPipelinesDo()
    {
        var pr = Make.PR(status: PullRequestStatus.Completed, closed: T(seconds: -Make.Hour)) with { MergeCommit = "m1" };
        PRSnapshot? Classify(IReadOnlyList<PipelineStatus> statuses, DateTimeOffset seen)
        {
            var merge = new MergePipelines(
                PullRequest: pr.Key, Title: pr.Title, TargetBranch: pr.TargetBranch, MergedAt: T(seconds: -Make.Hour), Url: pr.WebUrl, Pipelines: [.. statuses], IsFollowing: true);
            return PRClassifier.Snapshot(
                record: new PRRecord(pullRequest: pr, role: PRRole.Author, me: People.Me.Id, merge: merge), seenCutoff: seen, dismissedCutoff: seen, now: T(seconds: 0));
        }

        // While they run, it stays in Done, even once you've seen it.
        var running = Classify(statuses: [Status(id: 1, run: PipelineRunStatus.Succeeded), Status(id: 2, run: PipelineRunStatus.Running)], seen: T(seconds: -Make.Minute));
        Assert.NotNull(@object: running);
        Assert.Equal(expected: PRGroup.Done, actual: running.Group);
        Assert.Equal(expected: PRReason.Completed, actual: running.Reason);
        Assert.Equal(expected: "Merged into main · 1 pipeline running", actual: running.Detail);
        Assert.Equal(expected: pr.WebUrl, actual: running.Url);

        // A failed one is wrong, and opens the run.
        var failed = Classify(statuses: [Status(id: 1, run: PipelineRunStatus.Succeeded), Status(id: 2, run: PipelineRunStatus.Failed, failure: unitTests)], seen: T(seconds: -Make.Minute));
        Assert.NotNull(@object: failed);
        Assert.Equal(expected: PRGroup.Failing, actual: failed.Group);
        Assert.Equal(expected: PRReason.FailedAfterMerge, actual: failed.Reason);
        Assert.Equal(expected: "Failed after merge", actual: failed.Headline);
        Assert.Equal(expected: "pipeline 2 · Run unit tests: 2 tests failed.", actual: failed.Detail);
        Assert.Equal(expected: unitTests, actual: failed.Failure);
        Assert.Contains(expectedSubstring: "buildId=2", actualString: failed.Url.AbsoluteUri, comparisonType: StringComparison.Ordinal);
        Assert.Equal(expected: MergeOutcome.Failed, actual: failed.Merge?.Outcome);
        Assert.Equal(expected: "“pipeline 2” failed after “Fix the checkout total” merged.", actual: Brief.Item(snapshot: failed).Sentence);

        var waiting = Classify(statuses: [Status(id: 1, run: PipelineRunStatus.Running, stages: [waitingStage])], seen: T(seconds: -Make.Minute));
        Assert.NotNull(@object: waiting);
        Assert.Equal(expected: PRGroup.Done, actual: waiting.Group);
        Assert.Equal(expected: PRReason.WaitingForApproval, actual: waiting.Reason);
        Assert.Equal(expected: "Waiting for approval", actual: waiting.Headline);
        Assert.Equal(expected: "pipeline 1 · Production", actual: waiting.Detail);

        // Once they all passed, it's Done as before: until you've seen it.
        var passed = Classify(statuses: [Status(id: 1, run: PipelineRunStatus.Succeeded), Status(id: 2, run: PipelineRunStatus.Succeeded)], seen: T(seconds: -2 * Make.Hour));
        Assert.NotNull(@object: passed);
        Assert.Equal(expected: PRGroup.Done, actual: passed.Group);
        Assert.Equal(expected: "Merged into main · 2 pipelines passed", actual: passed.Detail);
        Assert.Equal(expected: "Merged into main · its pipeline passed", actual: Classify(statuses: [Status(id: 1, run: PipelineRunStatus.Succeeded)], seen: T(seconds: -2 * Make.Hour))?.Detail);
        Assert.Null(@object: Classify(statuses: [Status(id: 1, run: PipelineRunStatus.Succeeded)], seen: T(seconds: -Make.Minute)));

        // Someone else's merge, or one abandoned, says nothing about pipelines.
        var abandoned = pr with { Status = PullRequestStatus.Abandoned };
        var merge = new MergePipelines(
            PullRequest: pr.Key, Title: pr.Title, TargetBranch: "main", MergedAt: T(seconds: -Make.Hour), Url: pr.WebUrl, Pipelines: [Status(id: 1, run: PipelineRunStatus.Failed)], IsFollowing: false);
        var gone = PRClassifier.Snapshot(
            record: new PRRecord(pullRequest: abandoned, role: PRRole.Author, me: People.Me.Id, merge: merge),
            seenCutoff: T(seconds: -2 * Make.Hour),
            dismissedCutoff: T(seconds: -2 * Make.Hour),
            now: T(seconds: 0));
        Assert.Equal(expected: PRGroup.Done, actual: gone?.Group);
        Assert.Equal(expected: PRReason.Abandoned, actual: gone?.Reason);
        Assert.Null(@object: gone?.Merge);
    }

    // The engine

    [Fact]
    public async Task FollowsThePipelinesAfterYourMergeWithGETRequests()
    {
        var start = DateTimeOffset.UtcNow;
        var clock = new TestClock(start: start);
        var server = new StubServer();
        var merged = Fixture.PullRequest(id: 3, title: "Merged", created: start.AddSeconds(seconds: -Make.Day), status: "completed", closed: start.AddSeconds(seconds: -10 * Make.Minute));
        merged["lastMergeCommit"] = new JsonObject { ["commitId"] = "m1" };
        server.ServeOrganization(completed: [merged]);
        void Serve(bool finished)
        {
            var status = finished ? "completed" : "inProgress";
            var result = finished ? "succeeded" : null;
            server.On(
                path: "/_apis/build/builds",
                json: Fixture.List(items:
                [
                    Build(id: 1, definition: 10, queued: start.AddSeconds(seconds: -9 * Make.Minute)),
                    Build(id: 2, definition: 11, status: status, result: result, queued: start.AddSeconds(seconds: -8 * Make.Minute)),
                    Build(id: 4, definition: 12, commit: "before", queued: start.AddSeconds(seconds: -9 * Make.Minute)),
                ]),
                query: new Dictionary<string, string> { ["repositoryId"] = "r1" });
            server.On(
                path: "/_apis/build/builds",
                json: Fixture.List(items:
                [
                    Build(id: 5, definition: 20, status: status, result: result, queued: start.AddSeconds(seconds: -2 * Make.Minute), reason: "buildCompletion", triggeredBy: 1),
                ]),
                query: new Dictionary<string, string> { ["reasonFilter"] = "buildCompletion,resourceTrigger" });
        }
        Serve(finished: false);
        server.On(path: "/builds/2/timeline", json: BuildFixture.Timeline(records:
        [
            BuildFixture.Record(id: "s1", type: "Stage", name: "Staging", order: 1),
            BuildFixture.Record(id: "s2", type: "Stage", name: "Production", order: 2, state: "pending", result: null),
            BuildFixture.Record(id: "c2", type: "Checkpoint", name: "Checkpoint", parent: "s2", state: "inProgress", result: null),
        ]));
        using var client = server.Client();
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, onChange: _ => { }, time: clock);
        int Lookups() => server.Requests.Count(predicate: request => request.Query.GetValueOrDefault(key: "repositoryId") == "r1");

        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        var first = MergeOf(snapshot: engine.CurrentSnapshot());
        Assert.NotNull(@object: first);
        Assert.Equal(expected: [10, 11, 20], actual: first.Pipelines.Select(selector: status => status.Pipeline.DefinitionId));
        Assert.Equal(expected: ["pipeline 10", "pipeline 11", "pipeline 20"], actual: first.Pipelines.Select(selector: status => status.Pipeline.Name));
        Assert.True(condition: first.IsFollowing);
        Assert.Equal(expected: MergeOutcome.Waiting, actual: first.Summary?.Outcome);
        Assert.Equal(expected: "Production", actual: first.Summary?.Stage);
        var item = Classify(snapshot: engine.CurrentSnapshot(), now: start);
        Assert.NotNull(@object: item);
        Assert.Equal(expected: PRReason.WaitingForApproval, actual: item.Reason);

        // They finish; a refresh later, BriefBar reads that, and then stops looking a while after the last one finished.
        Serve(finished: true);
        clock.Set(time: start.AddSeconds(seconds: 5 * Make.Minute));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: MergeOutcome.Passed, actual: MergeOf(snapshot: engine.CurrentSnapshot())?.Summary?.Outcome);
        Assert.Equal(expected: 2, actual: Lookups());
        clock.Set(time: start.AddSeconds(seconds: 2 * Make.Hour));
        await engine.RefreshNowAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 2, actual: Lookups());
        Assert.False(condition: MergeOf(snapshot: engine.CurrentSnapshot())?.IsFollowing);
        Assert.All(collection: server.Requests, action: request =>
        {
            Assert.Equal(expected: HttpMethod.Get, actual: request.Method);
            Assert.False(condition: request.HasBody);
        });
    }

    [Fact]
    public async Task TurnedOffItReadsNoRuns()
    {
        var server = new StubServer();
        var merged = Fixture.PullRequest(id: 3, status: "completed", closed: DateTimeOffset.UtcNow.AddSeconds(seconds: -Make.Minute));
        merged["lastMergeCommit"] = new JsonObject { ["commitId"] = "m1" };
        server.ServeOrganization(completed: [merged]);
        using var client = server.Client();
        var snapshot = await PulseEngine.LoadOnceAsync(
            client: client,
            configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org], FollowMerges = false },
            cancellationToken: TestContext.Current.CancellationToken);
        Assert.Null(@object: MergeOf(snapshot: snapshot));
        Assert.DoesNotContain(collection: server.Requests, filter: request => request.Path.Contains(value: "/_apis/build/", comparisonType: StringComparison.Ordinal));
    }

    /// A run of a pipeline, on a commit, started by a push or by another run.
    static JsonObject Build(
        int id, int definition, DateTimeOffset queued, string commit = "m1", string status = "completed", string? result = "succeeded", string reason = "individualCI", int? triggeredBy = null)
    {
        var json = BuildFixture.Build(id: id, definition: definition, queued: queued, status: status, result: result, reason: reason);
        json["sourceVersion"] = commit;
        if (triggeredBy is { } parent)
        {
            json["triggeredByBuild"] = new JsonObject { ["id"] = parent };
        }
        return json;
    }

    /// `builds`, as BriefBar reads them.
    static List<ADOBuild> Decode(IEnumerable<JsonObject> builds) =>
        [.. builds.Select(selector: json => Fixture.Read(json: json, read: ADOBuild.Read) ?? throw new InvalidOperationException(message: "Not a build."))];

    /// Pipeline `id`, whose latest run stands as `run` says: queued 50 minutes ago and, once it's finished, finished a
    /// minute ago unless `finished` says when; with that run's stages, and where it failed.
    static PipelineStatus Status(int id, PipelineRunStatus run, IEnumerable<PipelineStage>? stages = null, PipelineFailure? failure = null, DateTimeOffset? finished = null)
    {
        var pipeline = new PipelineRef(Organization: Fixture.Org, ProjectId: "p1", ProjectName: "Shop", DefinitionId: id, Name: "pipeline " + Fixture.Text(number: id));
        var latest = new PipelineRun
        {
            Id = id,
            Organization = Fixture.Org,
            ProjectName = "Shop",
            Number = "20261018." + Fixture.Text(number: id),
            Status = run,
            Trigger = PipelineTrigger.Push,
            Branch = "main",
            QueuedAt = T(seconds: -50 * Make.Minute),
            StartedAt = T(seconds: -49 * Make.Minute),
        };
        return new PipelineStatus(
            Pipeline: pipeline, Runs: [latest with { FinishedAt = latest.IsFinished ? finished ?? T(seconds: -Make.Minute) : null }], Stages: [.. stages ?? []], Failure: failure);
    }

    /// The pipelines after pull request 3's merge, as `snapshot` has them.
    static MergePipelines? MergeOf(PulseSnapshot snapshot) => snapshot.Records.FirstOrDefault(predicate: record => record.Id.Number == 3)?.Merge;

    /// What the panel says of pull request 3, on a first run at `now`.
    static PRSnapshot? Classify(PulseSnapshot snapshot, DateTimeOffset now)
    {
        var seen = SeenState.FirstRun(now: now);
        return snapshot.Records.FirstOrDefault(predicate: record => record.Id.Number == 3) is { } record
            ? PRClassifier.Snapshot(record: record, seenCutoff: seen.Cutoff(key: record.Id), dismissedCutoff: seen.DismissedCutoff(key: record.Id), now: now)
            : null;
    }
}
