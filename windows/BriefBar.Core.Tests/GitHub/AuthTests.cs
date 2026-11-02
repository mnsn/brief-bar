using System.ComponentModel;
using System.Reflection;
using BriefBar.Core.GitHub;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.GitHub;

/// The GitHub CLI's sign-in: what `gh auth token` prints, how its token is kept, and where `gh` is. The Swift tests'
/// `TokenTests`, `TokenProviderTests` and `LocatorTests`, with Windows' places.
public sealed class AuthTests
{
    const string InstalledCLI = @"C:\Program Files\GitHub CLI\gh.exe";
    const string InstalledCLIFor32Bits = @"C:\Program Files (x86)\GitHub CLI\gh.exe";
    const string LinkedByWinGet = @"C:\Users\robin\AppData\Local\Microsoft\WinGet\Links\gh.exe";

    static readonly Dictionary<string, string?> environment = new(comparer: StringComparer.OrdinalIgnoreCase)
    {
        ["PATH"] = @"C:\Windows\System32;C:\Tools",
        ["ProgramFiles"] = @"C:\Program Files",
        ["ProgramFiles(x86)"] = @"C:\Program Files (x86)",
        ["LOCALAPPDATA"] = @"C:\Users\robin\AppData\Local",
    };

    [Fact]
    public void ReadsTheTokenOnItsOwnLine()
    {
        Assert.Equal(
            expected: new GitHubToken(Value: "gho_abc123", FetchedAt: TestTimes.Reference),
            actual: GitHubCLITokenProvider.ParseToken(output: "gho_abc123\n", now: TestTimes.Reference));
        Assert.Equal(expected: "gho_abc123", actual: GitHubCLITokenProvider.ParseToken(output: "\n   gho_abc123  \n", now: TestTimes.Reference).Value);
        // As Windows ends lines.
        Assert.Equal(expected: "gho_abc123", actual: GitHubCLITokenProvider.ParseToken(output: "gho_abc123\r\n", now: TestTimes.Reference).Value);
    }

    [Theory]
    [InlineData("")]
    [InlineData("\n  \n")]
    [InlineData("two words\n")]
    public void NoTokenIsAFailure(string output)
    {
        var error = Assert.Throws<GitHubAuthException>(testCode: () => GitHubCLITokenProvider.ParseToken(output: output, now: TestTimes.Reference));
        Assert.Equal(expected: GitHubAuthError.Failed(message: "The GitHub CLI returned no token."), actual: error.Error);
    }

    /// Never the token itself, should a token find its way into a message.
    [Fact]
    public void ATokenDoesntSayItsValue() =>
        Assert.DoesNotContain(expectedSubstring: "gho_secret", actualString: new GitHubToken(Value: "gho_secret", FetchedAt: TestTimes.Reference).ToString(), comparisonType: StringComparison.Ordinal);

    [Fact]
    public void TellsASignedOutCLIFromOtherFailures()
    {
        var notLoggedIn = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n";
        Assert.Equal(expected: GitHubAuthError.SignedOut(message: notLoggedIn.TrimEnd(trimChar: '\n')), actual: GitHubCLITokenProvider.ErrorFromOutput(output: notLoggedIn));
        Assert.Equal(
            expected: GitHubAuthError.SignedOut(message: "no oauth token found for github.com"),
            actual: GitHubCLITokenProvider.ErrorFromOutput(output: "no oauth token found for github.com"));
        Assert.Equal(expected: "HTTP 401: Authentication required", actual: GitHubCLITokenProvider.ErrorFromOutput(output: "HTTP 401: Authentication required").Description);
        Assert.Equal(
            expected: GitHubAuthError.SignedOut(message: "HTTP 401: Authentication required"),
            actual: GitHubCLITokenProvider.ErrorFromOutput(output: "HTTP 401: Authentication required"));

        Assert.Equal(expected: GitHubAuthError.Failed(message: "something broke"), actual: GitHubCLITokenProvider.ErrorFromOutput(output: "\n  something broke  \nmore detail"));
        Assert.Equal(expected: GitHubAuthError.Failed(message: "something broke"), actual: GitHubCLITokenProvider.ErrorFromOutput(output: "\r\n  something broke  \r\nmore detail"));
        Assert.Equal(expected: GitHubAuthError.Failed(message: "The GitHub CLI failed."), actual: GitHubCLITokenProvider.ErrorFromOutput(output: string.Empty));
        Assert.Equal(
            expected: GitHubAuthError.Failed(message: new string(c: 'x', count: 300)),
            actual: GitHubCLITokenProvider.ErrorFromOutput(output: new string(c: 'x', count: 500)));
    }

