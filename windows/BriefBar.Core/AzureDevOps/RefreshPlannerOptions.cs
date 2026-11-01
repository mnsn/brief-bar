namespace BriefBar.Core.AzureDevOps;

/// How often a pull request's details are read again: every `BusyInterval` while a build or check runs,
/// `ActiveInterval` otherwise, and `QuietInterval` for drafts and pull requests without recent activity; at most `Budget`
/// known pull requests a refresh, besides new ones. The Mac's `RefreshPlanner.Options`.
public sealed record RefreshPlannerOptions
{
    public TimeSpan BusyInterval { get; init; } = TimeSpan.FromSeconds(value: 60);

    public TimeSpan ActiveInterval { get; init; } = TimeSpan.FromSeconds(value: 180);

    public TimeSpan QuietInterval { get; init; } = TimeSpan.FromSeconds(value: 900);

    public int Budget { get; init; } = 8;
}
