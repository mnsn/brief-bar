namespace BriefBar.Core.AzureDevOps;

/// A pull request the lists have, with its fingerprint now. The Mac's `RefreshPlanner.Candidate`.
public sealed record RefreshPlannerCandidate(PRKey Key, string Fingerprint);
