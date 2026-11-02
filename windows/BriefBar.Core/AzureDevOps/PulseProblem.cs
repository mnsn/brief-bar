using System.Globalization;

namespace BriefBar.Core.AzureDevOps;

/// Why the list may be missing or out of date, with what the Azure CLI or Azure DevOps said (`Detail`), until when Azure
/// DevOps asked BriefBar to wait (`Until`), or, for organizations in a directory the Azure CLI isn't signed in to, which
/// (`Organizations`) and that directory's ID (`Tenant`), which only signing in gets. The Mac's `PulseProblem`.
public sealed record PulseProblem(
    PulseProblemKind Kind, string? Detail = null, DateTimeOffset? Until = null, ValueList<string>? Organizations = null, string? Tenant = null)
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
        // Its directory isn't named: its ID says nothing to you, and Sign in knows it.
        PulseProblemKind.OtherDirectory => InAnotherDirectory(organizations: Organizations ?? []) + (Detail is { } others ? " " + others : string.Empty),
        _ => throw new InvalidOperationException(message: "A problem of an unknown kind."),
    };

    /// Fixed by signing in, or by installing the Azure CLI first: until then, nothing can be read.
    public bool NeedsSignIn => Kind is PulseProblemKind.CliNotFound or PulseProblemKind.SignedOut;

    /// The directory to sign in to, when signing in to one fixes it: some organizations', or your sign-in's own.
    public string? SignInTenant => Kind is PulseProblemKind.OtherDirectory or PulseProblemKind.SignedOut ? Tenant : null;

    /// Signing in fixes it: to the Azure CLI, or to an organization's directory.
    public bool OffersSignIn => NeedsSignIn || SignInTenant is not null;

    /// Signed out of the Azure CLI, which said `detail`; with `tenant`, your sign-in's directory wants you to sign in again
    /// there.
    public static PulseProblem SignedOut(string? detail, string? tenant = null) => new(Kind: PulseProblemKind.SignedOut, Detail: detail, Tenant: tenant);

    /// `organizations` are in the directory `tenant`, which the Azure CLI isn't signed in to; `others` says which other
    /// organizations couldn't be read, and why.
    public static PulseProblem OtherDirectory(IReadOnlyList<string> organizations, string tenant, string? others = null)
    {
        ArgumentNullException.ThrowIfNull(argument: organizations);
        ArgumentNullException.ThrowIfNull(argument: tenant);
        return new PulseProblem(Kind: PulseProblemKind.OtherDirectory, Detail: others, Organizations: new ValueList<string>(items: organizations), Tenant: tenant);
    }

    /// "fabrikam is in a directory your Azure CLI isn't signed in to.", naming three at most, as Windows writes a list.
    public static string InAnotherDirectory(IReadOnlyList<string> organizations)
    {
        ArgumentNullException.ThrowIfNull(argument: organizations);
        return ListWords.Join(names: organizations, limit: 3) + (organizations.Count == 1 ? " is" : " are") + " in a directory your Azure CLI isn't signed in to.";
    }

    /// The problem `error` makes, at `now`, reading `organization`, which it names when it's one of several.
    public static PulseProblem From(ADOError error, DateTimeOffset now, string? organization = null)
    {
        ArgumentNullException.ThrowIfNull(argument: error);
        return error.Kind switch
        {
            ADOErrorKind.Auth when error.Auth?.Kind == AuthErrorKind.CliNotFound => CliNotFound,
            ADOErrorKind.Auth when error.Auth?.Kind == AuthErrorKind.SignedOut => SignedOut(detail: error.Auth.Message, tenant: error.Auth.Tenant),
            ADOErrorKind.Auth => new PulseProblem(Kind: PulseProblemKind.AuthFailed, Detail: error.Auth?.Message),
            ADOErrorKind.Offline => Offline,
            ADOErrorKind.Throttled => new PulseProblem(Kind: PulseProblemKind.Throttled, Until: now + (error.RetryAfter ?? TimeSpan.Zero)),
            ADOErrorKind.Unauthorized => SignedOut(detail: error.Description),
            ADOErrorKind.OtherDirectory when error is { Organization: { } named, Tenant: { } tenant } => OtherDirectory(organizations: [named], tenant: tenant),
            _ => new PulseProblem(Kind: PulseProblemKind.Unreachable, Detail: (organization is null ? string.Empty : "Can't read " + organization + ": ") + error.Description),
        };
    }

    /// What's wrong when these organizations couldn't be read, while others could: signing in to a directory, which fixes
    /// those in it, comes first; then each of the rest, with why: the first reason for each, however its name is spelled,
    /// but that it's in a directory to sign in to over any other. Null when there are none. The Mac's
    /// `PulseProblem.organizations(_:)`.
    public static PulseProblem? FromFailures(IReadOnlyList<(string Organization, ADOError Error)> failures)
    {
        ArgumentNullException.ThrowIfNull(argument: failures);
        var unique = new List<(string Organization, ADOError Error)>();
        foreach (var failure in failures)
        {
            var index = unique.FindIndex(match: kept => string.Equals(a: kept.Organization, b: failure.Organization, comparisonType: StringComparison.OrdinalIgnoreCase));
            if (index < 0)
            {
                unique.Add(item: failure);
            }
            else if (failure.Error.Kind == ADOErrorKind.OtherDirectory && unique[index].Error.Kind != ADOErrorKind.OtherDirectory)
            {
                // Signing in there is what to do about it, whatever else went wrong reading it.
                unique[index] = (unique[index].Organization, failure.Error);
            }
        }
        if (unique.Count == 0)
        {
            return null;
        }
        if (unique.Select(selector: failure => failure.Error).FirstOrDefault(predicate: error => error.Kind == ADOErrorKind.OtherDirectory)?.Tenant is not { } tenant)
        {
            return new PulseProblem(Kind: PulseProblemKind.SomeOrganizations, Detail: "Couldn't read " + Reasons(failures: unique) + ".");
        }
        var together = unique.Where(predicate: failure => failure.Error.Kind == ADOErrorKind.OtherDirectory && failure.Error.Tenant == tenant).ToList();
        var rest = unique.Where(predicate: failure => !together.Contains(item: failure)).ToList();
        return OtherDirectory(
            organizations: together.Select(selector: failure => failure.Organization).ToList(),
            tenant: tenant,
            others: rest.Count == 0 ? null : "Couldn't read " + Reasons(failures: rest) + ".");
    }

    /// Each organization, and why it couldn't be read.
    static string Reasons(List<(string Organization, ADOError Error)> failures) =>
        string.Join(separator: ", ", values: failures.Select(selector: failure => failure.Organization + " (" + failure.Error.Description + ")"));
}
