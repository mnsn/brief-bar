namespace BriefBar.Core.AzureDevOps;

/// One of your pull requests that left the active list without showing up as completed: since when, when it was last
/// looked up, and how many lookups in a row failed.
internal sealed record PulseVanished(PullRequest PullRequest, DateTimeOffset Since, DateTimeOffset? LastLookup = null, int Failures = 0)
{
    /// Whether to look it up on a refresh at `date`: at once, again on the next refresh if that fails, then less and less
    /// often, so that the ones that keep failing don't cost requests every refresh.
    public bool IsDue(DateTimeOffset date, TimeSpan interval) =>
        LastLookup is not { } last || Failures <= 1 || date - last >= Backoff.Delay(interval: interval, failures: Failures);
}
