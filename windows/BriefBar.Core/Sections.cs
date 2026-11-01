namespace BriefBar.Core;

/// The sections BriefBar knows, as the Mac defines them, with Windows' words.
public static class Sections
{
    public static SectionInfo TeamsChats { get; } = new(
        Id: SectionId.TeamsChats,
        Title: "Chats",
        BarLabel: "Chats",
        FullName: "Teams chats",
        Glyph: IconKey.Person,
        Tint: 0xFF5B5FC7,
        Counted: new CountNoun(One: "chat", Many: "chats"),
        States: [ItemState.NeedsYou]);

    public static SectionInfo TeamsGroupChats { get; } = new(
        Id: SectionId.TeamsGroupChats,
        Title: "Group chats",
        BarLabel: "Group chats",
        FullName: "Teams group chats",
        Glyph: IconKey.People,
        Tint: 0xFF038387,
        Counted: new CountNoun(One: "group chat", Many: "group chats"),
        States: [ItemState.NeedsYou]);

    public static SectionInfo AzureDevOpsPullRequests { get; } = new(
        Id: SectionId.AzureDevOpsPullRequests,
        Title: "Pull requests",
        BarLabel: "Azure DevOps",
        FullName: "Azure DevOps pull requests",
        Glyph: IconKey.BranchRequest,
        Tint: 0xFF0078D4,
        Counted: new CountNoun(One: "pull request", Many: "pull requests"),
        States: [ItemState.NeedsYou, ItemState.Failing, ItemState.Done]);

    public static SectionInfo CopilotSessions { get; } = new(
        Id: SectionId.CopilotSessions,
        Title: "Sessions",
        BarLabel: "Copilot",
        FullName: "GitHub Copilot sessions",
        Glyph: IconKey.Pulse,
        Tint: 0xFFDB4D8F,
        Counted: new CountNoun(One: "Copilot session", Many: "Copilot sessions"),
        States: [ItemState.NeedsYou, ItemState.Running, ItemState.Done, ItemState.Failing]);

    public static SectionInfo GitHubPullRequests { get; } = new(
        Id: SectionId.GitHubPullRequests,
        Title: "Pull requests",
        BarLabel: "GitHub",
        FullName: "GitHub pull requests",
        Glyph: IconKey.BranchFork,
        Tint: 0xFF8250DF,
        Counted: new CountNoun(One: "GitHub pull request", Many: "GitHub pull requests"),
        States: [ItemState.NeedsYou, ItemState.Failing, ItemState.Done]);

    /// Every section, in the order the bar shows them, left to right.
    public static IReadOnlyList<SectionInfo> InBarOrder { get; } =
        [TeamsChats, TeamsGroupChats, AzureDevOpsPullRequests, CopilotSessions, GitHubPullRequests];
}
