using Microsoft.UI.Xaml.Automation.Peers;

namespace BriefBar.Views;

/// An item in the bar, as UI Automation sees it: one button, whose name says everything its words and counts do, so
/// Narrator doesn't read them again, one by one, as "3", "2", "·".
internal sealed partial class BarItemButtonAutomationPeer(BarItemButton owner) : ButtonAutomationPeer(owner: owner)
{
    protected override IList<AutomationPeer> GetChildrenCore() => [];
}
