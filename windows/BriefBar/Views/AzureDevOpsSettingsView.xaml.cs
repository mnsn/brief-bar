using BriefBar.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace BriefBar.Views;

/// Azure DevOps' own settings, on its page in Settings while it's on. Enter in a box does what its button does.
public sealed partial class AzureDevOpsSettingsView : UserControl
{
    public AzureDevOpsSettingsView(AzureDevOpsSettingsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
    }

    public AzureDevOpsSettingsViewModel ViewModel { get; }

    void OnAddOrganizationClick(object sender, RoutedEventArgs e) => ViewModel.AddOrganization();

    void OnOrganizationKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            ViewModel.AddOrganization();
        }
    }

    void OnFindOrganizationsClick(object sender, RoutedEventArgs e) => ViewModel.FindOrganizations();

    void OnNoteSignInClick(object sender, RoutedEventArgs e) => ViewModel.SignInFromNote();

    void OnWatchClick(object sender, RoutedEventArgs e) => ViewModel.Watch();

    void OnLinkKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            ViewModel.Watch();
        }
    }

    void OnStopWatchingClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: WatchedPullRequestViewModel pullRequest })
        {
            ViewModel.StopWatching(pullRequest: pullRequest);
        }
    }
}
