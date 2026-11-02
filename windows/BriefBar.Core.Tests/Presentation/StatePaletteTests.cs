using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

/// The states' and sources' colors meet WCAG 2.2 AA in light and dark, on the bar's and the panel's acrylic and on the
/// flat color Windows shows in its place: 4.5 to 1 for words, 3 to 1 for icons, dots and badges.
public sealed class StatePaletteTests
{
    /// Light and dark, each with the backgrounds it can have.
    public static TheoryData<bool, uint> Backgrounds
    {
        get
        {
            var data = new TheoryData<bool, uint>();
            foreach (var dark in new[] { false, true })
            {
                foreach (var background in StatePalette.Backgrounds(dark: dark))
                {
                    data.Add(p1: dark, p2: background);
                }
            }
            return data;
        }
    }

    [Theory]
    [MemberData(memberName: nameof(Backgrounds))]
    public void WordsInAStatesColorAreReadable(bool dark, uint background)
    {
        foreach (var state in StateCounts.AllStates)
        {
            AssertContrast(foreground: StatePalette.Text(state: state, dark: dark), background: background, least: Wcag.TextContrast);
        }
        AssertContrast(foreground: StatePalette.Caution(dark: dark), background: background, least: Wcag.TextContrast);
        // Quiet is for words too: a chat's preview, or the heading of a group that isn't counted.
        AssertContrast(foreground: StatePalette.Quiet(dark: dark), background: background, least: Wcag.TextContrast);
    }

    [Theory]
    [MemberData(memberName: nameof(Backgrounds))]
    public void ChipsWordsAreReadableOnTheChipAsItShows(bool dark, uint background)
    {
        foreach (var kind in Enum.GetValues<RowChipKind>())
        {
            var chip = StatePalette.Over(argb: StatePalette.ChipBackground(kind: kind, dark: dark), background: background);
            AssertContrast(foreground: StatePalette.ChipText(kind: kind, dark: dark), background: chip, least: Wcag.TextContrast);
        }
    }

    [Fact]
    public void KeepsAChipsColorWhereItsReadableAlready()
    {
        // A work item's blue reads well enough on its chip in dark as it is. In light, on Windows' flat color, it's
        // darkened, as a pull request's green is, but only a little: 5%.
        Assert.Equal(
            expected: StatePalette.Text(state: ItemState.Running, dark: true),
            actual: StatePalette.ChipText(kind: RowChipKind.WorkItem, dark: true));
        Assert.Equal(expected: 0xFF005AAFu, actual: StatePalette.ChipText(kind: RowChipKind.WorkItem, dark: false));
        Assert.NotEqual(
            expected: StatePalette.Text(state: ItemState.Done, dark: false),
            actual: StatePalette.ChipText(kind: RowChipKind.PullRequest, dark: false));
        // Faint behind its words: the same color, at 14%.
        Assert.Equal(expected: 0x24u, actual: StatePalette.ChipBackground(kind: RowChipKind.PullRequest, dark: false) >> 24);
    }

    [Fact]
    public void ShowsATranslucentColorAsTheScreenDoes()
    {
        Assert.Equal(expected: 0xFF123456u, actual: StatePalette.Over(argb: 0xFF123456u, background: 0xFFFFFFFFu));
        Assert.Equal(expected: 0xFFF3F3F3u, actual: StatePalette.Over(argb: 0x00123456u, background: 0xFFF3F3F3u));
        // Black at 128 of 255 over white leaves 127 of white.
        Assert.Equal(expected: 0xFF7F7F7Fu, actual: StatePalette.Over(argb: 0x80000000u, background: 0xFFFFFFFFu));
    }

    [Theory]
    [MemberData(memberName: nameof(Backgrounds))]
    public void IconsAndBadgesStandOut(bool dark, uint background)
    {
        foreach (var state in StateCounts.AllStates)
        {
            AssertContrast(foreground: StatePalette.Fill(state: state, dark: dark), background: background, least: Wcag.GraphicsContrast);
            AssertContrast(
                foreground: StatePalette.OnFill(dark: dark), background: StatePalette.Fill(state: state, dark: dark), least: Wcag.GraphicsContrast);
        }
        AssertContrast(foreground: StatePalette.Quiet(dark: dark), background: background, least: Wcag.GraphicsContrast);
    }

