namespace BriefBar.Core.AzureDevOps;

/// You, as an organization's `connectionData` says: your identity's ID, and your name.
public sealed record ADOAuthenticatedUser(string Id, string? ProviderDisplayName);
