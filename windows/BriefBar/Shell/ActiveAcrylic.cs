using System.Diagnostics.CodeAnalysis;
using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.Shell;

/// Windows 11's acrylic, as an active window shows it. The bar is never the active window, and acrylic in an inactive
/// window turns into a flat color. When transparency is off, as in some remote sessions or with energy saver, Windows
/// shows the acrylic's solid fallback color by itself.
[SuppressMessage(
    category: "Reliability",
    checkId: "CA1001:Types that own disposable fields should be disposable",
    Justification = "A backdrop's controller lives exactly as long as its window's connection to it: it's made when the window connects and disposed when it disconnects.")]
internal sealed partial class ActiveAcrylic(DesktopAcrylicKind kind) : SystemBackdrop
{
    DesktopAcrylicController? controller;
    SystemBackdropConfiguration? configuration;
    FrameworkElement? root;

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
