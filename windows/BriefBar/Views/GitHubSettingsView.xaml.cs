using BriefBar.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace BriefBar.Views;

/// GitHub's own settings, on its page in Settings while it's on.
public sealed partial class GitHubSettingsView : UserControl
{
    public GitHubSettingsView(GitHubSettingsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
    }

    public GitHubSettingsViewModel ViewModel { get; }
}
