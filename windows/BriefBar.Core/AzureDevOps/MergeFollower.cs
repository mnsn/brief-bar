using System.Globalization;
using BriefBar.Core.Logging;

namespace BriefBar.Core.AzureDevOps;

/// Follows the pipelines that run after you merge a pull request, while Done keeps it: its target branch's runs on its
/// merge commit, and the runs those start; each merge for half an hour after it merged, while a run hasn't finished, and
/// a little while after the last one did; the newest merges first, `MergesPerRefresh` a refresh. A run's timeline is read
/// every refresh while it runs, and once more when it finishes, `TimelinesPerRefresh` a refresh. A lookup that fails is
/// tried again on the next refresh, then less and less often. Part of the Mac's `PulseEngine`. Safe to use from any
/// thread.
internal sealed class MergeFollower
{
    /// The most merges whose runs are looked for in one refresh, the newest first.
    public const int MergesPerRefresh = 5;

    /// The most timelines of runs after merges read in one refresh.
    public const int TimelinesPerRefresh = 4;

    readonly Lock gate = new();
    readonly Dictionary<PRKey, MergeFollow> merges = [];

    /// Looks for the runs after `done`'s merges, and reads their timelines. Returns the error when Azure DevOps asked
    /// BriefBar to slow down.
    public async Task<ADOError?> FollowAsync(
        IReadOnlyList<PullRequest> done, PulseEngineConfiguration configuration, ADOClient client, DateTimeOffset date, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(argument: done);
        ArgumentNullException.ThrowIfNull(argument: configuration);
        if (!configuration.FollowMerges)
        {
            Forget();
            return null;
        }
        var merged = done.Where(predicate: pr => pr.Status == PullRequestStatus.Completed && pr.MergeCommit is not null && pr.ClosedAt is not null).ToList();
        List<PullRequest> due;
        lock (gate)
        {
            var keys = merged.Select(selector: pr => pr.Key).ToHashSet();
            foreach (var key in merges.Keys.Where(predicate: key => !keys.Contains(item: key)).ToList())
            {
                merges.Remove(key: key);
            }
            due = merged
                .Where(predicate: pr =>
                {
                    var follow = merges.GetValueOrDefault(key: pr.Key) ?? new MergeFollow();
                    if (!MergeChain.IsFollowing(mergedAt: pr.ClosedAt!.Value, runs: follow.LatestRuns, date: date))
                    {
                        return false;
                    }
                    return follow.LastLookup is not { } last || follow.Failures <= 1 || date - last >= Backoff.Delay(interval: configuration.Interval, failures: follow.Failures);
                })
                .OrderByDescending(keySelector: pr => pr.ClosedAt)
                .ThenByDescending(keySelector: pr => pr.Key)
                .Take(count: MergesPerRefresh)
                .ToList();
        }
        foreach (var pr in due)
        {
            if (await LookAsync(pr: pr, client: client, date: date, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false) is { } throttled)
            {
                return throttled;
            }
        }
        return await ReadTimelinesAsync(client: client, date: date, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
    }

    /// The pipelines after `pr`'s merge, as known at `now`; null before any run was found.
    public MergePipelines? Pipelines(PullRequest pr, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: pr);
        MergeFollow? follow;
        lock (gate)
        {
            follow = merges.GetValueOrDefault(key: pr.Key);
        }
        if (follow is null || follow.Runs.IsEmpty || pr.ClosedAt is not { } mergedAt)
        {
            return null;
        }
        var statuses = follow.ByPipeline.Select(selector: pair =>
        {
            var latest = pair.Runs[0];
            var timeline = follow.Timelines.GetValueOrDefault(key: latest.Id);
            return new PipelineStatus(
                Pipeline: pair.Pipeline,
                Runs: new ValueList<PipelineRun>(items: pair.Runs),
                Stages: timeline?.Stages ?? [],
                Failure: latest.Status == PipelineRunStatus.Failed ? timeline?.Failure : null);
        });
        return new MergePipelines(
            PullRequest: pr.Key,
            Title: pr.Title.Length == 0 ? "Pull request " + pr.Key.Number.ToString(provider: CultureInfo.InvariantCulture) : pr.Title,
            TargetBranch: pr.TargetBranch,
            MergedAt: mergedAt,
            Url: pr.WebUrl,
            Pipelines: new ValueList<PipelineStatus>(items: statuses),
            IsFollowing: MergeChain.IsFollowing(mergedAt: mergedAt, runs: follow.LatestRuns, date: now));
    }

    /// Forgets the runs found so far, as when you turn following off, or someone else signs in.
    public void Forget()
    {
        lock (gate)
        {
            merges.Clear();
        }
    }

