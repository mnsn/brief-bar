using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class ReadableTintTests
{
    const uint White = 0xFFFFFFFFu;
    const uint Black = 0xFF000000u;

    /// Hues every 30 degrees, gray among them, at five lightnesses, from fully see-through to opaque: what a color
    /// of your own can be.
    public static TheoryData<uint> Colors
    {
        get
        {
            var colors = new List<uint>();
            foreach (var alpha in new uint[] { 0x00, 0x40, 0x80, 0xCC, 0xFF })
            {
                foreach (var lightness in new[] { 0.1, 0.3, 0.5, 0.7, 0.9 })
                {
                    foreach (var saturation in new[] { 0.0, 0.6, 1.0 })
                    {
                        for (var hue = 0; hue < 360; hue += saturation == 0 ? 360 : 30)
                        {
                            colors.Add(item: (alpha << 24) | (Hsl(hue: hue, saturation: saturation, lightness: lightness) & 0x00FFFFFFu));
                        }
                    }
                }
            }
            return [.. colors];
        }
    }

    /// Whatever you choose, the bar's words, labels, quietest words and state colors stand out on it over any
    /// wallpaper, white to black, with an item at rest or open and pointed at; and it's never more see-through than you
    /// chose.
    [Theory]
    [MemberData(memberName: nameof(Colors))]
    public void EveryColorShowsReadable(uint chosen)
    {
        foreach (var transparencyEffects in new[] { true, false })
        {
            var tint = ReadableTint.Of(chosen: chosen, dark: null, transparencyEffects: transparencyEffects);
            Assert.True(condition: (tint.Color >> 24) >= (chosen >> 24), userMessage: $"#{chosen:X8} shows more see-through than chosen.");
            if (!transparencyEffects)
            {
                Assert.Equal(expected: 0xFFu, actual: tint.Color >> 24);
            }
            var dark = tint.IsDark;
            uint Readable(uint color, double least) =>
                StatePalette.Readable(color: color, background: tint.WorkedOutAgainst, dark: dark, least: least);
            uint Words(uint words, double least) =>
                StatePalette.WordsOver(words: words, background: tint.WorkedOutAgainst, dark: dark, least: least);
            foreach (var wallpaper in new[] { White, Black })
            {
                var behind = StatePalette.Over(argb: tint.Color, background: wallpaper);
                foreach (var shown in new[] { behind, StatePalette.UnderBarItem(background: behind, dark: dark) })
                {
                    AssertReads(foreground: StatePalette.Over(argb: Words(words: StatePalette.Words(dark: dark), least: Wcag.TextContrast), background: shown), background: shown, least: Wcag.TextContrast, chosen: chosen);
                    AssertReads(foreground: StatePalette.Over(argb: Words(words: StatePalette.SecondaryWords(dark: dark), least: Wcag.TextContrast), background: shown), background: shown, least: Wcag.TextContrast, chosen: chosen);
                    AssertReads(foreground: StatePalette.Over(argb: Words(words: StatePalette.TertiaryWords(dark: dark), least: Wcag.GraphicsContrast), background: shown), background: shown, least: Wcag.GraphicsContrast, chosen: chosen);
                    foreach (var state in StateCounts.AllStates)
                    {
                        AssertReads(foreground: Readable(color: StatePalette.Fill(state: state, dark: dark), least: Wcag.GraphicsContrast), background: shown, least: Wcag.GraphicsContrast, chosen: chosen);
                        AssertReads(foreground: Readable(color: StatePalette.Text(state: state, dark: dark), least: Wcag.TextContrast), background: shown, least: Wcag.TextContrast, chosen: chosen);
                    }
                    AssertReads(foreground: Readable(color: StatePalette.Quiet(dark: dark), least: Wcag.TextContrast), background: shown, least: Wcag.TextContrast, chosen: chosen);
                }
            }
        }
    }

    /// Windows' own see-through colors, 80% of the taskbar's flat ones and of the accent's default shade, read as they
    /// are, and Settings says nothing under them.
    [Theory]
    [InlineData(0xCCEEEEEEu, false)]
    [InlineData(0xCC1C1C1Cu, true)]
    [InlineData(0xCC003E92u, true)]
    public void ShowsAColorThatReadsAsChosen(uint chosen, bool dark)
    {
        var tint = ReadableTint.Of(chosen: chosen, dark: null, transparencyEffects: true);
        Assert.Equal(expected: (chosen, dark), actual: (tint.Color, tint.IsDark));
        Assert.False(condition: tint.IsMoreOpaque || tint.IsShaded || tint.IsOpaqueForWindows);
        Assert.Null(@object: tint.Note);
    }

    [Fact]
    public void MakesAColorTooSeeThroughJustOpaqueEnough()
    {
        var tint = ReadableTint.Of(chosen: 0x33FFFFFFu, dark: null, transparencyEffects: true);
        Assert.False(condition: tint.IsDark);
        Assert.True(condition: tint.IsMoreOpaque);
        // One step less doesn't read: shown that way, it would be made more opaque again.
        Assert.True(condition: ReadableTint.Of(chosen: tint.Color - 0x01000000u, dark: null, transparencyEffects: true).IsMoreOpaque);
        Assert.Equal(expected: tint.Color, actual: ReadableTint.Of(chosen: tint.Color, dark: null, transparencyEffects: true).Color);
        Assert.Matches(expectedRegexPattern: @"^Shown \d+% opaque, so the bar's words stay readable on any wallpaper\.$", actualString: tint.Note);
    }

    /// A mid-toned purple reads with neither white nor black words, even opaque, behind an item that's open and pointed
    /// at: it shows a shade darker, with white words, which read better on it.
    [Fact]
    public void ShadesAColorThatDoesntReadEvenOpaque()
    {
        var tint = ReadableTint.Of(chosen: 0xFF5B5FC7u, dark: null, transparencyEffects: true);
        Assert.True(condition: tint.IsShaded && tint.IsDark);
        Assert.Equal(expected: 0xFFu, actual: tint.Color >> 24);
        Assert.Equal(expected: "Shown a shade darker, so the bar's words stay readable.", actual: tint.Note);
        Assert.Equal(
            expected: "Shown opaque and a shade darker, so the bar's words stay readable on any wallpaper.",
            actual: ReadableTint.Of(chosen: 0x805B5FC7u, dark: null, transparencyEffects: true).Note);
    }

    [Fact]
    public void ShowsOpaqueWithTransparencyEffectsOff()
    {
        var tint = ReadableTint.Of(chosen: 0x80FFFFFFu, dark: null, transparencyEffects: false);
        Assert.Equal(expected: White, actual: tint.Color);
        Assert.True(condition: tint.IsOpaqueForWindows);
        Assert.False(condition: tint.IsMoreOpaque);
        Assert.Equal(expected: "Shown opaque, as Transparency effects is off in Windows.", actual: tint.Note);
        // An opaque color was chosen opaque: nothing to say.
        Assert.Null(@object: ReadableTint.Of(chosen: White, dark: null, transparencyEffects: false).Note);
    }

    /// Automatic keeps Windows' mode for the bar's words: a light color with light words is shaded until they read.
    [Fact]
    public void KeepsTheWordsItsAskedFor()
    {
        var tint = ReadableTint.Of(chosen: 0xCCEEEEEEu, dark: true, transparencyEffects: true);
        Assert.True(condition: tint.IsDark);
        Assert.True(condition: tint.IsShaded);
    }

    static void AssertReads(uint foreground, uint background, double least, uint chosen)
    {
        var contrast = Wcag.Contrast(first: foreground, second: background);
        Assert.True(
            condition: contrast >= least,
            userMessage: $"On #{chosen:X8}: #{foreground:X8} on #{background:X8} is {contrast:0.00} to 1, under {least} to 1.");
    }

    /// An opaque color from hue (degrees), saturation and lightness (0 to 1).
    static uint Hsl(int hue, double saturation, double lightness)
    {
        var chroma = (1 - Math.Abs(value: (2 * lightness) - 1)) * saturation;
        var x = chroma * (1 - Math.Abs(value: (hue / 60.0 % 2) - 1));
        var m = lightness - (chroma / 2);
        var (r, g, b) = (hue / 60) switch
        {
            0 => (chroma, x, 0.0),
            1 => (x, chroma, 0.0),
            2 => (0.0, chroma, x),
            3 => (0.0, x, chroma),
            4 => (x, 0.0, chroma),
            _ => (chroma, 0.0, x),
        };
        static uint Channel(double value) => (uint)Math.Round(value: value * 255, mode: MidpointRounding.AwayFromZero);
        return 0xFF000000u | (Channel(value: r + m) << 16) | (Channel(value: g + m) << 8) | Channel(value: b + m);
    }
}
