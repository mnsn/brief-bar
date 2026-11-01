using System.Globalization;

namespace BriefBar.Core.AzureDevOps;

/// What went wrong reading Azure DevOps, with what goes with it: the sign-in's error, how long to wait, the HTTP status,
/// or a message. The Mac's `ADOError`.
public sealed record ADOError(ADOErrorKind Kind, AuthError? Auth = null, TimeSpan? RetryAfter = null, int? Status = null, string? Message = null)
{
    public static ADOError Unauthorized { get; } = new(Kind: ADOErrorKind.Unauthorized);

    public static ADOError Forbidden { get; } = new(Kind: ADOErrorKind.Forbidden);

    public static ADOError NotFound { get; } = new(Kind: ADOErrorKind.NotFound);

    public static ADOError Offline { get; } = new(Kind: ADOErrorKind.Offline);

    /// In a sentence.
    public string Description => Kind switch
    {
        ADOErrorKind.Auth => Auth?.Description ?? "Couldn't sign in.",
        ADOErrorKind.Unauthorized => "Azure DevOps didn't accept the sign-in.",
        ADOErrorKind.Forbidden => "No access to this organization.",
        ADOErrorKind.NotFound => "Not found.",
        ADOErrorKind.Throttled => "Azure DevOps asked BriefBar to slow down.",
        ADOErrorKind.Offline => "You're offline.",
        ADOErrorKind.Http => string.Create(provider: CultureInfo.InvariantCulture, handler: $"Azure DevOps answered with HTTP {Status}."),
        ADOErrorKind.Network => Message ?? "Couldn't reach Azure DevOps.",
        ADOErrorKind.Decoding => "Unexpected response from Azure DevOps (" + Message + ").",
        _ => throw new InvalidOperationException(message: "An error of an unknown kind."),
    };

    public static ADOError FromAuth(AuthError error) => new(Kind: ADOErrorKind.Auth, Auth: error);

    public static ADOError Throttled(TimeSpan retryAfter) => new(Kind: ADOErrorKind.Throttled, RetryAfter: retryAfter);

    public static ADOError Http(int status) => new(Kind: ADOErrorKind.Http, Status: status);

    public static ADOError Network(string message) => new(Kind: ADOErrorKind.Network, Message: message);

    public static ADOError Decoding(string message) => new(Kind: ADOErrorKind.Decoding, Message: message);
}
