namespace BriefBar.Core.Presentation;

/// What a press on an item in the bar does to the panel.
public enum PanelToggleAction
{
    /// Opens the item's panel, in place of any other.
    Open,

    /// Closes the item's panel, which is open.
    Close,

    /// Does nothing: the press was a repeat, or its panel closed a moment ago because of it.
    Ignore,
}
