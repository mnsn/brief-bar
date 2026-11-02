using System.ComponentModel;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace BriefBar.Core.AzureDevOps;

/// Gets tokens from the Azure CLI's sign-in (`az login`), silently, as `az` itself does:
/// `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --output json`, for your sign-in's
/// directory, and with `--tenant` and a directory's ID for each other directory an organization is in. Always those
/// arguments, since `az` is a batch file, which reads its command line as commands (`ProcessRunner`), and each run is
/// limited to a minute. A token is reused until five minutes before it expires, and callers asking for the same directory
/// at the same time share one run. Tokens stay in memory. The Mac's `AzureCLITokenProvider`.
///
/// Your sign-in's directory, once known, is asked for with `--tenant` too, rather than in the Azure CLI's default
/// directory, which `az login --tenant` changes: so who BriefBar reads as stays the same, and so do the organizations it
/// reads in your directory. It follows the default directory only when that's someone else's. Tokens kept for other
/// directories are your account's: when someone else signs in, they go, and so does any token that was on its way then,
/// whichever directory it's for (`accounts`).
public sealed partial class AzureCLITokenProvider : IAccessTokenProvider
{
    /// Azure DevOps' application ID, the resource tokens are for.
    public const string AzureDevOpsResource = "499b84ac-1321-427f-aa17-267ca6975798";

    /// What a token for a directory that isn't your account's own says when someone else has signed in, or one that was on
    /// its way when that happened: nobody gets it.
    const string SomeoneElse = "Someone else signed in to the Azure CLI.";

    /// Where your sign-in's directory's token is kept, and its run shared: any other directory is kept by its ID.
    const string Home = "";

    /// How long a run of `az` may take.
    static readonly TimeSpan runLimit = TimeSpan.FromMinutes(value: 1);

    /// Quiet runs, out of the CLI's telemetry.
    static readonly Dictionary<string, string?> quiet = new(comparer: StringComparer.Ordinal)
    {
        ["AZURE_CORE_COLLECT_TELEMETRY"] = "false",
        ["AZURE_CORE_ONLY_SHOW_ERRORS"] = "true",
        ["AZURE_CORE_NO_COLOR"] = "true",
    };

    readonly Lock gate = new();
    readonly AzureCLILocator locator;
    readonly IProcessRunner runner;
    readonly TimeProvider time;
    /// By directory, `Home` for your sign-in's.
    readonly Dictionary<string, AccessToken> cached = new(comparer: StringComparer.Ordinal);
    /// The `az` run under way for each directory, which everyone asking for it then shares, with the account it was kept
    /// for.
    readonly Dictionary<string, Task<(AccessToken Token, int Account)>> pending = new(comparer: StringComparer.Ordinal);
    string? program;
    /// Your sign-in's directory, once known.
    string? homeTenant;
    /// Whom the last token for your directory was for, and the directory that account is from, which its tokens from other
    /// directories name too: they tell your account from someone else's.
    (string? Account, string? Tenant)? homeAccount;
    /// How many times the account your tokens are for has changed: a token fetched across a change is the last account's.
    int accounts;

    /// - `homeTenant`: your sign-in's directory, when it's known from before: the one BriefBar last read your pull requests
    ///   with.
    /// - `homeAccountTenant`: where that account is from (`AccessToken.AccountTenant`), so that after a restart a sign-in
    ///   your directory wants again, while the Azure CLI's default is another directory you're a guest in, isn't taken for
    ///   someone else's.
    public AzureCLITokenProvider(
        AzureCLILocator locator, IProcessRunner? runner = null, TimeProvider? time = null, string? homeTenant = null, string? homeAccountTenant = null)
    {
        ArgumentNullException.ThrowIfNull(argument: locator);
        this.locator = locator;
        this.runner = runner ?? new ProcessRunner();
        this.time = time ?? TimeProvider.System;
        this.homeTenant = TenantId.From(text: homeTenant);
        if (Origin(text: homeAccountTenant) is { } origin)
        {
            homeAccount = (Account: null, Tenant: origin);
        }
    }

    /// `az get-access-token`'s fixed arguments, for your sign-in's directory before it's known.
    public static IReadOnlyList<string> Arguments { get; } = ["account", "get-access-token", "--resource", AzureDevOpsResource, "--output", "json"];

    /// The variables its runs set.
    public static IReadOnlyDictionary<string, string?> Environment => quiet;

    /// The `az` this provider runs, once it has looked for it: for signing in with the same one.
    public string? Program
    {
        get
        {
            lock (gate)
            {
                return program;
            }
        }
    }

