namespace BriefBar.Core.AzureDevOps;

/// A token couldn't be had: `Error` says why.
public sealed class AuthException : Exception
{
    public AuthException()
        : this(error: AuthError.Failed(message: "Couldn't get a token."))
    {
    }

    public AuthException(string message)
        : this(error: AuthError.Failed(message: message))
    {
    }

    public AuthException(string message, Exception innerException)
        : base(message: message, innerException: innerException)
    {
        Error = AuthError.Failed(message: message);
    }

    public AuthException(AuthError error, Exception? innerException = null)
        : base(message: error?.Description, innerException: innerException)
    {
        ArgumentNullException.ThrowIfNull(argument: error);
        Error = error;
    }

    public AuthError Error { get; }
}
