namespace BriefBar.Core.AzureDevOps;

/// How `AzureDevOpsSource` reads Azure DevOps: the engine it runs, made with the handler for what it reads; how it finds
/// your organizations; and where the Azure CLI is, to sign in with. Live, they share one client, which this owns; the demo
/// makes them up.
public sealed class AzureDevOpsReading : IDisposable
{
    readonly Func<Action<PulseSnapshot>, IPulseEngine> makeEngine;
    readonly Func<CancellationToken, Task<OrganizationsFound>> findOrganizations;
    readonly Func<string?> locateCli;
    readonly IDisposable? owned;

    public AzureDevOpsReading(
        Func<Action<PulseSnapshot>, IPulseEngine> makeEngine,
        Func<CancellationToken, Task<OrganizationsFound>> findOrganizations,
        Func<string?> locateCli,
        IDisposable? owned = null)
    {
        ArgumentNullException.ThrowIfNull(argument: makeEngine);
        ArgumentNullException.ThrowIfNull(argument: findOrganizations);
        ArgumentNullException.ThrowIfNull(argument: locateCli);
        this.makeEngine = makeEngine;
        this.findOrganizations = findOrganizations;
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
            locateCli: () => tokens.Program ?? locator.Locate(),
            owned: client);
    }

    public IPulseEngine MakeEngine(Action<PulseSnapshot> onChange) => makeEngine(arg: onChange);

    /// Your organizations, and those with your pull requests; throws `ADOException` when it couldn't tell.
    public Task<OrganizationsFound> FindOrganizationsAsync(CancellationToken cancellationToken) => findOrganizations(arg: cancellationToken);

    /// The Azure CLI's program, or null when it isn't installed.
    public string? LocateCli() => locateCli();

    public void Dispose() => owned?.Dispose();
}
