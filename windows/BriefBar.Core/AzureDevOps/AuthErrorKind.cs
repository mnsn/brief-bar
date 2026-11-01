namespace BriefBar.Core.AzureDevOps;

/// Why a token couldn't be had.
public enum AuthErrorKind
{
    /// The Azure CLI isn't installed, or isn't where BriefBar looks.
    CliNotFound,

    /// The sign-in is missing or has expired: `az login` fixes it.
    SignedOut,

    Failed,
}
