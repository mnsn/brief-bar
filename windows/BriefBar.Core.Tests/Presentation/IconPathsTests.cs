using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class IconPathsTests
{
    /// The sizes a source's glyph shows at: in the bar, on its tile, and on its page in Settings.
    static readonly int[] glyphSizes = [16, 20, 24];

    [Fact]
    public void EveryDrawingIsOneXamlCanRead()
    {
        foreach (var icon in Enum.GetValues<IconKey>())
        {
            foreach (var drawing in IconPaths.Drawings(icon: icon))
            {
                Assert.True(condition: drawing.Size is 12 or 16 or 20 or 24, userMessage: $"{icon} is {drawing.Size} units square.");
                var xaml = SvgPathData.ToXaml(svg: drawing.Svg, rule: drawing.Rule);
                Assert.Matches(expectedRegexPattern: @"^F[01] [MmLlHhVvCcSsQqTtAaZz0-9.\- ]+$", actualString: xaml);
            }
        }
    }

    [Fact]
    public void HasEachIconOnceAtEachSize()
    {
        foreach (var icon in Enum.GetValues<IconKey>())
        {
            var sizes = IconPaths.Drawings(icon: icon).Select(selector: drawing => drawing.Size).ToList();
            Assert.Equal(expected: sizes.Distinct().Count(), actual: sizes.Count);
        }
    }

    /// A source's glyph shows at 16 in the bar, in rows and in Settings' list, at 20 on its tile and at 24 on its page
    /// in Settings, and the Overview's on its tile. Fluent doesn't draw every icon at every size: Pulse starts at 20, and
    /// Branch Request stops at 20.
    [Fact]
    public void HasEverySourcesGlyphAtTheSizesItShows()
    {
        var missing = Sections.InBarOrder
            .Select(selector: section => section.Glyph)
            .SelectMany(selector: glyph => glyphSizes.Select(selector: size => (Glyph: glyph, Size: size)))
            .Append(element: (Glyph: IconKey.Stack, Size: 20))
            .Where(predicate: shown => !(shown is (IconKey.Pulse, 16) or (IconKey.BranchRequest, 24)))
            .Where(predicate: shown => IconPaths.Of(icon: shown.Glyph, size: shown.Size).Size != shown.Size)
            .Select(selector: shown => shown.Glyph + " at " + shown.Size)
            .ToList();
        Assert.Empty(collection: missing);
    }

    [Theory]
    [InlineData(IconKey.Person, 16, 16)]
    [InlineData(IconKey.Person, 20, 20)]
    [InlineData(IconKey.CheckmarkCircle, 24, 24)]
    [InlineData(IconKey.HandRaise, 16, 16)]
    // The nearest drawing, where Fluent has none at that size; the larger of two as near.
    [InlineData(IconKey.Pulse, 16, 20)]
    [InlineData(IconKey.BranchRequest, 24, 20)]
    [InlineData(IconKey.HandRaise, 20, 16)]
    [InlineData(IconKey.Person, 18, 20)]
    public void ShowsTheDrawingMadeForTheSizeOrTheNearest(IconKey icon, double size, int drawn)
    {
        Assert.Equal(expected: drawn, actual: IconPaths.Of(icon: icon, size: size).Size);
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