    [Theory]
    [MemberData(memberName: nameof(Backgrounds))]
    public void EverySourcesGlyphStandsOut(bool dark, uint background)
    {
        foreach (var section in Sections.InBarOrder)
        {
            AssertContrast(foreground: StatePalette.Glyph(tint: section.Tint, dark: dark), background: background, least: Wcag.GraphicsContrast);
        }
    }

    /// Colors worked out to stand out, a source's glyph and a chip's words, are worked out against the background they
    /// stand out least on: in light, Windows' flat color, darker than acrylic; in dark, acrylic, lighter than the flat
    /// color.
    [Fact]
    public void WorksColorsOutAgainstTheBackgroundTheyStandOutLeastOn()
    {
        Assert.Equal(expected: 0xFFEEEEEEu, actual: StatePalette.Background(dark: false));
        Assert.Equal(expected: StatePalette.Backgrounds(dark: false).MinBy(keySelector: Wcag.Luminance), actual: StatePalette.Background(dark: false));
        Assert.Equal(expected: 0xFF2C2C2Cu, actual: StatePalette.Background(dark: true));
        Assert.Equal(expected: StatePalette.Backgrounds(dark: true).MaxBy(keySelector: Wcag.Luminance), actual: StatePalette.Background(dark: true));
    }

    /// The shade of the accent color the taskbar shows in dark, which the bar then shows too: Windows' default blue's,
    /// `AccentDark2`, as measured on the taskbar, and made-up shades of other hues.
    public static TheoryData<uint> AccentShades => [0xFF003E92u, 0xFF8E1B1Bu, 0xFF0B5A2Au, 0xFF4B1F7Au, 0xFF7A3B00u, 0xFF6B5300u, 0xFF7A0F44u, 0xFF3D3D3Du];

    /// What the bar shows behind its words: its own backgrounds in light and dark, with no accent, and each of the
    /// accent's shades in dark.
    public static TheoryData<bool, uint, uint?> BarBackgrounds
    {
        get
        {
            var data = new TheoryData<bool, uint, uint?>();
            foreach (var dark in new[] { false, true })
            {
                foreach (var background in StatePalette.Backgrounds(dark: dark))
                {
                    data.Add(p1: dark, p2: background, p3: null);
                }
            }
            foreach (var accent in AccentShades)
            {
                data.Add(p1: true, p2: accent, p3: accent);
            }
            return data;
        }
    }

    /// The bar's colors, worked out against `BarBackground`, stand out wherever its items are: at rest, and behind an
    /// item that's open and pointed at, where both of Windows' highlights lie under them.
    [Theory]
    [MemberData(memberName: nameof(BarBackgrounds))]
    public void TheBarsColorsStandOutBehindAnOpenItemPointedAt(bool dark, uint background, uint? accent)
    {
        var workedOutAgainst = StatePalette.BarBackground(accent: accent, dark: dark);
        uint Readable(uint color, double least) =>
            StatePalette.Readable(color: color, background: workedOutAgainst, dark: dark, least: least);
        foreach (var shown in new[] { background, StatePalette.UnderBarItem(background: background, dark: dark) })
        {
            foreach (var state in StateCounts.AllStates)
            {
                AssertContrast(
                    foreground: Readable(color: StatePalette.Fill(state: state, dark: dark), least: Wcag.GraphicsContrast),
                    background: shown,
                    least: Wcag.GraphicsContrast);
                AssertContrast(
                    foreground: Readable(color: StatePalette.Text(state: state, dark: dark), least: Wcag.TextContrast),
                    background: shown,
                    least: Wcag.TextContrast);
            }
            AssertContrast(foreground: Readable(color: StatePalette.Caution(dark: dark), least: Wcag.TextContrast), background: shown, least: Wcag.TextContrast);
            AssertContrast(foreground: Readable(color: StatePalette.Quiet(dark: dark), least: Wcag.TextContrast), background: shown, least: Wcag.TextContrast);
            // Its words, which its glyphs are in too, its labels and its quietest words, which may be translucent, as they show.
            foreach (var (words, least) in new[]
            {
                (StatePalette.Words(dark: dark), Wcag.TextContrast),
                (StatePalette.SecondaryWords(dark: dark), Wcag.TextContrast),
                (StatePalette.TertiaryWords(dark: dark), Wcag.GraphicsContrast),
            })
            {
                var readable = StatePalette.ReadableWords(words: words, background: workedOutAgainst, dark: dark, least: least);
                AssertContrast(foreground: StatePalette.Over(argb: readable, background: shown), background: shown, least: least);
            }

            foreach (var section in Sections.InBarOrder)
            {
                AssertContrast(
                    foreground: Readable(color: StatePalette.Glyph(tint: section.Tint, dark: dark), least: Wcag.GraphicsContrast),
                    background: shown,
                    least: Wcag.GraphicsContrast);
            }
        }
    }

