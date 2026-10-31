namespace BriefBar.Core.Presentation;

/// One part of the Overview's words in the bar: "8 need you", its number in its state's color.
public sealed record SummaryPart(ItemState State, int Count, string Words);
