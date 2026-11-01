using System.ComponentModel;
using System.Globalization;
using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// Gets tokens from the Azure CLI's sign-in (`az login`), silently, as `az` itself does:
/// `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --output json`. Always those arguments,
/// since `az` is a batch file, which reads its command line as commands (`ProcessRunner`), and each run is limited to a
/// minute. A token is reused until five minutes before it expires, and callers asking at the same time share one run.
/// Tokens stay in memory. The Mac's `AzureCLITokenProvider`.
public sealed class AzureCLITokenProvider : IAccessTokenProvider
{
    /// Azure DevOps' application ID, the resource tokens are for.
    public const string AzureDevOpsResource = "499b84ac-1321-427f-aa17-267ca6975798";

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
    string? program;
    AccessToken? cached;
    Task<AccessToken>? pending;

    public AzureCLITokenProvider(AzureCLILocator locator, IProcessRunner? runner = null, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: locator);
        this.locator = locator;
        this.runner = runner ?? new ProcessRunner();
        this.time = time ?? TimeProvider.System;
    }

    /// `az get-access-token`'s fixed arguments.
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

    public async Task<AccessToken> TokenAsync(CancellationToken cancellationToken)
    {
        Task<AccessToken> fetching;
        lock (gate)
        {
            if (cached is { } token && token.IsValid(at: time.GetUtcNow()))
            {
                return token;
            }
            // On the thread pool, so that it never finishes before it's noted as pending.
            fetching = pending ??= Task.Run(function: FetchAndKeepAsync, cancellationToken: CancellationToken.None);
        }
        return await fetching.WaitAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
    }

    public void Invalidate()
    {
        lock (gate)
        {
            cached = null;
        }
    }

    /// The token in `output`, `az account get-access-token --output json`'s: until `expires_on`, seconds since 1970, in
    /// newer CLIs; or `expiresOn`, local time, in older ones; or half an hour from `now`.
    public static AccessToken ParseToken(string output, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: output);
        try
        {
            using var document = JsonDocument.Parse(json: output);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || ADOJson.Text(element: root, name: "accessToken") is not { Length: > 0 } value)
            {
                throw new AuthException(error: AuthError.Failed(message: "The Azure CLI returned no token."));
            }
            var expiry = ADOJson.Member(element: root, name: "expires_on") is { ValueKind: JsonValueKind.Number } seconds && seconds.TryGetDouble(value: out var epoch)
                ? DateTimeOffset.UnixEpoch.AddTicks(ticks: (long)Math.Round(a: epoch * TimeSpan.TicksPerSecond))
                : (ADOJson.Text(element: root, name: "expiresOn") is { } local ? ParseLocalTime(text: local) : null) ?? now.AddMinutes(minutes: 30);
            return new AccessToken(Value: value, ExpiresOn: expiry, Account: AccessToken.AccountInJwt(token: value));
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
    /// `ERROR:` line, or its first line, without the prefix, at most 300 characters.
    public static AuthError ErrorFromOutput(string output)
    {
        ArgumentNullException.ThrowIfNull(argument: output);
        var lines = output.Split(separator: ['\r', '\n'], options: StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var message = (Array.Find(array: lines, match: line => line.StartsWith(value: "ERROR:", comparisonType: StringComparison.Ordinal)) ?? lines.FirstOrDefault() ?? "The Azure CLI failed.")
            .Replace(oldValue: "ERROR: ", newValue: string.Empty, comparisonType: StringComparison.Ordinal);
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

    async Task<AccessToken> FetchAndKeepAsync()
    {
        try
        {
            var token = await FetchAsync().ConfigureAwait(continueOnCapturedContext: false);
            lock (gate)
            {
                cached = token;
            }
            return token;
        }
        finally
        {
            lock (gate)
            {
                pending = null;
            }
        }
    }

    async Task<AccessToken> FetchAsync()
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
            result = await runner.RunAsync(program: found, arguments: Arguments, environment: quiet, timeout: runLimit, cancellationToken: CancellationToken.None)
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
