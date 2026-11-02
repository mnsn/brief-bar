using BriefBar.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace BriefBar.Views;

/// Teams' own settings, on its page in Settings while it's on.
public sealed partial class TeamsSettingsView : UserControl
{
    public TeamsSettingsView(TeamsSettingsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
    }

    public TeamsSettingsViewModel ViewModel { get; }
}