    [Theory]
    [InlineData("unknown command \"token\" for \"gh auth\"")]
    [InlineData("unknown flag: --hostname")]
    public void AnOldCLIIsNamedAsSuch(string output) =>
        Assert.Equal(
            expected: GitHubAuthError.Failed(message: "This GitHub CLI is too old for BriefBar: update it to version 2.17 or later."),
            actual: GitHubCLITokenProvider.ErrorFromOutput(output: output));

    /// The Mac's `runsTheCLIWithTheUsualPlacesAndNoPrompts`: a Mac app gets only the system's PATH, so the usual places are
    /// added to it. Windows gives BriefBar your PATH, which is left as it is: runs are kept from prompting, checking for
    /// updates, spinning or coloring, and get only fixed words.
    [Fact]
    public void RunsTheCLIWithNoPromptsAndLeavesThePathAlone()
    {
        Assert.Equal(
            expected: new Dictionary<string, string?>
            {
                ["GH_PROMPT_DISABLED"] = "1",
                ["GH_NO_UPDATE_NOTIFIER"] = "1",
                ["GH_SPINNER_DISABLED"] = "1",
                ["NO_COLOR"] = "1",
            },
            actual: GitHubCLITokenProvider.Environment);
        Assert.Equal(expected: ["auth", "token", "--hostname", "github.com"], actual: GitHubCLITokenProvider.Arguments);
        // Fixed words, which even a batch file may get.
        Assert.EndsWith(
            expectedEndString: "\" auth token --hostname github.com\"",
            actualString: ProcessRunner.CmdArguments(program: @"C:\Tools\gh.cmd", arguments: GitHubCLITokenProvider.Arguments, keepOpen: false));
    }

    [Fact]
    public void ErrorsSayWhatToDo()
    {
        Assert.Equal(expected: "The GitHub CLI (gh) isn't installed.", actual: GitHubAuthError.CliNotFound.Description);
        Assert.Equal(expected: "Not signed in to the GitHub CLI.", actual: GitHubAuthError.SignedOut(message: string.Empty).Description);
        Assert.Equal(expected: "Run gh auth login", actual: GitHubAuthError.SignedOut(message: "Run gh auth login").Description);
    }

    [Fact]
    public async Task AsksTheCLIForGitHubDotComsToken()
    {
        var cli = new FakeProcessRunner(answer: _ => Output(text: "gho_first\n"));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli, time: new TestClock(start: TestTimes.Reference));

