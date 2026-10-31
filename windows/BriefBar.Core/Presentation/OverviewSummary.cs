using System.Globalization;

namespace BriefBar.Core.Presentation;

/// What the Overview's item, on the left of the bar, says: what needs you, what went wrong and what's done or ready, in
/// words, across every section (`Parts`); or, with nothing to say, `EmptyText`. What's running isn't in its words, as
/// it isn't in the Mac's counts added up, but it's in its tooltip.
public sealed record OverviewSummary(
    IReadOnlyList<SummaryPart> Parts,
    string EmptyText,
    string ToolTip,
    string AutomationName)
{
    static readonly ItemState[] inWords = [ItemState.NeedsYou, ItemState.Failing, ItemState.Done];

    public static OverviewSummary Of(IReadOnlyList<SectionSnapshot> snapshots)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        var counts = snapshots.Aggregate(seed: new StateCounts(), func: (sum, snapshot) => sum + snapshot.Counts);
        var parts = inWords
            .Where(predicate: state => counts[state] > 0)
            .Select(selector: state => new SummaryPart(State: state, Count: counts[state], Words: StateWords.AfterCount(state: state)))
            .ToList();
        var emptyText = snapshots.Count == 0 ? "No source is on" : "Nothing needs you";
        var counted = StateCounts.AllStates.Where(predicate: state => counts[state] > 0).ToList();
        var toolTip = counted.Count > 0
            ? "Overview\n" + string.Join(separator: " · ", values: counted.Select(selector: state => string.Create(
                provider: CultureInfo.InvariantCulture, handler: $"{StateWords.Title(state: state)}: {counts[state]}")))
            : "Overview\n" + emptyText;
        var automationName = counted.Count > 0
            ? "Overview: " + string.Join(separator: ", ", values: counted.Select(selector: state => string.Create(
                provider: CultureInfo.InvariantCulture, handler: $"{counts[state]} {StateWords.AfterCount(state: state)}"))) + "."
            : "Overview: " + emptyText + ".";
        return new OverviewSummary(Parts: parts, EmptyText: emptyText, ToolTip: toolTip, AutomationName: automationName);
    }
}
