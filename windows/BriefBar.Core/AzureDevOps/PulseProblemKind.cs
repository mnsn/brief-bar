namespace BriefBar.Core.AzureDevOps;

/// Why the list may be missing or out of date.
public enum PulseProblemKind
{
    NoOrganizations,
    CliNotFound,
    SignedOut,
    AuthFailed,
    Offline,
    Throttled,

    /// Nothing could be read: the list shown is the last one that could.
    Unreachable,

    /// Some organizations couldn't be read.
    SomeOrganizations,
}
