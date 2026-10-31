using BriefBar.Core.Logging;

namespace BriefBar.Core;

/// One list that a source shows, such as Teams' group chats. Each item in the bar shows one. Its raw value is the Mac's
/// (`copilot.sessions`), so the two apps name sections alike.
public readonly record struct SectionId(string RawValue) : ILoggable
{
    public static SectionId TeamsChats { get; } = new(RawValue: "teams.chats");
    public static SectionId TeamsGroupChats { get; } = new(RawValue: "teams.groupChats");
    public static SectionId AzureDevOpsPullRequests { get; } = new(RawValue: "azureDevOps.pullRequests");
    public static SectionId AzureDevOpsSprint { get; } = new(RawValue: "azureDevOps.sprint");
    public static SectionId AzureDevOpsPipelines { get; } = new(RawValue: "azureDevOps.pipelines");
    public static SectionId CopilotSessions { get; } = new(RawValue: "copilot.sessions");
    public static SectionId GitHubPullRequests { get; } = new(RawValue: "github.pullRequests");

    /// The source it belongs to, or null for one this version doesn't know.
    public SourceId? Source
    {
        get
        {
            var name = (RawValue ?? string.Empty).Split(separator: '.', count: 2)[0];
            return SourceIds.TryParse(rawValue: name, source: out var source) ? source : null;
        }
    }

    public override string ToString() => RawValue ?? string.Empty;
}