    /// Looks for `pr`'s runs: the target branch's on its merge commit, then, once there's one, the runs that runs started.
    async Task<ADOError?> LookAsync(PullRequest pr, ADOClient client, DateTimeOffset date, CancellationToken cancellationToken)
    {
        var commit = pr.MergeCommit!;
        var since = pr.ClosedAt!.Value - MergeChain.ClockSlack;
        var organization = pr.Key.Organization;
        MergeFollow follow;
        lock (gate)
        {
            follow = merges.GetValueOrDefault(key: pr.Key) ?? new MergeFollow();
        }
        try
        {
            var onBranch = (await client.ListAsync(
                url: ADOEndpoint.BranchBuilds(
                    organization: organization, projectId: pr.ProjectId, repositoryId: pr.RepositoryId, branch: pr.TargetBranch, queuedSince: since),
                read: ADOBuild.Read,
                cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false)).Value;
            var chain = MergeChain.Runs(onBranch: onBranch, triggered: [], mergeCommit: commit);
            // The runs they started are looked for only once there's a run to start them.
            if (chain.Count > 0)
            {
                var triggered = (await client.ListAsync(
                    url: ADOEndpoint.TriggeredBuilds(organization: organization, projectId: pr.ProjectId, queuedSince: since),
                    read: ADOBuild.Read,
                    cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false)).Value;
                chain = MergeChain.Runs(onBranch: onBranch, triggered: triggered, mergeCommit: commit);
            }
            var runs = follow.Runs;
            foreach (var build in chain)
            {
                var projectId = build.Project?.Id ?? pr.ProjectId;
                var projectName = build.Project?.Name ?? pr.ProjectName;
                var pipeline = new PipelineRef(
                    Organization: organization,
                    ProjectId: projectId,
                    ProjectName: projectName,
                    DefinitionId: build.Definition.Id,
                    Name: PlainText.SingleLine(text: build.Definition.Name ?? "Pipeline " + build.Definition.Id.ToString(provider: CultureInfo.InvariantCulture)),
                    Folder: PipelineRef.FolderOf(path: build.Definition.Path));
                runs = runs.SetItem(key: build.Id, value: new MergeFollowRun(Pipeline: pipeline, Run: PipelineRun.From(organization: organization, projectName: projectName, dto: build)));
            }
            follow = follow with { Runs = runs, LastLookup = date, Failures = 0 };
        }
        catch (ADOException error) when (error.Error.Kind == ADOErrorKind.Throttled)
        {
            return error.Error;
        }
        catch (ADOException error)
        {
            Log.Write(line: $"azureDevOps: a merge's runs couldn't be read, {error.Error.Kind}; trying again later");
            follow = follow with { LastLookup = date, Failures = follow.Failures + 1 };
        }
        lock (gate)
        {
            merges[pr.Key] = follow;
        }
        return null;
    }

    /// Reads the timelines of the latest runs after your merges: a run's every refresh while it runs, for its stages and
    /// whether one waits for an approval, and once more when it finishes, for where it failed. The ones never read first,
    /// then the ones read longest ago.
    async Task<ADOError?> ReadTimelinesAsync(ADOClient client, DateTimeOffset date, CancellationToken cancellationToken)
    {
        List<(PRKey Key, MergeFollowRun Found, DateTimeOffset? LastRead)> picked;
        lock (gate)
        {
            var due = new List<(PRKey Key, MergeFollowRun Found, DateTimeOffset? LastRead)>();
            foreach (var (key, follow) in merges)
            {
                foreach (var (pipeline, runs) in follow.ByPipeline)
                {
                    var run = runs[0];
                    if (run.Status == PipelineRunStatus.Queued)
                    {
                        continue;
                    }
                    var read = follow.Timelines.GetValueOrDefault(key: run.Id);
                    // Read once for how it finished; a retried run, running again under the same ID, is read again.
                    if (read is not null && run.IsFinished && read.ReadFor == run.Status)
                    {
                        continue;
                    }
                    due.Add(item: (key, new MergeFollowRun(Pipeline: pipeline, Run: run), read?.ReadAt));
                }
            }
            picked = due.OrderBy(keySelector: item => item.LastRead ?? DateTimeOffset.MinValue).ThenBy(keySelector: item => item.Found.Run.Id).Take(count: TimelinesPerRefresh).ToList();
        }
        foreach (var (key, found, _) in picked)
        {
            var run = found.Run;
            MergeFollowTimeline? timeline;
            try
            {
                var read = await client.GetAsync(
                    url: ADOEndpoint.Timeline(organization: found.Pipeline.Organization, projectId: found.Pipeline.ProjectId, buildId: run.Id),
                    read: ADOTimeline.Read,
                    cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                timeline = new MergeFollowTimeline(
                    Stages: new ValueList<PipelineStage>(items: PipelineStage.Stages(timeline: read, runFinished: run.IsFinished)),
                    Failure: run.Status == PipelineRunStatus.Failed ? PipelineFailure.First(timeline: read) : null,
                    ReadFor: run.Status,
                    ReadAt: date);
            }
            catch (ADOException error) when (error.Error.Kind is ADOErrorKind.NotFound or ADOErrorKind.Forbidden)
            {
                // No timeline yet, or one you may not read: a finished run's isn't asked for again.
                timeline = run.IsFinished ? new MergeFollowTimeline(Stages: [], Failure: null, ReadFor: run.Status, ReadAt: date) : null;
            }
            catch (ADOException error) when (error.Error.Kind == ADOErrorKind.Throttled)
            {
                return error.Error;
            }
            catch (ADOException error)
            {
                Log.Write(line: $"azureDevOps: a run's timeline after a merge couldn't be read, {error.Error.Kind}; trying again on the next refresh");
                timeline = null;
            }
            if (timeline is not null)
            {
                lock (gate)
                {
                    if (merges.TryGetValue(key: key, value: out var follow))
                    {
                        merges[key] = follow with { Timelines = follow.Timelines.SetItem(key: run.Id, value: timeline) };
                    }
                }
            }
        }
        return null;
    }
}
