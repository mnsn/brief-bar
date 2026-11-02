namespace BriefBar.Core.AzureDevOps;

/// Your organizations (`All`), and the ones to watch: those where you have an active pull request, as its author or a
/// reviewer. The Mac's `OrganizationDiscovery.Found`.
public sealed record OrganizationsFound(IReadOnlyList<string> All, IReadOnlyList<string> WithPullRequests);
