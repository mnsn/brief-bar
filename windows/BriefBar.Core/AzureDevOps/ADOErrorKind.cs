namespace BriefBar.Core.AzureDevOps;

/// What went wrong reading Azure DevOps.
public enum ADOErrorKind
{
    /// No token: `ADOError.Auth` says why.
    Auth,

    /// Azure DevOps rejected the token, even a new one.
    Unauthorized,

    /// Signed in, but without access to the organization or project.
    Forbidden,

    NotFound,

    /// Azure DevOps asked BriefBar to slow down, for `ADOError.RetryAfter`.
    Throttled,

    Offline,

    /// Another HTTP status, `ADOError.Status`.
    Http,

    /// The network failed some other way.
    Network,

    /// Azure DevOps answered with something BriefBar can't read.
    Decoding,
}
