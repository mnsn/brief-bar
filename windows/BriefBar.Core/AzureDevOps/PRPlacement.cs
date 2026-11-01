namespace BriefBar.Core.AzureDevOps;

/// Where the classifier puts a pull request: its group, the reason, the headline and detail, and since when, or since its
/// latest activity when null.
internal readonly record struct PRPlacement(PRGroup Group, PRReason Reason, string Headline, string? Detail = null, DateTimeOffset? Since = null);
