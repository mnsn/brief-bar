using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class BarSurfaceTests
{
    static readonly ShellLook light = new(IsDark: false, UsesAccent: false);
    static readonly ShellLook dark = new(IsDark: true, UsesAccent: false);
    static readonly ShellLook darkWithAccent = new(IsDark: true, UsesAccent: true);
    const uint Accent = 0xFF003E92u;

    [Fact]
    public void IsAcrylicWhereWindowsDrawsIt()
    {
        foreach (var look in new[] { light, dark })
        {
            var surface = For(background: BarBackground.Automatic, look: look);
            Assert.Equal(expected: BarMaterial.Acrylic, actual: surface.Material);
            Assert.Null(@object: surface.Color);
            Assert.Equal(expected: look.IsDark, actual: surface.IsDark);
            Assert.Equal(expected: StatePalette.BarBackground(accent: null, dark: look.IsDark), actual: surface.WorkedOutAgainst);
        }
        // Tinted with the taskbar's accent, as the taskbar is.
        Assert.Equal(expected: Accent, actual: For(background: BarBackground.Automatic, look: darkWithAccent).Color);
    }

    /// Automatic, over Remote Desktop with Transparency effects on: the color the taskbar is flat in there, at 80%,
    /// which reads as it is in Windows' colors, the accent's default shade's included.
    [Fact]
    public void IsSeeThroughWhereWindowsDrawsNoAcrylic()
    {
        Assert.Equal(
            expected: new BarSurface(
                Material: BarMaterial.SeeThrough,
                Color: 0xCCEEEEEEu,
                IsDark: false,
                WorkedOutAgainst: StatePalette.UnderSeeThrough(tint: 0xCCEEEEEEu, dark: false)),
            actual: For(background: BarBackground.Automatic, look: light, drawsAcrylic: false));
        Assert.Equal(expected: 0xCC1C1C1Cu, actual: For(background: BarBackground.Automatic, look: dark, drawsAcrylic: false).Color);
        var accent = For(background: BarBackground.Automatic, look: darkWithAccent, drawsAcrylic: false);
        Assert.Equal(expected: (BarMaterial.SeeThrough, 0xCC003E92u, true), actual: (accent.Material, accent.Color!.Value, accent.IsDark));
    }

    [Fact]
    public void IsFlatWithTransparencyEffectsOffOrLikeTheTaskbar()
    {
        // Acrylic, which Windows shows flat by itself there.
        Assert.Equal(expected: BarMaterial.Acrylic, actual: For(background: BarBackground.Automatic, look: dark, drawsAcrylic: false, transparencyEffects: false).Material);
        Assert.Equal(expected: BarMaterial.Acrylic, actual: For(background: BarBackground.LikeTheTaskbar, look: dark, drawsAcrylic: false).Material);
        Assert.Equal(expected: BarMaterial.Acrylic, actual: For(background: BarBackground.LikeTheTaskbar, look: light).Material);
    }

    /// Your own color shows as chosen, without blur, where Windows draws acrylic too; opaque with Transparency effects
    /// off; and as Automatic until you choose one.
    [Fact]
    public void ShowsYourColorEverywhere()
    {
        var mine = For(background: BarBackground.CustomColor, look: light, customColor: 0xB3101010u);
        Assert.Equal(expected: (BarMaterial.SeeThrough, 0xB3101010u, true), actual: (mine.Material, mine.Color!.Value, mine.IsDark));
        Assert.Equal(expected: 0xFF101010u, actual: For(background: BarBackground.CustomColor, look: light, customColor: 0xB3101010u, transparencyEffects: false).Color);
        Assert.Equal(expected: For(background: BarBackground.Automatic, look: dark, drawsAcrylic: false), actual: For(background: BarBackground.CustomColor, look: dark, drawsAcrylic: false));
    }

    [Fact]
    public void ShowsWindowsColorsInHighContrast()
    {
        var surface = For(background: BarBackground.CustomColor, look: darkWithAccent, customColor: 0x40FF0000u, drawsAcrylic: false, highContrast: true);
        Assert.Equal(expected: (BarMaterial.Acrylic, (uint?)null), actual: (surface.Material, surface.Color));
    }

    static BarSurface For(
        BarBackground background, ShellLook look, uint? customColor = null, bool drawsAcrylic = true, bool transparencyEffects = true, bool highContrast = false) =>
        BarSurface.For(
            background: background,
            customColor: customColor,
            look: look,
            accent: Accent,
            drawsAcrylic: drawsAcrylic,
            transparencyEffects: transparencyEffects,
            highContrast: highContrast);
}
