using BriefBar.Core.Logging;

namespace BriefBar.Core.Presentation;

/// What a panel lists: a section's own groups, or, for the Overview, every section's things by state.
public static class PanelLists
{
    /// A section's groups, in its order, each with its rows in the section's order. Empty groups aren't shown.
    public static IReadOnlyList<PanelGroup> ForSection(SectionSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshot);
        var groups = snapshot.Groups
            .Select(selector: group => new PanelGroup(
                Key: group.Key,
                Title: group.Title,
                State: group.State,
                Rows: snapshot.Rows.Where(predicate: row => row.Group == group.Key).ToList()))
            .Where(predicate: group => group.Rows.Count > 0)
            .ToList();
        var listed = groups.Sum(selector: group => group.Rows.Count);
        if (listed != snapshot.Rows.Count)
        {
            // A source's mistake: a row in a group it didn't name can't be shown under a title.
            Log.Write(line: $"{snapshot.Info.Id}: {snapshot.Rows.Count - listed} rows in no group aren't shown");
        }
        return groups;
    }

    /// Every section's things that are in a state: what needs you, what's wrong, what's running, then what's done or
    /// ready, each the newest first.
    public static IReadOnlyList<PanelGroup> ForOverview(IEnumerable<SectionSnapshot> snapshots)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        var rows = snapshots.SelectMany(selector: snapshot => snapshot.Rows).Where(predicate: row => row.State is not null).ToList();
        return StateCounts.AllStates
            .Select(selector: state => new PanelGroup(
                Key: state.ToString(),
                Title: StateWords.Title(state: state),
                State: state,
                Rows: rows.Where(predicate: row => row.State == state)
                    .OrderBy(keySelector: row => row.Date is null ? 1 : 0)
                    .ThenByDescending(keySelector: row => row.Date)
                    .ToList()))
            .Where(predicate: group => group.Rows.Count > 0)
            .ToList();
    }

    /// The brief a panel starts with: picked across every section given, so a section's own for its panel.
    public static IReadOnlyList<BriefLine> Brief(IEnumerable<SectionSnapshot> snapshots)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        return Briefing.Pick(lines: snapshots.SelectMany(selector: snapshot => snapshot.BriefLines).ToList());
    }
}
