using System.Diagnostics.CodeAnalysis;
using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.Shell;

/// Windows 11's acrylic, as an active window shows it. The bar is never the active window, and acrylic in an inactive
/// window turns into a flat color. Where Windows draws no acrylic, as over Remote Desktop, with Transparency effects off
/// or with energy saver, Windows shows the acrylic's flat fallback color by itself. It can be tinted, as the taskbar is
/// with the accent color (`UseTint`).
[SuppressMessage(
    category: "Reliability",
    checkId: "CA1001:Types that own disposable fields should be disposable",
    Justification = "A backdrop's controller lives exactly as long as its window's connection to it: it's made when the window connects and disposed when it disconnects.")]
internal sealed partial class ActiveAcrylic(DesktopAcrylicKind kind) : SystemBackdrop
{
    /// How strong a tint is over what's behind, and how much of what's behind keeps its brightness: the taskbar's
    /// look, and flat in the tint itself where Windows draws no acrylic, as the taskbar is then.
    const float TintOpacity = 0.8f;
    const float LuminosityOpacity = 0.85f;

    DesktopAcrylicController? controller;
    SystemBackdropConfiguration? configuration;
    FrameworkElement? root;
    Windows.UI.Color? tint;

    /// Tints it with `color`, as the taskbar is with the accent color, or gives it Windows' own colors again with null.
    public void UseTint(Windows.UI.Color? color)
    {
        tint = color;
        ApplyTint();
    }

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
    {
        ArgumentNullException.ThrowIfNull(argument: xamlRoot);
        base.OnTargetConnected(connectedTarget: connectedTarget, xamlRoot: xamlRoot);
        root = xamlRoot.Content as FrameworkElement;
        configuration = new SystemBackdropConfiguration { IsInputActive = true, Theme = ThemeOf(element: root) };
        if (root is not null)
        {
            root.ActualThemeChanged += OnThemeChanged;
        }
        controller = new DesktopAcrylicController { Kind = kind };
        ApplyTint();
        controller.AddSystemBackdropTarget(systemBackdropTarget: connectedTarget);
        controller.SetSystemBackdropConfiguration(configuration: configuration);
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop disconnectedTarget)
    {
        base.OnTargetDisconnected(disconnectedTarget: disconnectedTarget);
        if (root is not null)
        {
            root.ActualThemeChanged -= OnThemeChanged;
            root = null;
        }
        controller?.RemoveSystemBackdropTarget(systemBackdropTarget: disconnectedTarget);
        controller?.Dispose();
        controller = null;
    }

    /// WinUI calls this as Windows switches between light and dark, to apply its default configuration, with a target
    /// or XamlRoot it holds only weakly, so either can be null despite the signature. WinUI's base implementation
    /// rejects a null one (`E_INVALIDARG`), which ended BriefBar, so don't call it. This backdrop keeps its own
    /// configuration, always active, which follows the theme as its content does (`OnThemeChanged`).
    protected override void OnDefaultSystemBackdropConfigurationChanged(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
    }

    void ApplyTint()
    {
        if (controller is null)
        {
            return;
        }
        if (tint is { } color)
        {
            controller.TintColor = color;
            controller.TintOpacity = TintOpacity;
            controller.LuminosityOpacity = LuminosityOpacity;
            controller.FallbackColor = color;
        }
        else
        {
            controller.ResetProperties();
        }
    }

    void OnThemeChanged(FrameworkElement sender, object args)
    {
        if (configuration is not null)
        {
            configuration.Theme = ThemeOf(element: sender);
        }
    }

    static SystemBackdropTheme ThemeOf(FrameworkElement? element) =>
        element?.ActualTheme == ElementTheme.Dark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
}
