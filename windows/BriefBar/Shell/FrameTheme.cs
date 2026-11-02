using BriefBar.Core.Logging;
using BriefBar.Interop;
using Microsoft.UI.Xaml;

namespace BriefBar.Shell;

/// The theme Windows draws a window's frame in, its border and shadow, kept the same as its content's. WinUI leaves it
/// light, so a dark panel had a light border.
internal static class FrameTheme
{
    /// Draws `hwnd`'s frame for `content`'s theme, now and as it changes.
    public static void Follow(nint hwnd, FrameworkElement content)
    {
        ArgumentNullException.ThrowIfNull(argument: content);
        Apply(hwnd: hwnd, theme: content.ActualTheme);
        content.ActualThemeChanged += (sender, _) => Apply(hwnd: hwnd, theme: sender.ActualTheme);
    }

    static void Apply(nint hwnd, ElementTheme theme)
    {
        if (!Dwm.TrySet(hWnd: hwnd, attribute: DwmAttributes.DWMWA_USE_IMMERSIVE_DARK_MODE, value: theme == ElementTheme.Dark ? 1 : 0))
        {
            Log.Write(line: $"window {hwnd}: Windows kept its frame's theme");
        }
    }
}
