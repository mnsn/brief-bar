using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Copilot;
using BriefBar.Core.GitHub;
using BriefBar.Core.Teams;

namespace BriefBar.Core;

/// The sources BriefBar for Windows has, in the Mac's order.
public static class SourceCatalog
{
    public static SourceEntry Teams { get; } = new(
        Id: SourceId.Teams,
        Name: SourceIds.DisplayName(source: SourceId.Teams),
        Glyph: IconKey.People,
        Tint: Sections.TeamsChats.Tint,
        Description: TeamsSource.Description,
        Sections: [Sections.TeamsChats, Sections.TeamsGroupChats]);

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

    public static IReadOnlyList<SourceEntry> OnWindows { get; } = [Teams, AzureDevOps, Copilot, GitHub];
}
