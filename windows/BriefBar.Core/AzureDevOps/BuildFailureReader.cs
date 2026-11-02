using BriefBar.Core.Logging;

namespace BriefBar.Core.AzureDevOps;

/// Where your pull requests' failed builds failed, from their timelines: each read once, the ones never tried first, at
/// most `PerRefresh` a refresh. A timeline that can't be read is tried again later, less and less often; one that isn't
/// there, or that you may not read, never. Part of the Mac's `PulseEngine`. Safe to use from any thread.
internal sealed class BuildFailureReader
{
    /// The most failed builds whose timelines are read in one refresh.
    public const int PerRefresh = 4;

    readonly Lock gate = new();
    readonly Dictionary<FailedBuild, PipelineFailure> failures = [];
    /// The builds whose timelines were read, including those that had nothing to say or can't be read for good.
    readonly HashSet<FailedBuild> read = [];
    /// The builds whose timelines couldn't be read: when last tried, and how many tries in a row failed.
    readonly Dictionary<FailedBuild, (DateTimeOffset Last, int Failures)> attempts = [];

    /// Reads the timelines due of `wanted`, the failed builds as their policies report them now, and forgets the others.
    /// Returns the error when Azure DevOps asked BriefBar to slow down.
    public async Task<ADOError?> ReadAsync(IReadOnlySet<FailedBuild> wanted, ADOClient client, DateTimeOffset date, TimeSpan interval, CancellationToken cancellationToken)
    {
        List<FailedBuild> due;
        lock (gate)
        {
            foreach (var build in failures.Keys.Where(predicate: build => !wanted.Contains(item: build)).ToList())
            {
                failures.Remove(key: build);
            }
            read.IntersectWith(other: wanted);
            foreach (var build in attempts.Keys.Where(predicate: build => !wanted.Contains(item: build)).ToList())
            {
                attempts.Remove(key: build);
            }
            due = wanted
                .Where(predicate: build => !read.Contains(item: build)
                    && (!attempts.TryGetValue(key: build, value: out var tried) || tried.Failures <= 1 || date - tried.Last >= Backoff.Delay(interval: interval, failures: tried.Failures)))
                .OrderBy(keySelector: build => attempts.TryGetValue(key: build, value: out var tried) ? tried.Last : DateTimeOffset.MinValue)
                .ThenBy(keySelector: build => build.Organization, comparer: StringComparer.Ordinal)
                .ThenBy(keySelector: build => build.BuildId)
                .Take(count: PerRefresh)
                .ToList();
        }
        foreach (var build in due)
        {
            try
            {
                var timeline = await client.GetAsync(
                    url: ADOEndpoint.Timeline(organization: build.Organization, projectId: build.ProjectId, buildId: build.BuildId),
                    read: ADOTimeline.Read,
                    cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                lock (gate)
                {
                    if (PipelineFailure.First(timeline: timeline) is { } failure)
                    {
                        failures[build] = failure;
                    }
                    read.Add(item: build);
                    attempts.Remove(key: build);
                }
            }
            catch (ADOException error) when (error.Error.Kind is ADOErrorKind.NotFound or ADOErrorKind.Forbidden)
            {
                // No timeline, or one you may not read: the list names the build that failed, as before.
                lock (gate)
                {
                    read.Add(item: build);
                    attempts.Remove(key: build);
                }
            }
            catch (ADOException error) when (error.Error.Kind == ADOErrorKind.Throttled)
            {
                return error.Error;
            }
            catch (ADOException error)
            {
                Log.Write(line: $"azureDevOps: a failed build's timeline couldn't be read, {error.Error.Kind}; trying again later");
                lock (gate)
                {
                    attempts[build] = (date, (attempts.TryGetValue(key: build, value: out var tried) ? tried.Failures : 0) + 1);
                }
            }
        }
        return null;
    }

    /// `details`, with where each failed build failed, once that's been read.
    public PRDetails? WithFailures(PRDetails? details, PullRequest pr)
    {
        lock (gate)
        {
            if (details is null || failures.Count == 0)
            {
                return details;
            }
            return details with
            {
                Checks = new ValueList<Check>(items: details.Checks.Select(selector: check => check.FailedBuildId is { } buildId
                    ? check with
                    {
                        Failure = failures.GetValueOrDefault(
                            key: new FailedBuild(Organization: pr.Key.Organization, ProjectId: pr.ProjectId, BuildId: buildId, CompletedAt: check.CompletedAt)),
                    }
                    : check)),
            };
        }
    }

    /// Forgets every failed build read so far, as when someone else signs in.
    public void Forget()
    {
        lock (gate)
        {
            failures.Clear();
            read.Clear();
            attempts.Clear();
        }
    }
}