    public async Task<AccessToken> TokenAsync(string? tenant, CancellationToken cancellationToken)
    {
        var directory = Directory(tenant: tenant);
        Task<(AccessToken Token, int Account)>? fetching;
        lock (gate)
        {
            if (cached.TryGetValue(key: directory ?? Home, value: out var kept) && kept.IsValid(at: time.GetUtcNow()))
            {
                return kept;
            }
            if (!pending.TryGetValue(key: directory ?? Home, value: out fetching))
            {
                // On the thread pool, so that it never finishes before it's noted as pending.
                fetching = Task.Run(function: () => FetchAndKeepAsync(directory: directory), cancellationToken: CancellationToken.None);
                pending[directory ?? Home] = fetching;
            }
        }
        var fetched = await fetching.WaitAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        lock (gate)
        {
            // Someone else signed in to the Azure CLI since it was kept: it's the last account's, and nobody waiting gets it.
            if (fetched.Account != accounts)
            {
                throw new AuthException(error: AuthError.Failed(message: SomeoneElse));
            }
        }
        return fetched.Token;
    }

    public void Invalidate(string? tenant)
    {
        var directory = Directory(tenant: tenant);
        lock (gate)
        {
            cached.Remove(key: directory ?? Home);
        }
    }

    /// Where `account` (`AccessToken.Account`) is from, while your sign-in's tokens are its: for the app to keep, and give
    /// back after a restart. For an account they aren't, or no longer are, nothing, so that one account's is never kept for
    /// another.
    public string? AccountTenantOf(string account)
    {
        ArgumentNullException.ThrowIfNull(argument: account);
        lock (gate)
        {
            return homeAccount is { } home && home.Account == account ? home.Tenant : null;
        }
    }

    /// `az get-access-token`'s fixed arguments for `tenant`'s directory, a `TenantId`, or for the Azure CLI's default
    /// directory without one.
    public static IReadOnlyList<string> ArgumentsFor(string? tenant) => tenant is null ? Arguments : [.. Arguments, "--tenant", tenant];

