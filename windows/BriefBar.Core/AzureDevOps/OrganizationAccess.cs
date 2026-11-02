namespace BriefBar.Core.AzureDevOps;

/// What checking an organization as you add it found: whether your sign-in can read it, and when it can't, why. The Mac's
/// `OrganizationDiscovery.Access`.
public sealed record OrganizationAccess(OrganizationAccessKind Kind, string? Tenant = null, ADOError? Error = null)
{
    public static OrganizationAccess Readable { get; } = new(Kind: OrganizationAccessKind.Readable);

    public static OrganizationAccess NotYours { get; } = new(Kind: OrganizationAccessKind.NotYours);

    /// Whether to watch it: unless it can't be read for a reason that neither signing in nor waiting fixes.
    public bool Watches => Kind is OrganizationAccessKind.Readable or OrganizationAccessKind.OtherDirectory or OrganizationAccessKind.Unchecked;

    /// The directory to sign in to, for an organization in another directory.
    public string? SignInTenant => Kind == OrganizationAccessKind.OtherDirectory ? Tenant : null;

    /// In a directory the Azure CLI isn't signed in to, `tenant`.
    public static OrganizationAccess OtherDirectory(string tenant) => new(Kind: OrganizationAccessKind.OtherDirectory, Tenant: tenant);

    /// One of your organizations that your sign-in can't read, for `error`.
    public static OrganizationAccess Unreadable(ADOError error) => new(Kind: OrganizationAccessKind.Unreadable, Error: error);

    /// Not checked for now, for `error`.
    public static OrganizationAccess Unchecked(ADOError error) => new(Kind: OrganizationAccessKind.Unchecked, Error: error);

    /// What to tell you as you add `organization`, when your sign-in can't read it: what's wrong, and what to do. Null when
    /// there's nothing to tell. Neither names a directory's ID.
    public (string Title, string Detail)? Explanation(string organization)
    {
        ArgumentNullException.ThrowIfNull(argument: organization);
        return Kind switch
        {
            OrganizationAccessKind.OtherDirectory => (
                organization + " is in a directory your Azure CLI isn't signed in to",
                "Sign in to it, and BriefBar reads " + organization + " with your other organizations. " + ProjectHint(name: organization)),
            OrganizationAccessKind.NotYours => (organization + " isn't one of your organizations", "BriefBar didn't add it. " + ProjectHint(name: organization)),
            OrganizationAccessKind.Unreadable => ("Your sign-in can't read " + organization, "BriefBar didn't add it. " + Error?.Description),
            _ => null,
        };
    }

    /// Where a project's organization is, for a project's name entered as an organization's.
    public static string ProjectHint(string name) =>
        "If " + name + " is a project, its organization is the first part of its link: dev.azure.com/organization/" + name + ".";
}
