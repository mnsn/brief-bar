namespace BriefBar.Core.Presentation;

/// Something a panel can ask a source to do, to one of its rows or groups or to its section, by `Key`, with what it's
/// called in a menu or on a button, "Open in GitHub Copilot" or "Clear", what it does, for its tooltip, and whether it
/// opens something elsewhere, which closes the panel, as it does on the Mac.
public sealed record PanelCommand(string Key, string Title, string? Help = null, bool Opens = false)
{
    /// Its icon on a button at the panel's foot.
    public IconKey Icon { get; init; } = IconKey.Open;

    /// Whether its button at the panel's foot is its icon alone, beside Settings, as the Mac's refresh is; its title is
    /// then its name for screen readers, and its help its tooltip.
    public bool IconOnly { get; init; }
}
