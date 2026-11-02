namespace BriefBar.Core.AzureDevOps;

/// Where tokens come from. BriefBar has the Azure CLI's (`AzureCLITokenProvider`); one with Microsoft's authentication
/// library could be added once there's an app registration to sign in with. The Mac's `AccessTokenProvider`.
public interface IAccessTokenProvider
{
    /// A token that's good for a while yet; throws `AuthException` when there's none.
    Task<AccessToken> TokenAsync(CancellationToken cancellationToken);

    /// Forgets a token that Azure DevOps rejected, so that the next one is new.
    void Invalidate();
}
