namespace BriefBar.Core.AzureDevOps;

/// Why a token couldn't be had, and what the Azure CLI said, when it said something, without IDs, email addresses or the
/// names of directories it quotes. With `Tenant`, your sign-in's directory wants you to sign in again there
/// (`AuthErrorKind.SignedOut`). The Mac's `AuthError`.
public sealed record AuthError(AuthErrorKind Kind, string Message = "", string? Tenant = null)
{
    public static AuthError CliNotFound { get; } = new(Kind: AuthErrorKind.CliNotFound);

    public string Description => Kind switch
    {
        AuthErrorKind.CliNotFound => "The Azure CLI (az) isn't installed.",
        AuthErrorKind.SignedOut => Message.Length == 0 ? "Not signed in to the Azure CLI." : Message,
        _ => Message,
    };

    /// `az login` fixes it; with `tenant`, `az login --tenant` there, as your sign-in's directory wants you to sign in
    /// again there while the Azure CLI is still signed in to you in another one.
    public static AuthError SignedOut(string message, string? tenant = null) => new(Kind: AuthErrorKind.SignedOut, Message: message, Tenant: tenant);

    public static AuthError Failed(string message) => new(Kind: AuthErrorKind.Failed, Message: message);
}
