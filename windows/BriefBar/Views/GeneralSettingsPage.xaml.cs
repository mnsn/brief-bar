using BriefBar.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BriefBar.Views;

/// Settings' General page: what BriefBar asks before it reads anything, its sources and whether each is on, what the bar
/// shows behind its words, and quitting.
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

    /// Windows' color picker, as its own Settings shows for a custom accent color, with how see-through it is.
    async void OnChooseColorClick(object sender, RoutedEventArgs e)
    {
        var picker = new ColorPicker
        {
            Color = ViewModel.Appearance.Chosen,
            ColorSpectrumShape = ColorSpectrumShape.Box,
            IsAlphaEnabled = true,
            IsAlphaSliderVisible = true,
            IsAlphaTextInputVisible = true,
            IsColorChannelTextInputVisible = true,
            IsHexInputVisible = true,
            IsMoreButtonVisible = true,
        };
        var dialog = new ContentDialog
        {
            Title = "Choose the bar's color",
            Content = picker,
            PrimaryButtonText = "Done",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            ViewModel.Appearance.Choose(color: picker.Color);
        }
    }
}
