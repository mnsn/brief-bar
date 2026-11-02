using BriefBar.Core;
using BriefBar.ViewModels;
using BriefBar.Views;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
    readonly SettingsViewModel viewModel;
    readonly SettingsView view;
    bool closed;

    public SettingsWindow(AppShell shell, SettingsViewModel viewModel)
    {
        this.shell = shell;
        this.viewModel = viewModel;
        Hwnd = WindowNative.GetWindowHandle(target: this);
        Title = "BriefBar Settings";
        view = new SettingsView(viewModel: viewModel, palette: shell.Palette);
        view.TurnOnRequested += async (_, source) => await SwitchAsync(source: source, turnOn: true);
        view.TurnOffRequested += async (_, source) => await SwitchAsync(source: source, turnOn: false);
        view.QuitRequested += (_, _) => shell.Quit();
        Content = view;
        FrameTheme.Follow(hwnd: Hwnd, content: view);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(titleBar: view.TitleBarElement);
        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
        Closed += (_, _) => closed = true;
        PlaceOnPrimaryDisplay();
    }

    public nint Hwnd { get; }

    /// Shows `source`'s page, or General, and brings it to the front, restored if it was minimized.
    public void Show(SourceId? source)
    {
        view.Show(source: source);
        if (Interop.User32.IsIconic(hWnd: Hwnd))
        {
            Interop.User32.ShowWindow(hWnd: Hwnd, command: Interop.WindowStyles.SW_RESTORE);
        }
        Activate();
        Foreground.Bring(hwnd: Hwnd);
    }

    /// Whether each source is on, as it stands now.
    public void Refresh() => view.Refresh();

    public void UsePalette(ThemePalette palette) => view.UsePalette(palette: palette);

    /// Windows' colors or Transparency effects changed, or what the bar shows: Appearance says what it shows now.
    public void AppearanceChanged() => viewModel.Appearance.Refresh();

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

    /// Turns `source` on, or keeps it on, or turns it off, one change at a time; then shows how it stands, and says so
    /// when your choice couldn't be saved, as on a full disk.
    async Task SwitchAsync(SourceSettingsViewModel source, bool turnOn)
    {
        if (source.IsBusy)
        {
            return;
        }
        source.IsBusy = true;
        bool saved;
        try
        {
            saved = turnOn
                ? await shell.TurnOnAsync(entry: source.Entry).ConfigureAwait(continueOnCapturedContext: true)
                : await shell.TurnOffAsync(entry: source.Entry).ConfigureAwait(continueOnCapturedContext: true);
        }
        catch (OperationCanceledException) when (shell.IsQuitting)
        {
            // BriefBar quit before the source could start: it starts the next time, as saved.
            return;
        }
        finally
        {
            source.IsBusy = false;
            if (!closed)
            {
                view.Refresh();
            }
        }
        if (!saved && !closed)
        {
            await SayNotSavedAsync(name: source.Name, isOn: turnOn).ConfigureAwait(continueOnCapturedContext: true);
        }
    }

    /// What a choice that couldn't be saved means, until BriefBar can save it.
    async Task SayNotSavedAsync(string name, bool isOn)
    {
        var dialog = new ContentDialog
        {
            Title = "Couldn't save your choice",
            Content = isOn
                ? name + " is on, but BriefBar couldn't save that, so it'll be off the next time BriefBar starts. BriefBar "
                    + "tries again whenever a setting changes, and as it quits."
                : name + " is off, but BriefBar couldn't save that, so it may be on again the next time BriefBar starts. "
                    + "BriefBar tries again whenever a setting changes, and as it quits.",
            CloseButtonText = "OK",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = view.XamlRoot,
            RequestedTheme = view.ActualTheme,
        };
        await dialog.ShowAsync();
    }
}
