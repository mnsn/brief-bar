using System.Globalization;

namespace BriefBar.Core.Tests;

/// `Retry-After`, as a number of seconds or an HTTP date, in each of the forms RFC 9110 has recipients accept, from the
/// client's own clock, at most an hour.
public sealed class RetryAfterTests
{
    static readonly DateTimeOffset now = TestTimes.Reference;

    [Theory]
    [InlineData("120", 120)]
    [InlineData(" 30 ", 30)]
    [InlineData("1.5", 1.5)]
    [InlineData("99999", 3_600)]
    [InlineData("1e300", 3_600)]
    public void ReadsSeconds(string value, double seconds) =>
        Assert.Equal(expected: TimeSpan.FromSeconds(value: seconds), actual: RetryAfter.Wait(value: value, now: now));

    /// IMF-fixdate, RFC 850's and asctime's forms, from `now`, to the second.
    [Theory]
    [InlineData("Sun, 18 Oct 2026 10:15:00 GMT")]
    [InlineData("Sunday, 18-Oct-26 10:15:00 GMT")]
    [InlineData("Sun Oct 18 10:15:00 2026")]
    [InlineData("  Sun, 18 Oct 2026 10:15:00 GMT  ")]
    public void ReadsAnHTTPDateInEachOfItsForms(string value) =>
        Assert.Equal(expected: TimeSpan.FromMinutes(value: 15), actual: RetryAfter.Wait(value: value, now: now));

    /// asctime pads a day of one digit with a space.
    [Fact]
    public void ReadsAsctimesPaddedDay() =>
        Assert.Equal(expected: TimeSpan.FromMinutes(value: 15), actual: RetryAfter.Wait(value: "Tue Nov  3 10:15:00 2026", now: DateTimeOffset.Parse(input: "2026-11-03T10:00:00Z", formatProvider: CultureInfo.InvariantCulture)));

    /// From the clock it's given, not the PC's: a date read later asks for less.
    [Fact]
    public void ADateIsFromTheClockItsGiven() =>
        Assert.Equal(expected: TimeSpan.FromMinutes(value: 5), actual: RetryAfter.Wait(value: "Sun, 18 Oct 2026 10:15:00 GMT", now: now.AddMinutes(minutes: 10)));

    [Fact]
    public void WaitsAnHourAtMost() =>
        Assert.Equal(expected: TimeSpan.FromHours(value: 1), actual: RetryAfter.Wait(value: "Sun, 18 Oct 2026 15:00:00 GMT", now: now));

    /// Nothing to wait for: none at all, none asked for, a date that has passed, or words.
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("0")]
    [InlineData("-30")]
    [InlineData("NaN")]
    [InlineData("Infinity")]
    [InlineData("soon")]
    [InlineData("Sat, 17 Oct 2026 10:00:00 GMT")]
    [InlineData("Sun, 18 Oct 2026 10:00:00 GMT")]
    public void NothingToWaitFor(string? value) => Assert.Null(@object: RetryAfter.Wait(value: value, now: now));

    /// Seconds as the Mac reads them, as `x-ratelimit-reset` gives them too.
    [Fact]
    public void ReadsSecondsAsTheMacDoes()
    {
        Assert.Equal(expected: 1_792_317_600, actual: RetryAfter.Seconds(text: "1792317600"));
        Assert.Equal(expected: 2.5, actual: RetryAfter.Seconds(text: "2.5"));
        Assert.Null(@object: RetryAfter.Seconds(text: "later"));
        Assert.Null(@object: RetryAfter.Seconds(text: "Infinity"));
        Assert.Null(@object: RetryAfter.Seconds(text: null));
    }
}
