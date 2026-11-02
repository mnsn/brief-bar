using System.ComponentModel;
using System.Diagnostics.CodeAnalysis;

namespace BriefBar.Core.GitHub;

/// Gets the token that the GitHub CLI signed in with (`gh auth login`), with `gh auth token --hostname github.com`. It
/// never asks for a personal access token, and never stores the token: it keeps it in memory for half an hour, then asks
/// `gh` again, in case you signed in as someone else, and asks again at once when GitHub rejects it (`Invalidate`).
/// Always those arguments, and each run is limited to 30 seconds, without prompts, update checks, spinners or colors;
/// callers asking at the same time share one run. Stopped, as GitHub is turned off, it ends a run under way and forgets
/// the token, and nothing that run gets is kept or given to anyone (`StopAsync`). The Mac's `GitHubCLITokenProvider`.
[SuppressMessage(
    category: "Design",
    checkId: "CA1001:Types that own disposable fields should be disposable",
    Justification = "It holds a token source only while a run of gh is under way, and that's disposed once the run has ended: by the run, or by StopAsync when it took it.")]
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
    /// Ends `pending`, as GitHub is turned off: whichever lets go of it, the run as it ends or `StopAsync`, disposes it.
    CancellationTokenSource? ending;

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
        Task<GitHubToken> fetching;
        lock (gate)
        {
            // A caller that gave up, as a source that's stopping, starts no run of `gh`. Checked under the lock that
            // `StopAsync` takes, so that a run starts before a stop, which ends it, or not at all; one under way goes on
            // for whoever shares it, until the provider stops.
            cancellationToken.ThrowIfCancellationRequested();
            if (cached is { } token && time.GetUtcNow() - token.FetchedAt < Lifetime)
            {
                return token;
            }
            if (pending is null)
            {
                var run = new CancellationTokenSource();
                var runEnding = run.Token;
                ending = run;
                // On the thread pool, so that it never finishes before it's noted as pending.
                pending = Task.Run(function: () => FetchAndKeepAsync(run: run, cancellationToken: runEnding), cancellationToken: CancellationToken.None);
            }
            fetching = pending;
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

    /// Ends a run of `gh` under way, and forgets the token, as GitHub is turned off: what that run gets, should it finish
    /// all the same, is kept by nothing and given to no one. Calls from then on run `gh` again. Returns once the run has
    /// ended, and what ending it set off has finished: that runs on the thread pool (`CancelAsync`), not in the caller.
    public Task StopAsync()
    {
        CancellationTokenSource? run;
        Task<GitHubToken>? running;
        lock (gate)
        {
            run = ending;
            running = pending;
            ending = null;
            pending = null;
            cached = null;
        }
        return run is null || running is null ? Task.CompletedTask : EndAsync(run: run, running: running);
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

    /// Ends `running`, the run that `run` ends, which `StopAsync` took, then lets go of `run`, which nothing uses by then.
    static async Task EndAsync(CancellationTokenSource run, Task running)
    {
        try
        {
            await run.CancelAsync().ConfigureAwait(continueOnCapturedContext: false);
            await running.ConfigureAwait(options: ConfigureAwaitOptions.SuppressThrowing);
        }
        finally
        {
            run.Dispose();
        }
    }

    /// Runs `gh` until it ends, or `cancellationToken`, `run`'s, ends it, and keeps the token it got, unless the provider
    /// stopped meanwhile: then it keeps nothing, and throws rather than give the token to anyone. Lets go of `run` as it
    /// ends, unless `StopAsync` took it.
    async Task<GitHubToken> FetchAndKeepAsync(CancellationTokenSource run, CancellationToken cancellationToken)
    {
        try
        {
            var token = await FetchAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            lock (gate)
            {
                if (!ReferenceEquals(objA: ending, objB: run))
                {
                    throw new OperationCanceledException(message: "GitHub was turned off while the GitHub CLI ran.", token: cancellationToken);
                }
                cached = token;
            }
            return token;
        }
        finally
        {
            bool stillPending;
            lock (gate)
            {
                stillPending = ReferenceEquals(objA: ending, objB: run);
                if (stillPending)
                {
                    ending = null;
                    pending = null;
                }
            }
            if (stillPending)
            {
                run.Dispose();
            }
        }
    }

    async Task<GitHubToken> FetchAsync(CancellationToken cancellationToken)
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
            result = await runner.RunAsync(program: found, arguments: Arguments, environment: quiet, timeout: runLimit, cancellationToken: cancellationToken)
                .ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (Exception error) when (error is Win32Exception or TimeoutException or IOException or InvalidOperationException or ArgumentException)
        {
            // It may have been uninstalled or moved, or be a batch file at a path that `cmd.exe` can't take (`ProcessRunner`
            // refuses it): it's looked for again next time. The Mac's catches whatever running it throws.
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
