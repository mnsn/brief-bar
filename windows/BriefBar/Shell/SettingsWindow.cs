using BriefBar.Core;
using BriefBar.ViewModels;
using BriefBar.Views;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using WinRT.Interop;

namespace BriefBar.Shell;

/// BriefBar's Settings, in a window of its own, as Windows 11's apps have: on the taskbar and in Alt+Tab while it's
/// open. Only one is open at a time; closing it closes it for good, and the next opens anew.
internal sealed partial class SettingsWindow : Window
{
    /// Its size as it opens, in device-independent pixels, as far as the display allows.
    const double WidthDip = 980;
    const double HeightDip = 720;

    readonly AppShell shell;
    readonly SettingsView view;

    public SettingsWindow(AppShell shell, SettingsViewModel viewModel)
    {
        this.shell = shell;
        Hwnd = WindowNative.GetWindowHandle(target: this);
        Title = "BriefBar Settings";
        view = new SettingsView(viewModel: viewModel, palette: shell.Palette);
        view.TurnOnRequested += (_, source) => TurnOn(source: source);
        view.TurnOffRequested += (_, source) => TurnOff(source: source);
        view.QuitRequested += (_, _) => shell.Quit();
        Content = view;
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(titleBar: view.TitleBarElement);
        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
        PlaceOnPrimaryDisplay();
    }

    public nint Hwnd { get; }

    /// Shows `source`'s page, or General, and brings it to the front.
    public void Show(SourceId? source)
    {
        view.Show(source: source);
        Activate();
        Foreground.Bring(hwnd: Hwnd);
    }

    /// Whether each source is on, as it stands now.
    public void Refresh() => view.Refresh();

    public void UsePalette(ThemePalette palette) => view.UsePalette(palette: palette);

    /// Centered on the main display, at its size or as large as the display allows.
    void PlaceOnPrimaryDisplay()
    {
        var display = DisplayArea.GetFromWindowId(windowId: AppWindow.Id, displayAreaFallback: DisplayAreaFallback.Primary);
        var scale = Interop.User32.GetDpiForWindow(hWnd: Hwnd) / 96.0;
        var work = display.WorkArea;
        var width = Math.Min(val1: (int)Math.Round(a: WidthDip * scale), val2: work.Width);
        var height = Math.Min(val1: (int)Math.Round(a: HeightDip * scale), val2: work.Height);
        AppWindow.MoveAndResize(rect: new RectInt32(
            _X: work.X + ((work.Width - width) / 2),
            _Y: work.Y + ((work.Height - height) / 2),
            _Width: width,
            _Height: height));
    }

    async void TurnOn(SourceSettingsViewModel source)
    {
        if (source.IsBusy)
        {
            return;
        }
        source.IsBusy = true;
        try
        {
            await shell.TurnOnAsync(entry: source.Entry);
        }
        finally
        {
            source.IsBusy = false;
            view.Refresh();
        }
    }

    async void TurnOff(SourceSettingsViewModel source)
    {
        if (source.IsBusy)
        {
            return;
        }
        source.IsBusy = true;
        try
        {
            await shell.TurnOffAsync(entry: source.Entry);
        }
        finally
        {
            source.IsBusy = false;
            view.Refresh();
        }
    }
}
