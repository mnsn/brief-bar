using System.Diagnostics.CodeAnalysis;
using BriefBar.ViewModels;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.Shell;

/// A color over the desktop, without blur: the bar's see-through background, as a brush of Windows' own compositor
/// (`SystemCompositor`) for the window's system backdrop, which shows through where the bar's content is transparent.
/// The window lets the desktop show through it meanwhile (`SeeThroughWindow`).
[SuppressMessage(
    category: "Reliability",
    checkId: "CA1001:Types that own disposable fields should be disposable",
    Justification = "A backdrop's brush lives exactly as long as its window's connection to it: it's made when the window connects and disposed when it disconnects.")]
internal sealed partial class SeeThroughBackdrop : SystemBackdrop
{
    Windows.UI.Composition.CompositionColorBrush? brush;
    Windows.UI.Color color;

    /// Shows `argb`, which may be see-through.
    public void UseColor(uint argb)
    {
        color = ThemePalette.ColorOf(argb: argb);
        if (brush is not null)
        {
            brush.Color = color;
        }
    }

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
    {
        ArgumentNullException.ThrowIfNull(argument: connectedTarget);
        base.OnTargetConnected(connectedTarget: connectedTarget, xamlRoot: xamlRoot);
        brush = SystemCompositor.Get().CreateColorBrush(color: color);
        connectedTarget.SystemBackdrop = brush;
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop disconnectedTarget)
    {
        ArgumentNullException.ThrowIfNull(argument: disconnectedTarget);
        base.OnTargetDisconnected(disconnectedTarget: disconnectedTarget);
        disconnectedTarget.SystemBackdrop = null;
        brush?.Dispose();
        brush = null;
    }

    /// WinUI calls this as Windows switches between light and dark, with a target or XamlRoot it holds only weakly, so
    /// either can be null despite the signature, and its base implementation rejects a null one (`E_INVALIDARG`), which
    /// ended BriefBar: don't call it. Its color is the shell's to choose (`UseColor`).
    protected override void OnDefaultSystemBackdropConfigurationChanged(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
    }
}
