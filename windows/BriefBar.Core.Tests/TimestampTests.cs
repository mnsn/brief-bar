namespace BriefBar.Core.Tests;

public sealed class TimestampTests
{
    /// 2026-10-18T17:00:07Z.
    static readonly DateTimeOffset expected = DateTimeOffset.FromUnixTimeSeconds(seconds: 1_792_342_807);

    public static TheoryData<string, double> Supported { get; } = new()
    {
        { "2026-10-18T17:00:07Z", 0.0 },
        { "2026-10-18T17:00:07", 0 },
        { "2026-10-18 17:00:07", 0 },
        { "2026-10-18t17:00:07z", 0 },
        { "2026-10-18T17:00:07.304Z", 0.304 },
        { "2026-10-18T17:00:07,5Z", 0.5 },
        { "2026-10-18T17:00:07.123456Z", 0.123456 },
        { "2026-10-18T17:00:07.1234567Z", 0.1234567 },
        { "2026-10-18T19:00:07+02:00", 0 },
        { "2026-10-18T19:30:07+0230", 0 },
        { "2026-10-18T19:00:07+02", 0 },
        { "2026-10-18T12:30:07.250-04:30", 0.25 },
    };

    public static TheoryData<string> Malformed { get; } = new()
    {
        "", "2026-10-18", "2026-10-18T17:00", "20261018T170007Z", "2026/10/18T17:00:07Z", "2026-10-18X17:00:07Z",
        "2026-13-01T00:00:00Z", "2026-10-32T00:00:00Z", "2026-10-18T24:00:00Z", "2026-10-18T17:60:00Z",
        "2026-10-18T17:00:07.Z", "2026-10-18T17:00:07Zjunk", "2026-10-18T17:00:07+5", "2026-10-18T17:00:07 UTC",
    };

    [Theory]
    [MemberData(memberName: nameof(Supported))]
    public void ParsesSupportedForms(string input, double fraction)
    {
        var parsed = Timestamp.Parse(text: input);
        Assert.NotNull(@object: parsed);
        Assert.Equal(expected: fraction, actual: (parsed.Value - expected).TotalSeconds, precision: 6);
    }

    [Theory]
    [MemberData(memberName: nameof(Malformed))]
    public void RejectsMalformedInput(string input) => Assert.Null(@object: Timestamp.Parse(text: input));

    [Fact]
    public void HandlesCalendarEdges()
    {
        Assert.Equal(expected: 0, actual: Timestamp.DaysFromCivil(year: 1970, month: 1, day: 1));
        Assert.Equal(expected: 11_017, actual: Timestamp.DaysFromCivil(year: 2000, month: 3, day: 1));
        Assert.Equal(expected: -1, actual: Timestamp.DaysFromCivil(year: 1969, month: 12, day: 31));
        Assert.Equal(expected: DateTimeOffset.FromUnixTimeSeconds(seconds: 1_709_164_800), actual: Timestamp.Parse(text: "2024-02-29T00:00:00Z"));
        Assert.Equal(expected: DateTimeOffset.FromUnixTimeSeconds(seconds: -1), actual: Timestamp.Parse(text: "1969-12-31T23:59:59Z"));
        // Beyond what a DateTimeOffset holds.
        Assert.Null(@object: Timestamp.Parse(text: "0000-01-01T00:00:00Z"));
    }

    [Fact]
    public void RoundTripsTheCLIsFormat()
    {
        var date = DateTimeOffset.FromUnixTimeMilliseconds(milliseconds: 1_792_342_807_250);
        Assert.Equal(expected: date, actual: Timestamp.Parse(text: Copilot.TestTimes.Iso(date: date)));
    }
}
