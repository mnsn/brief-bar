using BriefBar.Core.Copilot;

namespace BriefBar.Core;

/// The sources BriefBar for Windows has so far, in the Mac's order: they arrive one at a time.
public static class SourceCatalog
{
    public static SourceEntry Copilot { get; } = new(
        Id: SourceId.Copilot,
        Name: SourceIds.DisplayName(source: SourceId.Copilot),
        Glyph: IconKey.Pulse,
        Tint: Sections.CopilotSessions.Tint,
        Description: CopilotSource.Description,
        Sections: [Sections.CopilotSessions]);

    public static IReadOnlyList<SourceEntry> OnWindows { get; } = [Copilot];

    /// The sources the Mac has that Windows doesn't yet, by name: "Azure DevOps, GitHub, and Microsoft Teams".
    public static string StillToCome => ListWords.Join(names: Enum.GetValues<SourceId>()
        .Where(predicate: source => !OnWindows.Any(predicate: entry => entry.Id == source))
        .Select(selector: source => SourceIds.DisplayName(source: source))
        .Order(comparer: StringComparer.Ordinal)
        .ToList());
}
