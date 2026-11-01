using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class BarMetricsTests
{
    [Theory]
    [InlineData(1.0, 32.0)]
    [InlineData(1.1, 35.2)]
    [InlineData(1.25, 40.0)]
    [InlineData(2.25, 40.0)]
    [InlineData(0.5, 32.0)]
    [InlineData(0.0, 32.0)]
    [InlineData(double.NaN, 32.0)]
    public void GrowsWithWindowsTextSizeUpToATaskbarsWorth(double textScale, double expected)
    {
        Assert.Equal(expected: expected, actual: BarMetrics.HeightDip(textScale: textScale), precision: 6);
    }

    [Theory]
    [InlineData(1.0, 1.0, 32)]
    [InlineData(1.0, 1.5, 48)]
    [InlineData(1.0, 1.25, 40)]
    [InlineData(1.25, 1.5, 60)]
    [InlineData(1.0, 1.75, 56)]
    public void IsWholePixelsOnEachDisplay(double textScale, double displayScale, int expected)
    {
        Assert.Equal(expected: expected, actual: BarMetrics.HeightPixels(textScale: textScale, displayScale: displayScale));
    }
}
