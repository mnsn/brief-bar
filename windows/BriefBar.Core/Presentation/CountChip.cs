namespace BriefBar.Core.Presentation;

/// One count on an item in the bar: its state's icon, in the state's color, and the number, as on the Mac.
public sealed record CountChip(ItemState State, int Count, IconKey Icon);
