using BriefBar.Core.Presentation;

namespace BriefBar.Views;

/// The panel asks its source to do something, such as open a row's item: what, and whether it opens something
/// elsewhere, which closes the panel.
public sealed class PanelCommandEventArgs(CommandRequest request, bool opens) : EventArgs
{
    public CommandRequest Request { get; } = request;

    public bool Opens { get; } = opens;
}
