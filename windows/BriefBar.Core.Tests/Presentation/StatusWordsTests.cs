using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class StatusWordsTests
{
    [Theory]
    [InlineData(0, "Updated just now")]
    [InlineData(9, "Updated just now")]
    [InlineData(10, "Updated 10 s ago")]
    [InlineData(59, "Updated 59 s ago")]
    [InlineData(60, "Updated 1 min ago")]
    [InlineData(3_599, "Updated 59 min ago")]
    [InlineData(3_600, "Updated 1 h ago")]
    [InlineData(86_400, "Updated 1 d ago")]
    [InlineData(-30, "Updated just now")]
    public void SaysWhenItLastRead(int secondsAgo, string expected)
    {
        Assert.Equal(
            expected: expected,
            actual: StatusWords.Updated(updatedAt: Times.At(seconds: -secondsAgo), now: Times.At(seconds: 0)));
    }

    [Fact]
    public void SaysEachCondition()
    {
        var now = Times.At(seconds: 0);
        Assert.Equal(expected: "Starting…", actual: StatusWords.Of(status: SectionStatus.Starting, now: now));
        Assert.Equal(expected: "Live", actual: StatusWords.Of(status: SectionStatus.Live, now: now));
        Assert.Equal(
            expected: string.Empty,
            actual: StatusWords.Of(status: new SectionStatus(Condition: SectionCondition.Ready), now: now));
        Assert.Equal(
            expected: "Couldn't refresh.",
            actual: StatusWords.Of(status: new SectionStatus(Condition: SectionCondition.Stale), now: now));
        Assert.Equal(
            expected: "Can't read.",
            actual: StatusWords.Of(status: new SectionStatus(Condition: SectionCondition.Problem), now: now));
        Assert.StartsWith(
            expectedStartString: "Paused",
            actualString: StatusWords.Of(status: new SectionStatus(Condition: SectionCondition.Paused), now: now),
            comparisonType: StringComparison.Ordinal);
    }
}
