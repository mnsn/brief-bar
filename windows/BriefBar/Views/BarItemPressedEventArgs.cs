using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml;

namespace BriefBar.Views;

/// An item in the bar was pressed: which panel it opens, and the item itself, for where that panel goes.
public sealed class BarItemPressedEventArgs(PanelTarget target, FrameworkElement item) : EventArgs
{
    public PanelTarget Target { get; } = target;

    public FrameworkElement Item { get; } = item;
}
