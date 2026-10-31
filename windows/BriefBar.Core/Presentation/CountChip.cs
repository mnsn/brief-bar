namespace BriefBar.Core.Presentation;

/// One count on an item in the bar: its state's icon and number. Needs you is emphasized, as a filled pill, so that it's
/// the one count that stands out.
public sealed record CountChip(ItemState State, int Count, IconKey Icon)
{
    public bool IsEmphasized => State == ItemState.NeedsYou;
}
