namespace BriefBar.Core.AzureDevOps;

/// A pull request's reviewer: a person, or a team or group, with their vote.
public sealed record Reviewer(Person Person, Vote Vote, bool IsRequired = false, bool IsGroup = false, bool HasDeclined = false);
