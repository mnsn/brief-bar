using BriefBar.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BriefBar.Views;

/// Settings' General page: what BriefBar asks before it reads anything, its sources and whether each is on, and quitting.
public sealed partial class GeneralSettingsPage : UserControl
{
    public GeneralSettingsPage(SettingsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
    }

    public SettingsViewModel ViewModel { get; }

    /// A source's card was pressed: its page opens.
    public event EventHandler<SourceSettingsViewModel>? SourceRequested;

    public event EventHandler? QuitRequested;

    void OnSourceClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: SourceSettingsViewModel source })
        {
            SourceRequested?.Invoke(sender: this, e: source);
        }
    }

    void OnQuitClick(object sender, RoutedEventArgs e) => QuitRequested?.Invoke(sender: this, e: EventArgs.Empty);
}
