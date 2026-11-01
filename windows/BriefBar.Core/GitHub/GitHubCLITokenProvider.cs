using System.ComponentModel;

namespace BriefBar.Core.GitHub;

/// Gets the token that the GitHub CLI signed in with (`gh auth login`), with `gh auth token --hostname github.com`. It
/// never asks for a personal access token, and never stores the token: it keeps it in memory for half an hour, then asks
/// `gh` again, in case you signed in as someone else, and asks again at once when GitHub rejects it (`Invalidate`).
/// Always those arguments, and each run is limited to 30 seconds, without prompts, update checks, spinners or colors;
/// callers asking at the same time share one run. The Mac's `GitHubCLITokenProvider`.
public sealed class GitHubCLITokenProvider : IGitHubTokenProvider
{
    /// BriefBar reads github.com only, not GitHub Enterprise Server.
    public const string Host = "github.com";

    /// How long a token is used before `gh` is asked again.
    public static TimeSpan Lifetime { get; } = TimeSpan.FromMinutes(value: 30);

    /// How long a run of `gh` may take.
    static readonly TimeSpan runLimit = TimeSpan.FromSeconds(value: 30);

    /// Quiet runs: no prompts, update checks, spinners or colors.
    static readonly Dictionary<string, string?> quiet = new(comparer: StringComparer.Ordinal)
    {
        ["GH_PROMPT_DISABLED"] = "1",
        ["GH_NO_UPDATE_NOTIFIER"] = "1",
        ["GH_SPINNER_DISABLED"] = "1",
        ["NO_COLOR"] = "1",
    };

    readonly Lock gate = new();
    readonly GitHubCLILocator locator;
    readonly IProcessRunner runner;
    readonly TimeProvider time;
    string? program;
    GitHubToken? cached;
    Task<GitHubToken>? pending;

    public GitHubCLITokenProvider(GitHubCLILocator locator, IProcessRunner? runner = null, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: locator);
        this.locator = locator;
        this.runner = runner ?? new ProcessRunner();
        this.time = time ?? TimeProvider.System;
    }

    /// `gh auth token`'s fixed arguments.
    public static IReadOnlyList<string> Arguments { get; } = ["auth", "token", "--hostname", Host];

    /// The variables its runs set.
    public static IReadOnlyDictionary<string, string?> Environment => quiet;

    /// The `gh` this provider runs, once it has looked for it: for signing in with the same one.
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

    public async Task<GitHubToken> TokenAsync(CancellationToken cancellationToken)
    {
        // A caller that gave up, as a source that's stopping, starts no run of `gh`; one under way finishes, as on the Mac.
        cancellationToken.ThrowIfCancellationRequested();
        Task<GitHubToken> fetching;
        lock (gate)
        {
            if (cached is { } token && time.GetUtcNow() - token.FetchedAt < Lifetime)
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

    /// The token in what `gh auth token` printed: the first line that isn't blank, which must be one word.
    public static GitHubToken ParseToken(string output, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: output);
        var token = output.Split(separator: ['\r', '\n'], options: StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault();
        if (token is null || token.Any(predicate: char.IsWhiteSpace))
        {
            throw new GitHubAuthException(error: GitHubAuthError.Failed(message: "The GitHub CLI returned no token."));
        }
        return new GitHubToken(Value: token, FetchedAt: now);
    }

    /// Tells a missing sign-in, which `gh auth login` fixes, from other failures, by what `gh` printed: its first line, at
    /// most 300 characters.
    public static GitHubAuthError ErrorFromOutput(string output)
    {
        ArgumentNullException.ThrowIfNull(argument: output);
        var lines = output.Split(separator: ['\r', '\n'], options: StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var message = PlainText.Prefix(text: lines.FirstOrDefault() ?? "The GitHub CLI failed.", length: 300);
        var lower = output.ToLowerInvariant();
        // `gh auth token` arrived in GitHub CLI 2.17.
        if (lower.Contains(value: "unknown command", comparisonType: StringComparison.Ordinal) || lower.Contains(value: "unknown flag", comparisonType: StringComparison.Ordinal))
        {
            return GitHubAuthError.Failed(message: "This GitHub CLI is too old for BriefBar: update it to version 2.17 or later.");
        }
        string[] signedOutHints = ["gh auth login", "no oauth token", "not logged in", "not logged into", "authentication required"];
        return signedOutHints.Any(predicate: hint => lower.Contains(value: hint, comparisonType: StringComparison.Ordinal))
            ? GitHubAuthError.SignedOut(message: message)
            : GitHubAuthError.Failed(message: message);
    }

    async Task<GitHubToken> FetchAndKeepAsync()
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

    async Task<GitHubToken> FetchAsync()
    {
        string? found;
        lock (gate)
        {
            found = program ??= locator.Locate();
        }
        if (found is null)
        {
            throw new GitHubAuthException(error: GitHubAuthError.CliNotFound);
        }
        ProcessResult result;
        try
        {
            result = await runner.RunAsync(program: found, arguments: Arguments, environment: quiet, timeout: runLimit, cancellationToken: CancellationToken.None)
                .ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (Exception error) when (error is Win32Exception or TimeoutException or IOException or InvalidOperationException)
        {
            // It may have been uninstalled or moved: it's looked for again next time.
            lock (gate)
            {
                program = null;
            }
            var message = error is TimeoutException ? "The GitHub CLI didn't answer within 30 seconds." : "Couldn't run the GitHub CLI.";
            throw new GitHubAuthException(error: GitHubAuthError.Failed(message: message), innerException: error);
        }
        if (result.ExitCode != 0)
        {
            throw new GitHubAuthException(error: ErrorFromOutput(output: result.Error));
        }
        return ParseToken(output: result.Output, now: time.GetUtcNow());
    }
}
