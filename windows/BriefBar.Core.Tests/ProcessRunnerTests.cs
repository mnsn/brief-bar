using System.ComponentModel;
using System.Diagnostics;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests;

/// `ProcessRunner` with real programs, Windows' own and made-up batch files, as the Mac's `ProcessRunnerTests` use
/// `/bin/sh`. A batch file that must still be running when it's ended has `ping` write to a file, which stays open, so that
/// nothing else can open it, for as long as `ping` runs.
public sealed class ProcessRunnerTests
{
    static readonly string system = Environment.GetFolderPath(folder: Environment.SpecialFolder.System);
    static readonly string cmd = Path.Combine(path1: system, path2: "cmd.exe");
    static readonly string powerShell = Path.Combine(paths: [system, "WindowsPowerShell", "v1.0", "powershell.exe"]);

    /// Longer than any of these programs takes, unless it's made to wait.
    static readonly TimeSpan enough = TimeSpan.FromSeconds(value: 30);

    static readonly Dictionary<string, string?> noVariables = [];

    /// What `cmd.exe` reads as commands, or as something else than text: what a batch file mustn't get. A line break at
    /// the end too, which a regular expression's `$` lets through.
    static readonly string[] commandText = ["a&b", "a|b", "%PATH%", "a^b", "a\"b", "a b", "<in", ">out", "!PATH!", "(a)", "a\nb", "account\n", @"tail\", ""];

    public static TheoryData<string> CommandText { get; } = new(values: commandText);

    /// The Mac's `runsAProgramAndCollectsItsOutput`, with text that isn't ASCII: `cmd.exe` writes in its console's code
    /// page, which `chcp` makes UTF-8 for the `cmd.exe`s that start after it.
    [Fact]
    public async Task RunsAProgramAndCollectsItsOutputAsUtf8()
    {
        var result = await new ProcessRunner().RunAsync(
            program: cmd,
            arguments: ["/d", "/c", "chcp 65001>nul& cmd /d /c echo Grüße ✓& cmd /d /c echo Größe>&2& exit /b 3"],
            environment: noVariables,
            timeout: enough,
            cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 3, actual: result.ExitCode);
        Assert.Equal(expected: "Grüße ✓\r\n", actual: result.Output);
        Assert.Equal(expected: "Größe\r\n", actual: result.Error);
    }

    /// A batch file runs in `cmd.exe`, as `BatchCommandLine` says, and gets its fixed arguments as they are.
    [Fact]
    public async Task RunsABatchFileInCmdWithItsArguments()
    {
        using var folder = new TemporaryFolder();
        var batchFile = folder.Combine("print arguments.cmd");
        // Its command line, then its arguments; delayed expansion prints the command line's quotes as text.
        File.WriteAllText(
            path: batchFile,
            contents: "@echo off\r\nchcp 65001>nul\r\nsetlocal EnableDelayedExpansion\r\necho(!CMDCMDLINE!\r\nendlocal\r\necho(%*\r\nexit /b 4\r\n");
        string[] arguments = ["account", "get-access-token", "--resource", "499b84ac-1321-427f-aa17-267ca6975798", "--output", "json", "C:/made-up/file.txt", "key=value"];

        var result = await new ProcessRunner().RunAsync(
            program: batchFile, arguments: arguments, environment: noVariables, timeout: enough, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: 4, actual: result.ExitCode);
        Assert.Equal(
            expected: "\"" + cmd + "\" " + ProcessRunner.BatchCommandLine(batchFile: batchFile, arguments: arguments, keepOpen: false) + "\r\n"
                + string.Join(separator: ' ', value: arguments) + "\r\n",
            actual: result.Output);
        Assert.Equal(expected: string.Empty, actual: result.Error);
    }

    /// Before anything starts, for a batch file named as Windows runs it, with dots or spaces after its name too.
    [Theory]
    [MemberData(memberName: nameof(CommandText))]
    public async Task RefusesWhatCmdWouldReadAsCommandsForABatchFile(string argument)
    {
        using var folder = new TemporaryFolder();
        var batchFile = folder.Combine("ran.cmd");
        File.WriteAllText(path: batchFile, contents: "@echo ran>\"%~dp0ran.txt\"\r\n");
        foreach (var program in new[] { batchFile, batchFile + ".", batchFile + " " })
        {
            Assert.Throws<ArgumentException>(testCode: () => ProcessRunner.BatchCommandLine(batchFile: program, arguments: ["account", argument], keepOpen: false));
            await Assert.ThrowsAsync<ArgumentException>(testCode: () => new ProcessRunner().RunAsync(
                program: program, arguments: ["account", argument], environment: noVariables, timeout: enough, cancellationToken: TestContext.Current.CancellationToken));
        }
        Assert.False(condition: File.Exists(path: folder.Combine("ran.txt")));
    }

    /// A program that isn't a batch file gets them as they are. Windows PowerShell prints the arguments it got after its
    /// own and its command, which takes the rest of the line as a comment.
    [Fact]
    public async Task GivesAnyArgumentsToAProgramThatIsntABatchFile()
    {
        string[] own = ["-NoProfile", "-NonInteractive", "-Command", "$a = [Environment]::GetCommandLineArgs(); for ($i = 5; $i -lt $a.Length; $i++) { [Console]::Out.WriteLine('[' + $a[$i] + ']') } #"];
        string[] printable = [.. commandText.Where(predicate: argument => !argument.Contains(value: '\n', comparisonType: StringComparison.Ordinal))];

        var result = await new ProcessRunner().RunAsync(
            program: powerShell, arguments: [.. own, .. printable], environment: noVariables, timeout: enough, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: 0, actual: result.ExitCode);
        Assert.Equal(expected: string.Concat(values: printable.Select(selector: argument => "[" + argument + "]\r\n")), actual: result.Output);
    }

    [Theory]
    [InlineData(@"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd", true)]
    [InlineData("az.CMD", true)]
    [InlineData(@"C:\Tools\build.bat", true)]
    [InlineData("build.Bat", true)]
    // Windows takes dots and spaces off the end of a file's name, and runs these as batch files too.
    [InlineData(@"C:\Tools\az.cmd.", true)]
    [InlineData(@"C:\Tools\az.cmd ", true)]
    [InlineData(@"C:\Tools\az.cmd. .", true)]
    [InlineData(@"C:\Windows\System32\cmd.exe", false)]
    [InlineData("az", false)]
    [InlineData("az.cmd.exe", false)]
    [InlineData("az.cmdx", false)]
    [InlineData(@"C:\Tools.cmd\az.exe", false)]
    public void TellsABatchFile(string program, bool isBatchFile) =>
        Assert.Equal(expected: isBatchFile, actual: ProcessRunner.IsBatchFile(program: program));

    [Fact]
    public async Task SetsAndRemovesVariables()
    {
        // One that BriefBar has, to remove.
        Assert.False(condition: string.IsNullOrEmpty(value: Environment.GetEnvironmentVariable(variable: "USERNAME")));
        using var folder = new TemporaryFolder();
        var batchFile = folder.Combine("variables.cmd");
        File.WriteAllText(path: batchFile, contents: "@echo [%BRIEFBAR_MADE_UP%]\r\n@echo [%COMPUTERNAME%]\r\n@echo [%USERNAME%]\r\n");

        var result = await new ProcessRunner().RunAsync(
            program: batchFile,
            arguments: [],
            environment: new Dictionary<string, string?> { ["BRIEFBAR_MADE_UP"] = "made-up value", ["COMPUTERNAME"] = "MADE-UP-PC", ["USERNAME"] = null },
            timeout: enough,
            cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: "[made-up value]\r\n[MADE-UP-PC]\r\n[]\r\n", actual: result.Output);
        // For it only.
        Assert.Null(@object: Environment.GetEnvironmentVariable(variable: "BRIEFBAR_MADE_UP"));
    }

    /// The Mac's `endsAProgramThatRunsTooLong`, and what it started. A busy machine may not have started `ping` before
    /// the time is up: that isn't what's tested, so it's tried again with twice the time.
    [Fact]
    public async Task EndsAProgramThatRunsTooLong()
    {
        foreach (var seconds in new[] { 1, 2, 4 })
        {
            using var folder = new TemporaryFolder();
            var held = folder.Combine("held.txt");
            var batchFile = WaitingBatchFile(folder: folder);
            var elapsed = Stopwatch.StartNew();
            await Assert.ThrowsAsync<TimeoutException>(testCode: () => new ProcessRunner().RunAsync(
                program: batchFile, arguments: [], environment: noVariables, timeout: TimeSpan.FromSeconds(value: seconds), cancellationToken: TestContext.Current.CancellationToken));
            Assert.True(condition: elapsed.Elapsed < TimeSpan.FromSeconds(value: seconds + 5), userMessage: "it waited for ping");
            if (!HasStarted(output: held) && seconds < 4)
            {
                continue;
            }
            Assert.True(condition: HasStarted(output: held), userMessage: "ping didn't start");
            Assert.True(condition: await IsReleasedAsync(path: held), userMessage: "ping still runs");
            return;
        }
    }

    /// The Mac's `endsAProgramWhoseTaskIsCancelled`: rather than waiting for it, as it would the time limit.
    [Fact]
    public async Task EndsAProgramWhoseCallerCancels()
    {
        using var folder = new TemporaryFolder();
        var held = folder.Combine("held.txt");
        var batchFile = WaitingBatchFile(folder: folder);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(token: TestContext.Current.CancellationToken);
        var run = new ProcessRunner().RunAsync(program: batchFile, arguments: [], environment: noVariables, timeout: enough, cancellationToken: cancellation.Token);
        await WaitUntilAsync(what: "ping to start", condition: () => HasStarted(output: held));

        var elapsed = Stopwatch.StartNew();
        await cancellation.CancelAsync();
        var error = await Assert.ThrowsAnyAsync<OperationCanceledException>(testCode: () => run);

        Assert.Equal(expected: cancellation.Token, actual: error.CancellationToken);
        Assert.True(condition: elapsed.Elapsed < TimeSpan.FromSeconds(value: 5), userMessage: "it waited for ping");
        Assert.True(condition: await IsReleasedAsync(path: held), userMessage: "ping still runs");
    }

    /// The Mac's `doesntStartAProgramForATaskThatsCancelled`.
    [Fact]
    public async Task DoesntStartAProgramForACallerThatsCancelled()
    {
        using var folder = new TemporaryFolder();
        var batchFile = folder.Combine("ran.cmd");
        File.WriteAllText(path: batchFile, contents: "@echo ran>\"%~dp0ran.txt\"\r\n");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(testCode: () => new ProcessRunner().RunAsync(
            program: batchFile, arguments: [], environment: noVariables, timeout: enough, cancellationToken: new CancellationToken(canceled: true)));
        Assert.False(condition: File.Exists(path: folder.Combine("ran.txt")));
    }

    /// The Mac's `doesntWaitForWhatTheProgramLeftRunning`: the batch file ends at once, but the `ping` it started in the
    /// background has its output, which it inherited, open. What the batch file printed comes back, and `ping` is ended.
    [Fact]
    public async Task DoesntWaitForWhatTheProgramLeftRunning()
    {
        using var folder = new TemporaryFolder();
        var held = folder.Combine("held.txt");
        var batchFile = folder.Combine("leave.cmd");
        File.WriteAllText(path: batchFile, contents: "@start \"\" /b ping -n 30 127.0.0.1 >\"%~dp0held.txt\"\r\n@echo left\r\n");
        var elapsed = Stopwatch.StartNew();

        var result = await new ProcessRunner().RunAsync(
            program: batchFile, arguments: [], environment: noVariables, timeout: enough, cancellationToken: TestContext.Current.CancellationToken);

        Assert.True(condition: elapsed.Elapsed < TimeSpan.FromSeconds(value: 3), userMessage: "it waited for ping");
        Assert.Equal(expected: 0, actual: result.ExitCode);
        Assert.Equal(expected: "left\r\n", actual: result.Output);
        Assert.Equal(expected: string.Empty, actual: result.Error);
        Assert.True(condition: await IsReleasedAsync(path: held), userMessage: "ping still runs");
    }

    /// The Mac's `collectsLargeOutput`, from both at once.
    [Fact]
    public async Task CollectsLargeOutput()
    {
        using var folder = new TemporaryFolder();
        File.WriteAllText(path: folder.Combine("out.txt"), contents: new string(c: 'o', count: 1_000_000));
        File.WriteAllText(path: folder.Combine("error.txt"), contents: new string(c: 'e', count: 300_000));
        var batchFile = folder.Combine("print.cmd");
        File.WriteAllText(path: batchFile, contents: "@type \"%~dp0out.txt\"\r\n@type \"%~dp0error.txt\" 1>&2\r\n");

        var result = await new ProcessRunner().RunAsync(
            program: batchFile, arguments: [], environment: noVariables, timeout: enough, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: 0, actual: result.ExitCode);
        Assert.Equal(expected: new string(c: 'o', count: 1_000_000), actual: result.Output);
        Assert.Equal(expected: new string(c: 'e', count: 300_000), actual: result.Error);
    }

    /// The Mac's `reportsAProgramThatCantRun`, whether it would run itself or in `cmd.exe`, so that what runs it can tell
    /// that it's gone, as the Azure CLI's sign-in does to look for it again.
    [Fact]
    public async Task ReportsAProgramThatCantRun()
    {
        using var folder = new TemporaryFolder();
        foreach (var program in new[] { folder.Combine("missing.exe"), folder.Combine("missing.cmd") })
        {
            await Assert.ThrowsAsync<Win32Exception>(testCode: () => new ProcessRunner().RunAsync(
                program: program, arguments: [], environment: noVariables, timeout: enough, cancellationToken: TestContext.Current.CancellationToken));
        }
    }

    /// A batch file that runs `ping` for half a minute, its output in `held.txt`, in `folder`.
    static string WaitingBatchFile(TemporaryFolder folder)
    {
        var batchFile = folder.Combine("wait.cmd");
        File.WriteAllText(path: batchFile, contents: "@ping -n 30 127.0.0.1 >\"%~dp0held.txt\"\r\n");
        return batchFile;
    }

    /// Whether `ping` has started writing to `output`.
    static bool HasStarted(string output) => File.Exists(path: output) && new FileInfo(fileName: output).Length > 0;

    /// Whether nothing has `path` open within two seconds, as once what wrote it is gone.
    static async Task<bool> IsReleasedAsync(string path)
    {
        Assert.True(condition: File.Exists(path: path));
        for (var attempt = 0; attempt < 100; attempt++)
        {
            try
            {
                using var file = new FileStream(path: path, mode: FileMode.Open, access: FileAccess.ReadWrite, share: FileShare.None);
                return true;
            }
            catch (IOException)
            {
                await Task.Delay(millisecondsDelay: 20, cancellationToken: TestContext.Current.CancellationToken);
            }
        }
        return false;
    }

    static async Task WaitUntilAsync(string what, Func<bool> condition)
    {
        var waited = Stopwatch.StartNew();
        while (!condition())
        {
            Assert.True(condition: waited.Elapsed < TimeSpan.FromSeconds(value: 10), userMessage: "Timed out waiting for " + what);
            await Task.Delay(millisecondsDelay: 20, cancellationToken: TestContext.Current.CancellationToken);
        }
    }
}
