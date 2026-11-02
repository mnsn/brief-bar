namespace BriefBar.Core.AzureDevOps;

/// Why a token couldn't be had.
public enum AuthErrorKind
{
    /// The Azure CLI isn't installed, or isn't where BriefBar looks.
    CliNotFound,

    /// The sign-in is missing or has expired: `az login` fixes it. With `AuthError.Tenant`, your sign-in's directory wants
    /// you to sign in again, while the Azure CLI is still signed in to you in another one: `az login --tenant` with it fixes
    /// it.
    SignedOut,

    Failed,
}
