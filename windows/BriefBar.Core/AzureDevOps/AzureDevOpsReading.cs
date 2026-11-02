namespace BriefBar.Core.AzureDevOps;

/// How `AzureDevOpsSource` reads Azure DevOps: the engine it runs, made with the handler for what it reads; how it finds
/// your organizations, and checks one you add; where the account it reads as is from, to keep for after a restart; and
/// where the Azure CLI is, to sign in with. Live, they share one client, which this owns; the demo makes them up, and reads
/// nothing.
public sealed class AzureDevOpsReading : IDisposable
{
    readonly Func<Action<PulseSnapshot>, IPulseEngine> makeEngine;
    readonly Func<CancellationToken, Task<OrganizationsFound>> findOrganizations;
    readonly Func<string, CancellationToken, Task<OrganizationAccess>> checkAccess;
    readonly Func<string, string?> accountOrigin;
    readonly Func<string?> locateCli;
    readonly IDisposable? owned;

    /// - `checkAccess`: whether your sign-in can read an organization you add (`OrganizationDiscovery.AccessAsync`).
    /// - `accountOrigin`: where an account is from, while the sign-in's tokens are its (`AzureCLITokenProvider.AccountTenantOf`).
    public AzureDevOpsReading(
        Func<Action<PulseSnapshot>, IPulseEngine> makeEngine,
        Func<CancellationToken, Task<OrganizationsFound>> findOrganizations,
        Func<string, CancellationToken, Task<OrganizationAccess>> checkAccess,
        Func<string, string?> accountOrigin,
        Func<string?> locateCli,
        IDisposable? owned = null)
    {
        ArgumentNullException.ThrowIfNull(argument: makeEngine);
        ArgumentNullException.ThrowIfNull(argument: findOrganizations);
        ArgumentNullException.ThrowIfNull(argument: checkAccess);
        ArgumentNullException.ThrowIfNull(argument: accountOrigin);
        ArgumentNullException.ThrowIfNull(argument: locateCli);
        this.makeEngine = makeEngine;
        this.findOrganizations = findOrganizations;
        this.checkAccess = checkAccess;
        this.accountOrigin = accountOrigin;
        this.locateCli = locateCli;
        this.owned = owned;
    }

    /// Azure DevOps itself, with the Azure CLI's sign-in that `tokens` gets.
    public static AzureDevOpsReading Live(AzureCLITokenProvider tokens, AzureCLILocator locator)
    {
        ArgumentNullException.ThrowIfNull(argument: tokens);
        ArgumentNullException.ThrowIfNull(argument: locator);
        var client = new ADOClient(tokens: tokens);
        return new AzureDevOpsReading(
            makeEngine: onChange => new PulseEngine(client: client, configuration: new PulseEngineConfiguration(), onChange: onChange),
            findOrganizations: cancellationToken => OrganizationDiscovery.DiscoverAsync(client: client, cancellationToken: cancellationToken),
            checkAccess: (organization, cancellationToken) => OrganizationDiscovery.AccessAsync(organization: organization, client: client, cancellationToken: cancellationToken),
            accountOrigin: tokens.AccountTenantOf,
            locateCli: () => tokens.Program ?? locator.Locate(),
            owned: client);
    }

    public IPulseEngine MakeEngine(Action<PulseSnapshot> onChange) => makeEngine(arg: onChange);

    /// Your organizations, and those with your pull requests; throws `ADOException` when it couldn't tell.
    public Task<OrganizationsFound> FindOrganizationsAsync(CancellationToken cancellationToken) => findOrganizations(arg: cancellationToken);

    /// Whether your sign-in can read `organization`, as you add it, and if not, why.
    public Task<OrganizationAccess> CheckAccessAsync(string organization, CancellationToken cancellationToken) => checkAccess(arg1: organization, arg2: cancellationToken);

    /// Where `account` (`AccessToken.Account`) is from, while the sign-in's tokens are its; null for any other.
    public string? AccountOrigin(string account) => accountOrigin(arg: account);

    /// The Azure CLI's program, or null when it isn't installed.
    public string? LocateCli() => locateCli();

    public void Dispose() => owned?.Dispose();
}
