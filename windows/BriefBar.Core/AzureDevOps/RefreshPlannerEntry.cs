namespace BriefBar.Core.AzureDevOps;

/// When a pull request's details were last read, for its fingerprint then, and whether a check ran (`IsBusy`) or it was
/// quiet: a draft, or without recent activity. The Mac's `RefreshPlanner.Entry`.
public sealed record RefreshPlannerEntry(DateTimeOffset FetchedAt, string Fingerprint, bool IsBusy = false, bool IsQuiet = false);
