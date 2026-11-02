using System.Globalization;

namespace BriefBar.Core.Tests;

/// The Swift tests' fixed times: `T(seconds)` after 2026-10-18T10:00:00Z, and the format the Copilot CLI and Azure DevOps
/// write times in.
internal static class TestTimes
{
    public static DateTimeOffset Reference { get; } = DateTimeOffset.FromUnixTimeSeconds(seconds: 1_792_317_600);

    public static DateTimeOffset T(double seconds) => Reference.AddTicks(ticks: (long)Math.Round(a: seconds * TimeSpan.TicksPerSecond));

    /// As the CLI writes it: `2026-10-18T10:00:01.000Z`.
    public static string Iso(DateTimeOffset date) =>
        date.UtcDateTime.ToString(format: "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", provider: CultureInfo.InvariantCulture);
}
