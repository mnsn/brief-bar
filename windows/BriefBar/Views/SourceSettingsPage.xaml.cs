using BriefBar.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BriefBar.Views;

/// A source's page in Settings: what it reads, and turning it on, keeping it on after an update, or turning it off,
/// which asks first, as on the Mac. `settings` are its own, shown while it's on.
public sealed partial class SourceSettingsPage : UserControl
{
    bool confirming;

    public SourceSettingsPage(SourceSettingsViewModel viewModel, UIElement? settings)
    {
        ViewModel = viewModel;
        InitializeComponent();
        OffDescription.Content = Description();
        PausedDescription.Content = Description();
        OnDescription.Content = Description();
        SourceSettings.Content = settings;
    }

    public SourceSettingsViewModel ViewModel { get; }

    /// Turn it on, or keep it on: your consent to what it reads now.
    public event EventHandler? TurnOnRequested;

    public event EventHandler? TurnOffRequested;

    /// Puts the keyboard on what the page asks of you first: turning it on, keeping it on, or, while it's on, its
    /// settings.
    public void FocusFirst()
    {
        var target = ViewModel.State switch
        {
            Core.SourceState.Off => TurnOnButton,
            Core.SourceState.NeedsReview => KeepOnButton,
            _ => null,
        };
        target?.Focus(value: FocusState.Programmatic);
    }

    SourceDescriptionView Description() => new(reads: ViewModel.Reads, network: ViewModel.Network, needs: ViewModel.Needs);

    void OnTurnOnClick(object sender, RoutedEventArgs e) => TurnOnRequested?.Invoke(sender: this, e: EventArgs.Empty);

    /// A paused source turns off without asking, as on the Mac: it reads nothing already.
    void OnTurnOffNowClick(object sender, RoutedEventArgs e) => TurnOffRequested?.Invoke(sender: this, e: EventArgs.Empty);

    async void OnTurnOffClick(object sender, RoutedEventArgs e)
    {
        if (confirming)
        {
            return;
        }
        confirming = true;
        try
        {
            var dialog = new ContentDialog
            {
                Title = "Turn off " + ViewModel.Name + "?",
                Content = "BriefBar stops reading it, removes it from the bar and deletes what it saved for it. Its settings stay.",
                PrimaryButtonText = "Turn off",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = XamlRoot,
                RequestedTheme = ActualTheme,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                TurnOffRequested?.Invoke(sender: this, e: EventArgs.Empty);
            }
        }
        finally
        {
            confirming = false;
        }
    }
}
