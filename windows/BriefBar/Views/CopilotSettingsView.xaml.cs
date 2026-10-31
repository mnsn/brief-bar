using BriefBar.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace BriefBar.Views;

/// Copilot's own settings, on its page in Settings while it's on.
public sealed partial class CopilotSettingsView : UserControl
{
    public CopilotSettingsView(CopilotSettingsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
    }

    public CopilotSettingsViewModel ViewModel { get; }
}
