namespace BriefBar.Core.Tests;

/// Ported from Tests/BriefBarCoreTests/ElapsedTests.swift.
public sealed class ElapsedTests
{
    [Theory]
    [InlineData(0.0, "now")]
    [InlineData(59.0, "now")]
    [InlineData(60.0, "1m")]
    [InlineData(3_599.0, "59m")]
    [InlineData(3_600.0, "1h")]
    [InlineData(3_660.0, "1h 1m")]
    [InlineData(86_399.0, "23h 59m")]
    [InlineData(86_400.0, "1d")]
    [InlineData(200_000.0, "2d")]
    [InlineData(-5.0, "now")]
    public void FormatsElapsedTime(double seconds, string expected)
    {
        Assert.Equal(expected: expected, actual: Elapsed.Compact(since: Times.At(seconds: 0), now: Times.At(seconds: seconds)));
    }

    [Fact]
    public void ElapsedTimeOfNothingIsEmpty()
    {
        Assert.Equal(expected: string.Empty, actual: Elapsed.Compact(since: null, now: Times.At(seconds: 0)));
    }

    [Theory]
    [InlineData(0.0, "just now")]
    [InlineData(59.0, "just now")]
    [InlineData(60.0, "1 minute ago")]
    [InlineData(180.0, "3 minutes ago")]
    [InlineData(3_600.0, "1 hour ago")]
    [InlineData(3_660.0, "1 hour 1 minute ago")]
    [InlineData(7_500.0, "2 hours 5 minutes ago")]
    [InlineData(86_400.0, "1 day ago")]
    [InlineData(200_000.0, "2 days ago")]
    [InlineData(-5.0, "just now")]
    public void SaysElapsedTimeInWords(double seconds, string expected)
    {
        Assert.Equal(expected: expected, actual: Elapsed.Spoken(since: Times.At(seconds: 0), now: Times.At(seconds: seconds)));
    }

    [Fact]
    public void SaysNothingForNoDate()
    {
        Assert.Equal(expected: string.Empty, actual: Elapsed.Spoken(since: null, now: Times.At(seconds: 0)));
    }
}
