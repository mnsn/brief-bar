using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Copilot;
using BriefBar.Core.GitHub;

namespace BriefBar.Core;

/// The sources BriefBar for Windows has so far, in the Mac's order: they arrive one at a time.
public static class SourceCatalog
{
    public static SourceEntry AzureDevOps { get; } = new(
        Id: SourceId.AzureDevOps,
        Name: SourceIds.DisplayName(source: SourceId.AzureDevOps),
        Glyph: IconKey.BranchRequest,
        Tint: Sections.AzureDevOpsPullRequests.Tint,
        Description: AzureDevOpsSource.Description,
        Sections: [Sections.AzureDevOpsPullRequests]);

    public static SourceEntry Copilot { get; } = new(
        Id: SourceId.Copilot,
        Name: SourceIds.DisplayName(source: SourceId.Copilot),
        Glyph: IconKey.Pulse,
        Tint: Sections.CopilotSessions.Tint,
        Description: CopilotSource.Description,
        Sections: [Sections.CopilotSessions]);

    public static SourceEntry GitHub { get; } = new(
        Id: SourceId.GitHub,
        Name: SourceIds.DisplayName(source: SourceId.GitHub),
        Glyph: IconKey.BranchFork,
        Tint: Sections.GitHubPullRequests.Tint,
        Description: GitHubSource.Description,
        Sections: [Sections.GitHubPullRequests]);

    public static IReadOnlyList<SourceEntry> OnWindows { get; } = [AzureDevOps, Copilot, GitHub];

    /// The sources the Mac has that Windows doesn't yet, by name: "Azure DevOps, GitHub, and Microsoft Teams".
    public static string StillToCome => ListWords.Join(names: StillToComeNames());

    /// What Settings says about them, or nothing once Windows has them all.
    public static string? StillToComeNote => NoteOnStillToCome(names: StillToComeNames());

    /// "Microsoft Teams comes to BriefBar for Windows next." for one source, "Azure DevOps and Microsoft Teams come to
    /// BriefBar for Windows one at a time." for more, and nothing for none.
    public static string? NoteOnStillToCome(IReadOnlyList<string> names)
    {
        ArgumentNullException.ThrowIfNull(argument: names);
        return names.Count switch
        {
            0 => null,
            1 => names[0] + " comes to BriefBar for Windows next.",
            _ => ListWords.Join(names: names) + " come to BriefBar for Windows one at a time.",
        };
    }

    static List<string> StillToComeNames() => Enum.GetValues<SourceId>()
        .Where(predicate: source => !OnWindows.Any(predicate: entry => entry.Id == source))
        .Select(selector: source => SourceIds.DisplayName(source: source))
        .Order(comparer: StringComparer.Ordinal)
        .ToList();
}
