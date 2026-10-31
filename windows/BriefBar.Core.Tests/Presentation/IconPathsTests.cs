using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class IconPathsTests
{
    [Fact]
    public void EveryIconHasADrawingThatXamlCanRead()
    {
        foreach (var icon in Enum.GetValues<IconKey>())
        {
            var drawing = IconPaths.Of(icon: icon);
            Assert.True(condition: drawing.Size is 12 or 16 or 20, userMessage: $"{icon} is {drawing.Size} units square.");
            var xaml = SvgPathData.ToXaml(svg: drawing.Svg, rule: drawing.Rule);
            Assert.Matches(expectedRegexPattern: @"^F[01] [MmLlHhVvCcSsQqTtAaZz0-9.\- ]+$", actualString: xaml);
        }
    }

    [Theory]
    [InlineData("M1.5.5L2,3Z", IconFillRule.Nonzero, "F1 M 1.5 0.5 L 2 3 Z")]
    [InlineData("M-1-2h3", IconFillRule.EvenOdd, "F0 M -1 -2 h 3")]
    [InlineData("M0 0a1 1 0 01 2 3", IconFillRule.Nonzero, "F1 M 0 0 a 1 1 0 0 1 2 3")]
    [InlineData("M1e-1 2E2", IconFillRule.Nonzero, "F1 M 0.1 200")]
    public void SpellsOutWhatSvgRunsTogether(string svg, IconFillRule rule, string expected)
    {
        Assert.Equal(expected: expected, actual: SvgPathData.ToXaml(svg: svg, rule: rule));
    }

    [Fact]
    public void RefusesSomethingThatIsntAPath()
    {
        Assert.Throws<FormatException>(testCode: () => SvgPathData.ToXaml(svg: "M 1 # 2", rule: IconFillRule.Nonzero));
    }
}
