namespace BriefBar.Core.AzureDevOps;

/// A failed build of one of your pull requests, whose timeline says where it failed. A build that's retried keeps its ID
/// and fails again later, so when it completed is part of it.
internal readonly record struct FailedBuild(string Organization, string ProjectId, int BuildId, DateTimeOffset? CompletedAt);
