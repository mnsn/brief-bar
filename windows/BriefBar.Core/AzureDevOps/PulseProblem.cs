using System.Globalization;

namespace BriefBar.Core.AzureDevOps;

/// Why the list may be missing or out of date, with what the Azure CLI or Azure DevOps said (`Detail`), or until when
/// Azure DevOps asked BriefBar to wait (`Until`). The Mac's `PulseProblem`.
public sealed record PulseProblem(PulseProblemKind Kind, string? Detail = null, DateTimeOffset? Until = null)
{
    public static PulseProblem NoOrganizations { get; } = new(Kind: PulseProblemKind.NoOrganizations);

    public static PulseProblem CliNotFound { get; } = new(Kind: PulseProblemKind.CliNotFound);

    public static PulseProblem Offline { get; } = new(Kind: PulseProblemKind.Offline);

    /// What the section says, in a sentence.
    public string Message => Kind switch
    {
        PulseProblemKind.NoOrganizations => "No Azure DevOps organizations to watch yet.",
        PulseProblemKind.CliNotFound => "BriefBar signs in with the Azure CLI, which isn't installed.",
        PulseProblemKind.SignedOut => "Sign in to the Azure CLI to see your pull requests.",
        PulseProblemKind.AuthFailed => "Couldn't get a token from the Azure CLI: " + Detail,
        PulseProblemKind.Offline => "You're offline. The list may be out of date.",
        PulseProblemKind.Throttled => "Azure DevOps asked BriefBar to slow down, until "
            + (Until ?? DateTimeOffset.Now).ToLocalTime().ToString(format: "t", formatProvider: CultureInfo.CurrentCulture) + ".",
        PulseProblemKind.Unreachable => Detail + " The list may be out of date.",
        PulseProblemKind.SomeOrganizations => Detail ?? "Some organizations couldn't be read.",
        _ => throw new InvalidOperationException(message: "A problem of an unknown kind."),
    };

    /// Fixed by signing in, or by installing the Azure CLI first.
    public bool NeedsSignIn => Kind is PulseProblemKind.CliNotFound or PulseProblemKind.SignedOut;

    /// The problem `error` makes, at `now`, reading `organization`, which it names when it's one of several.
    public static PulseProblem From(ADOError error, DateTimeOffset now, string? organization = null)
    {
        ArgumentNullException.ThrowIfNull(argument: error);
        return error.Kind switch
        {
            ADOErrorKind.Auth when error.Auth?.Kind == AuthErrorKind.CliNotFound => CliNotFound,
            ADOErrorKind.Auth when error.Auth?.Kind == AuthErrorKind.SignedOut => new PulseProblem(Kind: PulseProblemKind.SignedOut, Detail: error.Auth.Message),
            ADOErrorKind.Auth => new PulseProblem(Kind: PulseProblemKind.AuthFailed, Detail: error.Auth?.Message),
            ADOErrorKind.Offline => Offline,
            ADOErrorKind.Throttled => new PulseProblem(Kind: PulseProblemKind.Throttled, Until: now + (error.RetryAfter ?? TimeSpan.Zero)),
            ADOErrorKind.Unauthorized => new PulseProblem(Kind: PulseProblemKind.SignedOut, Detail: error.Description),
            _ => new PulseProblem(Kind: PulseProblemKind.Unreachable, Detail: (organization is null ? string.Empty : "Can't read " + organization + ": ") + error.Description),
        };
    }
}
