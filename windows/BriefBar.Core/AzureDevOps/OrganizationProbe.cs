namespace BriefBar.Core.AzureDevOps;

/// What looking for your pull requests in organizations told: where you have an active one, and where it couldn't tell,
/// as offline, slowed down or with Azure DevOps failing. An organization you can't read, in another tenant or without
/// access, isn't one it couldn't tell: there's nothing of yours to show there. The Mac's `OrganizationDiscovery.Probe`.
public sealed record OrganizationProbe(IReadOnlyList<string> WithPullRequests, IReadOnlyDictionary<string, ADOError> Failures);
