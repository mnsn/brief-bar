namespace BriefBar.Core.AzureDevOps;

/// An organization's lists, as one refresh read them: your identity there (`Me`) and your name, the first time; your active
/// pull requests, those you review, and yours completed lately.
internal sealed record PulseOrganizationLists(
    string Me, string? Name, IReadOnlyList<PullRequest> Mine, IReadOnlyList<PullRequest> Reviewing, IReadOnlyList<PullRequest> Completed);
