namespace BriefBar.Core.AzureDevOps;

/// Why a token couldn't be had, and what the Azure CLI said, when it said something. The Mac's `AuthError`.
public sealed record AuthError(AuthErrorKind Kind, string Message = "")
{
    public static AuthError CliNotFound { get; } = new(Kind: AuthErrorKind.CliNotFound);

    public string Description => Kind switch
    {
        AuthErrorKind.CliNotFound => "The Azure CLI (az) isn't installed.",
        AuthErrorKind.SignedOut => Message.Length == 0 ? "Not signed in to the Azure CLI." : Message,
        _ => Message,
    };

    public static AuthError SignedOut(string message) => new(Kind: AuthErrorKind.SignedOut, Message: message);

    public static AuthError Failed(string message) => new(Kind: AuthErrorKind.Failed, Message: message);
}
