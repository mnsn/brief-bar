namespace BriefBar.Core.AzureDevOps;

/// How long to wait before trying again something that failed `failures` times in a row: a refresh `interval` after the
/// second failure, twice that after the third, and so on, at most half an hour. The Mac's
/// `min(interval * pow(2, failures - 2), 1_800)`.
internal static class Backoff
{
    static readonly TimeSpan longest = TimeSpan.FromMinutes(value: 30);

    public static TimeSpan Delay(TimeSpan interval, int failures)
    {
        var seconds = interval.TotalSeconds * Math.Pow(x: 2, y: failures - 2);
        return seconds >= longest.TotalSeconds ? longest : TimeSpan.FromSeconds(value: seconds);
    }
}
