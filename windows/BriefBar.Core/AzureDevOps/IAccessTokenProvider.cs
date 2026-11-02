namespace BriefBar.Core.AzureDevOps;

/// Where tokens come from. BriefBar has the Azure CLI's (`AzureCLITokenProvider`); one with Microsoft's authentication
/// library could be added once there's an app registration to sign in with. The Mac's `AccessTokenProvider`.
public interface IAccessTokenProvider
{
    /// A token that's good for a while yet, for your sign-in's directory; or, with `tenant`, for that directory (a
    /// Microsoft Entra tenant's ID, `TenantId`), which an organization in another directory needs. Throws `AuthException`
    /// when there's none.
    Task<AccessToken> TokenAsync(string? tenant, CancellationToken cancellationToken);

    /// Forgets a token that Azure DevOps rejected, for your sign-in's directory, or `tenant`'s, so that the next one for it
    /// is new.
    void Invalidate(string? tenant);
}
