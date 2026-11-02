namespace BriefBar.Core.AzureDevOps;

/// Why the list may be missing or out of date.
public enum PulseProblemKind
{
    NoOrganizations,
    CliNotFound,

    /// With `PulseProblem.Tenant`, your sign-in's directory, which wants you to sign in again there.
    SignedOut,

    AuthFailed,
    Offline,
    Throttled,

    /// Nothing could be read: the list shown is the last one that could.
    Unreachable,

    /// Some organizations couldn't be read.
    SomeOrganizations,

    /// Organizations (`PulseProblem.Organizations`) in a directory, a Microsoft Entra tenant (`PulseProblem.Tenant`), that
    /// the Azure CLI isn't signed in to: signing in there, with `az login --tenant`, lets BriefBar read them. The other
    /// organizations' pull requests are still listed; `PulseProblem.Detail` says which others couldn't be read, and why.
    OtherDirectory,
}
