namespace BriefBar.Core.Presentation;

/// What the bar shows behind its words, as you choose in Settings › General › Appearance.
public enum BarBackground
{
    /// Acrylic, or see-through where Windows draws no acrylic, as over Remote Desktop.
    Automatic,

    /// Acrylic, or flat where Windows draws no acrylic, as the taskbar is.
    LikeTheTaskbar,

    /// A color of your own, as see-through as you like.
    CustomColor,
}