        Assert.Equal(expected: new GitHubToken(Value: "gho_first", FetchedAt: TestTimes.Reference), actual: await provider.TokenAsync(cancellationToken: TestContext.Current.CancellationToken));
        var run = Assert.Single(collection: cli.Runs);
        Assert.Equal(expected: InstalledCLI, actual: run.Program);
        Assert.Equal(expected: ["auth", "token", "--hostname", "github.com"], actual: run.Arguments);
        Assert.Equal(expected: TimeSpan.FromSeconds(value: 30), actual: run.Timeout);
        Assert.Equal(expected: GitHubCLITokenProvider.Environment, actual: run.Environment);
        Assert.Equal(expected: InstalledCLI, actual: provider.Program);
    }

    [Fact]
    public async Task KeepsTheTokenForHalfAnHour()
    {
        var cli = new FakeProcessRunner(answer: run => Output(text: run == 1 ? "gho_first" : "gho_second"));
        var clock = new TestClock(start: TestTimes.Reference);
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli, time: clock);
        var cancellationToken = TestContext.Current.CancellationToken;

        Assert.Equal(expected: "gho_first", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        clock.Set(time: TestTimes.T(seconds: 29 * GitHubFixture.Minute));
        Assert.Equal(expected: "gho_first", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.Single(collection: cli.Runs);

        clock.Set(time: TestTimes.T(seconds: 30 * GitHubFixture.Minute));
        Assert.Equal(expected: "gho_second", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.Equal(expected: 2, actual: cli.Runs.Count);
    }

    [Fact]
    public async Task AsksAgainOnceInvalidated()
    {
        var cli = new FakeProcessRunner(answer: run => Output(text: run == 1 ? "gho_first" : "gho_second"));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli, time: new TestClock(start: TestTimes.Reference));
        var cancellationToken = TestContext.Current.CancellationToken;

        Assert.Equal(expected: "gho_first", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        provider.Invalidate();
        Assert.Equal(expected: "gho_second", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.Equal(expected: 2, actual: cli.Runs.Count);
    }

    [Fact]
    public async Task CallersAtTheSameTimeShareOneRun()
    {
        var cli = new FakeProcessRunner(answer: _ => Output(text: "gho_shared"), delay: TimeSpan.FromMilliseconds(value: 100));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli, time: new TestClock(start: TestTimes.Reference));
        var cancellationToken = TestContext.Current.CancellationToken;

        var tokens = await Task.WhenAll(provider.TokenAsync(cancellationToken: cancellationToken), provider.TokenAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: ["gho_shared", "gho_shared"], actual: tokens.Select(selector: token => token.Value));
        Assert.Single(collection: cli.Runs);
    }

    /// A caller that gave up, as a source that's stopping, runs nothing.
    [Fact]
    public async Task ACallerThatGaveUpRunsNothing()
    {
        var cli = new FakeProcessRunner(answer: _ => Output(text: "gho_never"));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(testCode: () => provider.TokenAsync(cancellationToken: new CancellationToken(canceled: true)));
        Assert.Empty(collection: cli.Runs);
    }

    /// Nor does one that gave up while it waited for the provider's lock, as a source that stops cancels its read, then
    /// stops the provider: it checks under the lock that `StopAsync` takes, so that a run starts before a stop, which ends
    /// it, or not at all. The test holds the lock, through its private field, as a thread that's slow to give it up would.
    [Fact]
    public async Task ACallerThatGaveUpWhileItWaitedRunsNothing()
    {
        var cli = new FakeProcessRunner(answer: _ => Output(text: "gho_never"));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli, time: new TestClock(start: TestTimes.Reference));
        var gate = typeof(GitHubCLITokenProvider).GetField(name: "gate", bindingAttr: BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(obj: provider) as Lock
            ?? throw new InvalidOperationException(message: "GitHubCLITokenProvider has no lock named gate any more: update this test.");
        using var giveUp = new CancellationTokenSource();
        Task<GitHubToken> asking;
        gate.Enter();
        try
        {
            asking = Task.Run(function: () => provider.TokenAsync(cancellationToken: giveUp.Token), cancellationToken: CancellationToken.None);
            // Long enough for it to be waiting for the lock.
            Thread.Sleep(millisecondsTimeout: 200);
            giveUp.Cancel();
            _ = provider.StopAsync();
        }
        finally
        {
            gate.Exit();
        }

        await Assert.ThrowsAnyAsync<OperationCanceledException>(testCode: () => asking);
        // Long enough for a run that started to be noted.
        await Task.Delay(millisecondsDelay: 200, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Empty(collection: cli.Runs);
    }

    /// Stopped while `gh auth token` runs, as GitHub is turned off, it tells the run to end; should `gh` finish all the same,
    /// what it got is kept by nothing and given to no one. Asked again, it runs `gh` again.
    [Fact]
    public async Task StoppingEndsARunUnderWayAndKeepsNothingItGets()
    {
        var finish = new TaskCompletionSource(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
        var cli = new FakeProcessRunner(answer: run => Output(text: run == 1 ? "gho_dropped" : "gho_fresh"), hold: run => run == 1 ? finish.Task : Task.CompletedTask);
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli, time: new TestClock(start: TestTimes.Reference));
        var cancellationToken = TestContext.Current.CancellationToken;

        var asking = provider.TokenAsync(cancellationToken: cancellationToken);
        await Waiting.Until(condition: () => cli.Runs.Count == 1);
        var stopping = provider.StopAsync();
        Assert.True(condition: cli.Runs[0].CancellationToken.IsCancellationRequested);
        // It returns once the run has ended.
        await Task.Delay(millisecondsDelay: 100, cancellationToken: cancellationToken);
        Assert.False(condition: stopping.IsCompleted);
        finish.SetResult();
        await stopping.WaitAsync(timeout: Waiting.Limit, cancellationToken: cancellationToken);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(testCode: () => asking);
        Assert.Equal(expected: "gho_fresh", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.Equal(expected: 2, actual: cli.Runs.Count);
    }

    /// A run that ends as it's told to, as `ProcessRunner`'s does, holds the stop up no longer than that.
    [Fact]
    public async Task StoppingEndsARunThatHeedsIt()
    {
        var cli = new FakeProcessRunner(answer: _ => Output(text: "gho_never"), delay: TimeSpan.FromMinutes(value: 5));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli, time: new TestClock(start: TestTimes.Reference));
        var cancellationToken = TestContext.Current.CancellationToken;

        var asking = provider.TokenAsync(cancellationToken: cancellationToken);
        await Waiting.Until(condition: () => cli.Runs.Count == 1);
        await provider.StopAsync().WaitAsync(timeout: Waiting.Limit, cancellationToken: cancellationToken);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(testCode: () => asking);
    }

    /// Stopped between runs, it forgets the token it kept: asked again, it runs `gh` again.
    [Fact]
    public async Task StoppingForgetsTheToken()
    {
        var cli = new FakeProcessRunner(answer: run => Output(text: run == 1 ? "gho_first" : "gho_second"));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli, time: new TestClock(start: TestTimes.Reference));
        var cancellationToken = TestContext.Current.CancellationToken;

        Assert.Equal(expected: "gho_first", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        await provider.StopAsync().WaitAsync(timeout: Waiting.Limit, cancellationToken: cancellationToken);
        Assert.Equal(expected: "gho_second", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.Equal(expected: 2, actual: cli.Runs.Count);
    }

    [Fact]
    public async Task NoCLIRunsNothing()
    {
        var cli = new FakeProcessRunner(answer: _ => Output(text: "gho_never"));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: []), runner: cli);

        var error = await Assert.ThrowsAsync<GitHubAuthException>(testCode: () => provider.TokenAsync(cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: GitHubAuthError.CliNotFound, actual: error.Error);
        Assert.Empty(collection: cli.Runs);
        Assert.Null(@object: provider.Program);
    }

    [Fact]
    public async Task ASignedOutCLIIsSignedOut()
    {
        var signedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login";
        var cli = new FakeProcessRunner(answer: _ => new ProcessResult(ExitCode: 1, Output: string.Empty, Error: signedOut));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli);

        var error = await Assert.ThrowsAsync<GitHubAuthException>(testCode: () => provider.TokenAsync(cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: GitHubAuthError.SignedOut(message: signedOut), actual: error.Error);
    }

    [Fact]
    public async Task AFailureIsNotKept()
    {
        var cli = new FakeProcessRunner(answer: run => run == 1 ? new ProcessResult(ExitCode: 1, Output: string.Empty, Error: "not logged in") : Output(text: "gho_after_sign_in"));
        var provider = new GitHubCLITokenProvider(locator: Locator(present: [InstalledCLI]), runner: cli, time: new TestClock(start: TestTimes.Reference));
        var cancellationToken = TestContext.Current.CancellationToken;

        await Assert.ThrowsAsync<GitHubAuthException>(testCode: () => provider.TokenAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: "gho_after_sign_in", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
    }

    /// If `gh` can't run, it may have been uninstalled or moved: it's looked for again next time, and not before.
    [Fact]
    public async Task LooksForTheCLIAgainWhenItCantRun()
    {
        var looked = 0;
        var locator = new GitHubCLILocator(environment: environment, exists: path =>
        {
            Interlocked.Increment(location: ref looked);
            return path == InstalledCLI;
        });
        var cli = new FakeProcessRunner(answer: run => run == 1 ? throw new Win32Exception(error: 2) : Output(text: run == 2 ? "gho_found" : "gho_again"));
        var provider = new GitHubCLITokenProvider(locator: locator, runner: cli, time: new TestClock(start: TestTimes.Reference));
        var cancellationToken = TestContext.Current.CancellationToken;

        var error = await Assert.ThrowsAsync<GitHubAuthException>(testCode: () => provider.TokenAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: GitHubAuthError.Failed(message: "Couldn't run the GitHub CLI."), actual: error.Error);
        Assert.Null(@object: provider.Program);
        var lookedOnce = looked;

        Assert.Equal(expected: "gho_found", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.True(condition: looked > lookedOnce);
        var lookedTwice = looked;

        provider.Invalidate();
        Assert.Equal(expected: "gho_again", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.Equal(expected: lookedTwice, actual: looked);
    }

    /// With `ProcessRunner`, and a made-up `gh.cmd` that answers with a token made of what it got: its arguments, and the
    /// variables that keep it quiet.
    [Fact]
    public async Task GetsATokenFromTheCLI()
    {
        using var folder = new TemporaryFolder();
        File.WriteAllText(
            path: folder.Combine("gh.cmd"),
            contents: "@echo tok-%1-%2-%3-%4-%GH_PROMPT_DISABLED%%GH_NO_UPDATE_NOTIFIER%%GH_SPINNER_DISABLED%%NO_COLOR%\r\n");
        var provider = new GitHubCLITokenProvider(
            locator: new GitHubCLILocator(environment: new Dictionary<string, string?> { ["PATH"] = folder.Path }), time: new TestClock(start: TestTimes.Reference));

        var token = await provider.TokenAsync(cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: "tok-auth-token---hostname-github.com-1111", actual: token.Value);
        Assert.Equal(expected: folder.Combine("gh.cmd"), actual: provider.Program);
    }

    /// A `gh.cmd` in a folder whose name has a percent sign, which `cmd.exe` would read as part of a command, can't run:
    /// `ProcessRunner` refuses it before anything starts. That's a problem the panel shows, and BriefBar looks again next
    /// time, rather than one that stops it reading GitHub.
    [Fact]
    public async Task ABatchFileThatCmdCantTakeIsAProblemToFix()
    {
        const string percent = @"C:\Tools\100%\gh.cmd";
        var overridden = new Dictionary<string, string?>(dictionary: environment, comparer: StringComparer.OrdinalIgnoreCase)
        {
            [GitHubCLILocator.OverrideVariable] = percent,
        };
        var provider = new GitHubCLITokenProvider(locator: new GitHubCLILocator(environment: overridden, exists: path => path == percent), runner: new ProcessRunner());

        var error = await Assert.ThrowsAsync<GitHubAuthException>(testCode: () => provider.TokenAsync(cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: GitHubAuthError.Failed(message: "Couldn't run the GitHub CLI."), actual: error.Error);
        Assert.IsType<ArgumentException>(@object: error.InnerException);
        Assert.Null(@object: provider.Program);
    }

    [Fact]
    public void LooksInThePathInWindowsOrder()
    {
        Assert.Equal(expected: @"C:\Tools\gh.exe", actual: Locator(present: [@"C:\Tools\gh.cmd", @"C:\Tools\gh.exe", InstalledCLI]).Locate());
        Assert.Equal(expected: @"C:\Tools\gh.cmd", actual: Locator(present: [@"C:\Tools\gh.cmd", InstalledCLI]).Locate());
    }

    /// `BRIEFBAR_GH` comes first, unless it isn't there, as on the Mac.
    [Fact]
    public void AnOverrideComesFirst()
    {
        var overridden = new Dictionary<string, string?>(dictionary: environment, comparer: StringComparer.OrdinalIgnoreCase)
        {
            [GitHubCLILocator.OverrideVariable] = @"D:\Custom\gh.exe",
        };
        Assert.Equal(expected: @"D:\Custom\gh.exe", actual: new GitHubCLILocator(environment: overridden, exists: _ => true).Locate());
        Assert.Equal(expected: InstalledCLI, actual: new GitHubCLILocator(environment: overridden, exists: path => path == InstalledCLI).Locate());
    }

    /// The Mac's `asksALoginShellLast`: on Windows, BriefBar may have started before the PATH had `gh`, as when it was just
    /// installed, so it looks where its installer puts it, for 64-bit Windows, then for the 32-bit CLI, then where WinGet
    /// links it.
    [Fact]
    public void LooksWhereTheInstallerPutsItWhenThePathDoesntHaveIt()
    {
        Assert.Equal(expected: [InstalledCLI, InstalledCLIFor32Bits, LinkedByWinGet], actual: Locator(present: []).UsualPlaces);
        Assert.Equal(expected: InstalledCLI, actual: Locator(present: [InstalledCLIFor32Bits, InstalledCLI, LinkedByWinGet]).Locate());
        Assert.Equal(expected: InstalledCLIFor32Bits, actual: Locator(present: [InstalledCLIFor32Bits, LinkedByWinGet]).Locate());
        Assert.Equal(expected: LinkedByWinGet, actual: Locator(present: [LinkedByWinGet]).Locate());
        Assert.Null(@object: Locator(present: []).Locate());
    }

    static GitHubCLILocator Locator(IReadOnlyList<string> present) => new(environment: environment, exists: present.Contains);

    static ProcessResult Output(string text) => new(ExitCode: 0, Output: text, Error: string.Empty);
}
