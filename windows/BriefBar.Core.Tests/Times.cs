namespace BriefBar.Core.Tests;

/// Made-up times for tests, as the Swift tests' `t(_:)`: seconds after a fixed moment.
internal static class Times
{
    public static DateTimeOffset Origin { get; } =
        new(year: 2026, month: 10, day: 19, hour: 9, minute: 41, second: 0, offset: TimeSpan.Zero);

    public static DateTimeOffset At(double seconds) => Origin.AddSeconds(seconds: seconds);
}