    [Fact]
    public void KeepsWindowsWordsWhereTheyRead()
    {
        // On the bar's own backgrounds, Windows' words read behind an open item pointed at as they are, translucent.
        foreach (var dark in new[] { false, true })
        {
            var background = StatePalette.BarBackground(accent: null, dark: dark);
            Assert.Equal(
                expected: StatePalette.SecondaryWords(dark: dark),
                actual: StatePalette.ReadableWords(words: StatePalette.SecondaryWords(dark: dark), background: background, dark: dark, least: Wcag.TextContrast));
        }
        // On a dark gold accent, labels stand about 4 to 1 there as they are, so they're lightened, and opaque.
        var gold = StatePalette.BarBackground(accent: 0xFF6B5300u, dark: true);
        var labels = StatePalette.SecondaryWords(dark: true);
        Assert.True(condition: Wcag.Contrast(first: StatePalette.Over(argb: labels, background: gold), second: gold) < Wcag.TextContrast, userMessage: "Under 4.5 to 1 as they are.");
        var readable = StatePalette.ReadableWords(words: labels, background: gold, dark: true, least: Wcag.TextContrast);
        Assert.Equal(expected: 0xFFu, actual: readable >> 24);
        AssertContrast(foreground: readable, background: gold, least: Wcag.TextContrast);
    }

    [Fact]
    public void WorksTheBarsColorsOutBehindAnItemWithBothHighlights()
    {
        // Windows' highlight, 9 of 255 black in light and 15 of 255 white in dark, twice: open, and pointed at.
        Assert.Equal(expected: 0xFFDEDEDEu, actual: StatePalette.BarBackground(accent: null, dark: false));
        Assert.Equal(expected: 0xFF444444u, actual: StatePalette.BarBackground(accent: null, dark: true));
        Assert.Equal(expected: StatePalette.UnderBarItem(background: 0xFF003E92u, dark: true), actual: StatePalette.BarBackground(accent: 0xFF003E92u, dark: true));
        // Needs you's orange stands 2.81 to 1 there in light, so the bar's is darker than the panel's.
        var orange = StatePalette.Fill(state: ItemState.NeedsYou, dark: false);
        Assert.True(condition: Wcag.Contrast(first: orange, second: 0xFFDEDEDEu) < Wcag.GraphicsContrast, userMessage: "Under 3 to 1 as it is.");
        Assert.NotEqual(
            expected: orange,
            actual: StatePalette.Readable(color: orange, background: StatePalette.BarBackground(accent: null, dark: false), dark: false, least: Wcag.GraphicsContrast));
    }

    [Fact]
    public void KeepsAColorThatStandsOutOnTheAccentAlready()
    {
        // Done's green reads on Windows' default accent as it is; Quiet's gray is lightened.
        var green = StatePalette.Text(state: ItemState.Done, dark: true);
        Assert.Equal(expected: green, actual: StatePalette.Readable(color: green, background: 0xFF003E92u, dark: true, least: Wcag.TextContrast));
        var gray = StatePalette.Quiet(dark: true);
        Assert.NotEqual(expected: gray, actual: StatePalette.Readable(color: gray, background: 0xFF003E92u, dark: true, least: Wcag.TextContrast));
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
