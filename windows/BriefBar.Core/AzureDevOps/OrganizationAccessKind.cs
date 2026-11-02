namespace BriefBar.Core.AzureDevOps;

/// What checking an organization as you add it found.
public enum OrganizationAccessKind
{
    /// Your sign-in reads it.
    Readable,

    /// It's in a directory, a Microsoft Entra tenant (`OrganizationAccess.Tenant`), that the Azure CLI isn't signed in to:
    /// signing in there reads it.
    OtherDirectory,

    /// Your sign-in can't read it, and it isn't one of your organizations: perhaps it's a project's name.
    NotYours,

    /// One of your organizations, which your sign-in can't read, and why (`OrganizationAccess.Error`).
    Unreadable,

    /// It couldn't be checked for now, such as while you're offline or signed out, and why (`OrganizationAccess.Error`):
    /// once it's watched, its list says what's wrong.
    Unchecked,
}
