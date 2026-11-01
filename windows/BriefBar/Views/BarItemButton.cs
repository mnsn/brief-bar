using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BriefBar.Views;

/// An item in the bar: a button as tall as the bar, which acts as you press it, and is marked while its panel is open,
/// as the taskbar marks the app in front. Its look is `BarItemButtonStyle`, in Themes/Controls.xaml.
public sealed partial class BarItemButton : Button
{
    public static readonly DependencyProperty IsOpenProperty = DependencyProperty.Register(
        name: nameof(IsOpen),
        propertyType: typeof(bool),
        ownerType: typeof(BarItemButton),
        typeMetadata: new PropertyMetadata(defaultValue: false, propertyChangedCallback: OnIsOpenChanged));

    public bool IsOpen
    {
        get => (bool)GetValue(dp: IsOpenProperty);
        set => SetValue(dp: IsOpenProperty, value: value);
    }

    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        ShowOpenState(useTransitions: false);
    }

    static void OnIsOpenChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((BarItemButton)sender).ShowOpenState(useTransitions: true);

    void ShowOpenState(bool useTransitions) =>
        VisualStateManager.GoToState(control: this, stateName: IsOpen ? "Open" : "Closed", useTransitions: useTransitions);
}
