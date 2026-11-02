namespace BriefBar.Core.AzureDevOps;

/// A pull request in your lists, and whether you wrote it or review it.
internal sealed record PulseListed(PullRequest PullRequest, PRRole Role);
