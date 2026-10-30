using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace BriefBar;

/// Windows 11's acrylic, as an active window shows it. The bar is never the active window, and acrylic in an inactive
/// window turns into a flat color.
internal sealed class ActiveAcrylic(DesktopAcrylicKind kind) : SystemBackdrop
{
    DesktopAcrylicController? controller;
    SystemBackdropConfiguration? configuration;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(target, xamlRoot);
        configuration = new SystemBackdropConfiguration { IsInputActive = true, Theme = ThemeOf(xamlRoot) };
        if (xamlRoot.Content is FrameworkElement root)
        {
            root.ActualThemeChanged += (_, _) =>
            {
                if (configuration is not null) configuration.Theme = ThemeOf(xamlRoot);
            };
        }
        controller = new DesktopAcrylicController { Kind = kind };
        controller.AddSystemBackdropTarget(target);
        controller.SetSystemBackdropConfiguration(configuration);
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        base.OnTargetDisconnected(target);
        controller?.RemoveSystemBackdropTarget(target);
        controller?.Dispose();
        controller = null;
    }

    static SystemBackdropTheme ThemeOf(XamlRoot root) =>
        (root.Content as FrameworkElement)?.ActualTheme == ElementTheme.Dark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
}
