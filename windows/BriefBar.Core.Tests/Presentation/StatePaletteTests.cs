using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

/// The states' and sources' colors meet WCAG 2.2 AA in light and dark: 4.5 to 1 for words, 3 to 1 for icons, dots and
/// badges.
public sealed class StatePaletteTests
{
    public static TheoryData<bool> Themes => [false, true];

    [Theory]
    [MemberData(memberName: nameof(Themes))]
    public void WordsInAStatesColorAreReadable(bool dark)
    {
        var background = StatePalette.Background(dark: dark);
        foreach (var state in StateCounts.AllStates)
        {
            AssertContrast(foreground: StatePalette.Text(state: state, dark: dark), background: background, least: Wcag.TextContrast);
        }
        AssertContrast(foreground: StatePalette.Caution(dark: dark), background: background, least: Wcag.TextContrast);
        AssertContrast(foreground: StatePalette.PillText(dark: dark), background: StatePalette.PillFill(dark: dark), least: Wcag.TextContrast);
    }

    [Theory]
    [MemberData(memberName: nameof(Themes))]
    public void IconsAndBadgesStandOut(bool dark)
    {
        var background = StatePalette.Background(dark: dark);
        foreach (var state in StateCounts.AllStates)
        {
            AssertContrast(foreground: StatePalette.Fill(state: state, dark: dark), background: background, least: Wcag.GraphicsContrast);
            AssertContrast(
                foreground: StatePalette.OnFill(dark: dark), background: StatePalette.Fill(state: state, dark: dark), least: Wcag.GraphicsContrast);
        }
        AssertContrast(foreground: StatePalette.PillFill(dark: dark), background: background, least: Wcag.GraphicsContrast);
        AssertContrast(foreground: StatePalette.Quiet(dark: dark), background: background, least: Wcag.GraphicsContrast);
    }

    [Theory]
    [MemberData(memberName: nameof(Themes))]
    public void EverySourcesGlyphStandsOut(bool dark)
    {
        foreach (var section in Sections.InBarOrder)
        {
            AssertContrast(
                foreground: StatePalette.Glyph(tint: section.Tint, dark: dark),
                background: StatePalette.Background(dark: dark),
                least: Wcag.GraphicsContrast);
        }
    }

    [Fact]
    public void KeepsASourcesOwnColorWhenItStandsOutAlready()
    {
        // Azure DevOps' blue stands out on light as it is.
        Assert.Equal(expected: 0xFF0078D4u, actual: StatePalette.Glyph(tint: 0xFF0078D4u, dark: false));
        // Teams' purple doesn't on dark, so it's lightened, and stays a purple.
        var lightened = StatePalette.Glyph(tint: 0xFF5B5FC7u, dark: true);
        Assert.NotEqual(expected: 0xFF5B5FC7u, actual: lightened);
        Assert.True(condition: (lightened & 0xFF) > ((lightened >> 16) & 0xFF), userMessage: "Still more blue than red.");
    }

    [Fact]
    public void EveryStateHasItsOwnColor()
    {
        foreach (var dark in new[] { false, true })
        {
            var fills = StateCounts.AllStates.Select(selector: state => StatePalette.Fill(state: state, dark: dark)).ToList();
            Assert.Equal(expected: fills.Count, actual: fills.Distinct().Count());
        }
    }

    [Fact]
    public void MeasuresContrastAsWcagDoes()
    {
        Assert.Equal(expected: 21, actual: Wcag.Contrast(first: 0xFF000000u, second: 0xFFFFFFFFu), precision: 6);
        Assert.Equal(expected: 21, actual: Wcag.Contrast(first: 0xFFFFFFFFu, second: 0xFF000000u), precision: 6);
        Assert.Equal(expected: 1, actual: Wcag.Contrast(first: 0xFF777777u, second: 0xFF777777u), precision: 6);
        // #767676 on white is the classic 4.54 to 1.
        Assert.Equal(expected: 4.54, actual: Wcag.Contrast(first: 0xFF767676u, second: 0xFFFFFFFFu), precision: 2);
    }

    static void AssertContrast(uint foreground, uint background, double least)
    {
        var contrast = Wcag.Contrast(first: foreground, second: background);
        Assert.True(
            condition: contrast >= least,
            userMessage: $"#{foreground:X8} on #{background:X8} is {contrast:0.00} to 1, under {least} to 1.");
    }
}
