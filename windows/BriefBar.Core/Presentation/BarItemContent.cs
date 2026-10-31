using System.Globalization;

namespace BriefBar.Core.Presentation;

/// What a section's item in the bar shows: its glyph and name, its counts in its section's order, and a badge when it
/// doesn't show the whole story; with the same in words for its tooltip and for Narrator.
public sealed record BarItemContent(
    SectionId Section,
    string Label,
    IconKey Glyph,
    uint Tint,
    bool IsQuiet,
    IReadOnlyList<CountChip> Chips,
    BarItemBadge Badge,
    string? BadgeText,
    string ToolTip,
    string AutomationName)
{
    public static BarItemContent Of(SectionSnapshot snapshot, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshot);
        var info = snapshot.Info;
        var badge = BadgeOf(condition: snapshot.Status.Condition);
        // Until it reads what's there, or while it can't, its counts would be wrong: it shows none.
        var showsCounts = badge is BarItemBadge.None or BarItemBadge.Stale;
        var chips = showsCounts ? ChipsOf(info: info, counts: snapshot.Counts) : [];
        var status = StatusWords.Of(status: snapshot.Status, now: now);
        return new BarItemContent(
            Section: info.Id,
            Label: info.BarLabel,
            Glyph: info.Glyph,
            Tint: info.Tint,
            IsQuiet: chips.Count == 0 && badge == BarItemBadge.None,
            Chips: chips,
            Badge: badge,
            BadgeText: BadgeTextOf(badge: badge, status: snapshot.Status),
            ToolTip: ToolTipOf(info: info, chips: chips, showsCounts: showsCounts, status: status),
            AutomationName: AutomationNameOf(info: info, chips: chips, showsCounts: showsCounts, status: status));
    }

    static List<CountChip> ChipsOf(SectionInfo info, StateCounts counts) => info.States
        .Where(predicate: state => counts[state] > 0)
        .Select(selector: state => new CountChip(
            State: state, Count: counts[state], Icon: StateWords.Icon(state: state, section: info.Id)))
        .ToList();

    static BarItemBadge BadgeOf(SectionCondition condition) => condition switch
    {
        SectionCondition.Starting => BarItemBadge.Starting,
        SectionCondition.Ready => BarItemBadge.None,
        SectionCondition.Stale => BarItemBadge.Stale,
        SectionCondition.Problem => BarItemBadge.Problem,
        SectionCondition.Paused => BarItemBadge.Paused,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(condition), actualValue: condition, message: "Not a condition."),
    };

    static string? BadgeTextOf(BarItemBadge badge, SectionStatus status) => badge switch
    {
        BarItemBadge.Problem => status.ShortProblem ?? "Can't read",
        BarItemBadge.Paused => "Review",
        _ => null,
    };

    /// "GitHub Copilot sessions", then "Needs you: 2 · Running: 1", then how it stands, each on a line.
    static string ToolTipOf(SectionInfo info, List<CountChip> chips, bool showsCounts, string status)
    {
        var lines = new List<string> { info.FullName };
        if (showsCounts)
        {
            lines.Add(item: chips.Count > 0
                ? string.Join(separator: " · ", values: chips.Select(selector: chip => string.Create(
                    provider: CultureInfo.InvariantCulture, handler: $"{StateWords.Title(state: chip.State)}: {chip.Count}")))
                : "Nothing new");
        }
        if (status.Length > 0)
        {
            lines.Add(item: status);
        }
        return string.Join(separator: '\n', values: lines);
    }

    /// "GitHub Copilot sessions: 2 need you, 1 running. Live"
    static string AutomationNameOf(SectionInfo info, List<CountChip> chips, bool showsCounts, string status)
    {
        var counts = chips.Count > 0
            ? string.Join(separator: ", ", values: chips.Select(selector: chip => string.Create(
                provider: CultureInfo.InvariantCulture, handler: $"{chip.Count} {StateWords.AfterCount(state: chip.State)}")))
            : "nothing new";
        var name = showsCounts ? info.FullName + ": " + counts + "." : info.FullName + ".";
        return status.Length > 0 ? name + " " + status : name;
    }
}