    /// The token in `output`, `az account get-access-token --output json`'s: until `expires_on`, seconds since 1970, in
    /// newer CLIs; or `expiresOn`, local time, in older ones; or half an hour from `now`. The directory it's for is what the
    /// token says, over what the CLI says it asked for (`tenant`).
    public static AccessToken ParseToken(string output, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: output);
        try
        {
            using var document = JsonDocument.Parse(json: output);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || LenientJson.Text(element: root, name: "accessToken") is not { Length: > 0 } value)
            {
                throw new AuthException(error: AuthError.Failed(message: "The Azure CLI returned no token."));
            }
            var expiry = LenientJson.Member(element: root, name: "expires_on") is { ValueKind: JsonValueKind.Number } seconds && seconds.TryGetDouble(value: out var epoch)
                ? DateTimeOffset.UnixEpoch.AddTicks(ticks: (long)Math.Round(a: epoch * TimeSpan.TicksPerSecond))
                : (LenientJson.Text(element: root, name: "expiresOn") is { } local ? ParseLocalTime(text: local) : null) ?? now.AddMinutes(minutes: 30);
            return new AccessToken(
                Value: value,
                ExpiresOn: expiry,
                Account: AccessToken.AccountInJwt(token: value),
                Tenant: AccessToken.TenantInJwt(token: value) ?? TenantId.From(text: LenientJson.Text(element: root, name: "tenant")),
                AccountTenant: AccessToken.AccountTenantInJwt(token: value));
        }
        catch (JsonException error)
        {
            throw new AuthException(error: AuthError.Failed(message: "The Azure CLI returned no token."), innerException: error);
        }
    }

    /// `2026-10-21 10:31:46.000000`, in this PC's time zone.
    public static DateTimeOffset? ParseLocalTime(string text)
    {
        ArgumentNullException.ThrowIfNull(argument: text);
        if (!DateTime.TryParseExact(
            s: text, formats: ["yyyy-MM-dd HH:mm:ss.ffffff", "yyyy-MM-dd HH:mm:ss"], provider: CultureInfo.InvariantCulture, style: DateTimeStyles.AssumeLocal, result: out var date))
        {
            return null;
        }
        return new DateTimeOffset(dateTime: date);
    }

    /// Tells a missing or expired sign-in, which `az login` fixes, from other failures, by what the CLI printed: its first
    /// `ERROR:` line, or its first line, without the prefix, without IDs, email addresses or the names of directories it
    /// quotes or names (`Redacted`), at most 300 characters.
    public static AuthError ErrorFromOutput(string output)
    {
        ArgumentNullException.ThrowIfNull(argument: output);
        var lines = output.Split(separator: ['\r', '\n'], options: StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var message = Redacted(message: (Array.Find(array: lines, match: line => line.StartsWith(value: "ERROR:", comparisonType: StringComparison.Ordinal)) ?? lines.FirstOrDefault() ?? "The Azure CLI failed.")
            .Replace(oldValue: "ERROR: ", newValue: string.Empty, comparisonType: StringComparison.Ordinal));
        if (message.Length > 300)
        {
            message = message[..300];
        }
        string[] signedOutHints =
        [
            "az login", "please run", "aadsts", "interaction_required", "invalid_grant", "refresh token", "no subscription", "not logged in",
            "does not exist in msal token cache",
        ];
        var lower = output.ToLowerInvariant();
        return signedOutHints.Any(predicate: hint => lower.Contains(value: hint, comparisonType: StringComparison.Ordinal))
            ? AuthError.SignedOut(message: message)
            : AuthError.Failed(message: message);
    }

    /// What the Azure CLI says, without email addresses, IDs (a directory's, a request's), or the name of a tenant or
    /// directory it quotes or names: before it's cut short, so that no part of one is left. Addresses go first, so one
    /// whose user name or domain holds an ID goes whole, rather than leaving the rest of it around `<id>`. A quoted name, in
    /// single or double quotes, goes up to the last of the same quote on its line that can end one, as a name can hold
    /// quotes itself, as in Fabrikam's Lab or Students' Lab; one it names, to the line's end. The panel shows it, and it
    /// could reach the log, which never holds IDs, as on the Mac.
    internal static string Redacted(string message)
    {
        ArgumentNullException.ThrowIfNull(argument: message);
        var withoutAccounts = AccountPattern().Replace(input: message, replacement: "<account>");
        var withoutIds = IdPattern().Replace(input: withoutAccounts, replacement: "<id>");
        var withoutQuotedNames = QuotedDirectoryPattern().Replace(input: withoutIds, replacement: "$1 $2<name>$2");
        return NamedDirectoryPattern().Replace(input: withoutQuotedNames, replacement: "$1 named <name>");
    }

    /// A directory as tokens are kept by: its ID (`TenantId`); null for none, which is your sign-in's. Anything else isn't
    /// a directory BriefBar asks the Azure CLI for.
    static string? Directory(string? tenant)
    {
        if (tenant is null)
        {
            return null;
        }
        return TenantId.From(text: tenant) ?? throw new ArgumentException(message: "Not a directory's ID.", paramName: nameof(tenant));
    }

    /// Where an account is from, as kept: a directory's ID, or an identity provider such as `live.com`, lowercased.
    static string? Origin(string? text) => string.IsNullOrWhiteSpace(value: text) ? null : TenantId.From(text: text) ?? text.Trim().ToLowerInvariant();

    [GeneratedRegex(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", options: RegexOptions.CultureInvariant)]
    private static partial Regex IdPattern();

    /// An address, whatever a Microsoft Entra user name holds: apostrophes, wherever they are, as in O'Brien or robin',
    /// and ! # ^ ~, as in a guest's sign-in name in another directory, robin_contoso.example#EXT#@fabrikam.onmicrosoft.com,
    /// which holds their own address and their directory's domain. A user name of apostrophes only goes too, with any quote
    /// before it, as nothing tells them apart; one that starts with a letter or digit keeps the quote before it.
    [GeneratedRegex(pattern: @"(?:[A-Za-z0-9._%+!#^~-]+(?:'+[A-Za-z0-9._%+!#^~-]+)*'*|'+)@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", options: RegexOptions.CultureInvariant)]
    private static partial Regex AccountPattern();

    /// A tenant's or directory's name in single or double quotes, up to the last of the same quote on its line that can end
    /// one, not one inside a word as in Fabrikam's or isn't; or to the line's end without one. One that's only a directory's
    /// ID, `<id>` by then, stays as it is.
    [GeneratedRegex(pattern: @"\b(tenant|directory) (['""])(?!<id>\2)(?:[^\r\n]*\2(?!\w)|[^\r\n]*)", options: RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex QuotedDirectoryPattern();

    /// A tenant's or directory's name without quotes, as in "the tenant named Fabrikam. This can happen…": to the line's
    /// end, as nothing tells where the name ends.
    [GeneratedRegex(pattern: @"\b(tenant|directory) named [^\r\n]*", options: RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex NamedDirectoryPattern();

    /// A token for `directory`, kept, with the account it was kept for. One that comes back after someone else signed in
    /// may be the last account's, whichever directory it's for, and one from another directory for an account from
    /// elsewhere than yours means someone else has: nobody gets either, and neither is kept.
    async Task<(AccessToken Token, int Account)> FetchAndKeepAsync(string? directory)
    {
        try
        {
            int account;
            lock (gate)
            {
                account = accounts;
            }
            var token = await FetchAsync(directory: directory).ConfigureAwait(continueOnCapturedContext: false);
            lock (gate)
            {
                if (accounts != account)
                {
                    throw new AuthException(error: AuthError.Failed(message: SomeoneElse));
                }
                // Every token kept goes, the last account's, with any on its way: the next one for yours tells who's
                // signed in, and what's read as them starts over.
                if (directory is not null && homeAccount?.Tenant is { } yours && token.AccountTenant is { } theirs && yours != theirs)
                {
                    cached.Clear();
                    accounts++;
                    throw new AuthException(error: AuthError.Failed(message: SomeoneElse));
                }
                Keep(token: token, directory: directory);
                return (token, accounts);
            }
        }
        finally
        {
            lock (gate)
            {
                pending.Remove(key: directory ?? Home);
            }
        }
    }

    /// Keeps a token until it nears its expiry. One for your directory that's another account's means someone else signed
    /// in to the Azure CLI: the other directories' tokens, the last account's, go, and so do those on their way. Under the
    /// lock.
    void Keep(AccessToken token, string? directory)
    {
        if (directory is null)
        {
            if (homeAccount is { } last && last.Account != token.Account)
            {
                cached.Clear();
                if (last.Account is not null)
                {
                    accounts++;
                }
            }
            homeAccount = (Account: token.Account, Tenant: token.AccountTenant);
        }
        cached[directory ?? Home] = token;
    }

    /// A token for `directory`, or for yours: in the directory BriefBar knows as yours. When the Azure CLI can't give one
    /// there, it's someone else's sign-in, if the CLI's default directory has another account: then that directory becomes
    /// yours. If it's your account there, as a guest, your directory only needs you to sign in again, there: a plain
    /// `az login` may sign in to another one without what yours asks for, such as multi-factor authentication.
    async Task<AccessToken> FetchAsync(string? directory)
    {
        if (directory is not null)
        {
            return await RunAsync(tenant: directory).ConfigureAwait(continueOnCapturedContext: false);
        }
        string? home;
        lock (gate)
        {
            home = homeTenant;
        }
        if (home is null)
        {
            var first = await RunAsync(tenant: null).ConfigureAwait(continueOnCapturedContext: false);
            lock (gate)
            {
                homeTenant = first.Tenant;
            }
            return first;
        }
        try
        {
            return await RunAsync(tenant: home).ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (AuthException error) when (error.Error.Kind == AuthErrorKind.SignedOut)
        {
            var current = await RunAsync(tenant: null).ConfigureAwait(continueOnCapturedContext: false);
            string? yours;
            lock (gate)
            {
                // The directory your account is from, which a guest token names: the pinned one may be a guest's too.
                yours = homeAccount?.Tenant ?? home;
            }
            if (current.Tenant != home && current.AccountTenant == yours)
            {
                throw new AuthException(error: AuthError.SignedOut(message: error.Error.Message, tenant: home), innerException: error);
            }
            if (current.Tenant is { } theirs)
            {
                lock (gate)
                {
                    homeTenant = theirs;
                }
            }
            return current;
        }
    }

    /// Runs `az get-access-token`, for `tenant`'s directory, or the Azure CLI's default.
    async Task<AccessToken> RunAsync(string? tenant)
    {
        string? found;
        lock (gate)
        {
            found = program ??= locator.Locate();
        }
        if (found is null)
        {
            throw new AuthException(error: AuthError.CliNotFound);
        }
        ProcessResult result;
        try
        {
            result = await runner.RunAsync(program: found, arguments: ArgumentsFor(tenant: tenant), environment: quiet, timeout: runLimit, cancellationToken: CancellationToken.None)
                .ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (Exception error) when (error is Win32Exception or TimeoutException or IOException or InvalidOperationException or ArgumentException)
        {
            // It may have been uninstalled or moved, or be at a path that `cmd.exe` can't take, with a percent sign
            // (`ProcessRunner` refuses it): it's looked for again next time. The Mac's catches whatever running it throws.
            lock (gate)
            {
                program = null;
            }
            var message = error is TimeoutException ? "The Azure CLI didn't answer within a minute." : "Couldn't run the Azure CLI.";
            throw new AuthException(error: AuthError.Failed(message: message), innerException: error);
        }
        if (result.ExitCode != 0)
        {
            throw new AuthException(error: ErrorFromOutput(output: result.Error));
        }
        return ParseToken(output: result.Output, now: time.GetUtcNow());
    }
}
