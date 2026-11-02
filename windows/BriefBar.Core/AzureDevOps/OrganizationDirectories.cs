namespace BriefBar.Core.AzureDevOps;

/// Which directory each organization in another one than your sign-in's is in, as Azure DevOps named it when it rejected a
/// token from yours, while a token from there works: by organization name, which Azure DevOps compares ignoring case. In
/// memory only, so the first request to such an organization after BriefBar starts is rejected once. Safe to use from any
/// thread. The Mac's `OrganizationDirectories`.
internal sealed class OrganizationDirectories
{
    readonly Lock gate = new();
    readonly Dictionary<string, string> tenants = new(comparer: StringComparer.OrdinalIgnoreCase);

    public string? TenantOf(string organization)
    {
        lock (gate)
        {
            return tenants.GetValueOrDefault(key: organization);
        }
    }

    public void Remember(string tenant, string organization)
    {
        lock (gate)
        {
            tenants[organization] = tenant;
        }
    }

    public void Forget(string organization)
    {
        lock (gate)
        {
            tenants.Remove(key: organization);
        }
    }
}
