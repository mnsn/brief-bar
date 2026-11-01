using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using BriefBar.Core.Logging;

namespace BriefBar.Core;

/// The only place BriefBar starts programs, such as the Azure CLI for a sign-in's token, or looks into those running, such
/// as the Copilot CLI that has a session open, so that what it starts, and how, is checked in one place
/// (`BoundaryTests`). The Mac's `ProcessRunner` and `DetachedProgram`.
///
/// A batch file, such as `az.cmd`, runs in `cmd.exe`, which reads its whole command line as commands: nothing of yours may
/// reach it. So a batch file gets only fixed arguments, made of letters, digits and `-._:/=`, or this throws; and `cmd.exe`
/// runs it without AutoRun commands or delayed expansion, the batch file's path quoted.
public sealed partial class ProcessRunner : IProcessRunner
{
    /// Windows' `ERROR_FILE_NOT_FOUND`.
    const int FileNotFound = 2;

    /// How long a program's output may stay open once it has ended, held by something it left running.
    static readonly TimeSpan outputGrace = TimeSpan.FromMilliseconds(value: 500);

    public async Task<ProcessResult> RunAsync(
        string program,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string?> environment,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(argument: environment);
        var info = StartInfo(program: program, arguments: arguments, keepOpen: false);
        info.CreateNoWindow = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        info.RedirectStandardInput = true;
        Apply(environment: environment, info: info);
        using var process = new Process { StartInfo = info };
        // Cancelled before it starts, it doesn't start at all.
        cancellationToken.ThrowIfCancellationRequested();
        process.Start();
        // It reads nothing from BriefBar: a program that asks for input gets none, rather than waiting for it.
        process.StandardInput.Close();
        using var output = new MemoryStream();
        using var error = new MemoryStream();
        using var reading = new CancellationTokenSource();
        var read = Task.WhenAll(
            Collect(stream: process.StandardOutput.BaseStream, sink: output, cancellationToken: reading.Token),
            Collect(stream: process.StandardError.BaseStream, sink: error, cancellationToken: reading.Token));
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token: cancellationToken);
        deadline.CancelAfter(delay: timeout);
        try
        {
            await process.WaitForExitAsync(cancellationToken: deadline.Token).ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (OperationCanceledException)
        {
            EndTree(process: process);
            await StopReadingAsync(read: read, reading: reading).ConfigureAwait(continueOnCapturedContext: false);
            cancellationToken.ThrowIfCancellationRequested();
            throw new TimeoutException(message: "The program didn't end in time.");
        }
        if (await Task.WhenAny(task1: read, task2: Task.Delay(delay: outputGrace, cancellationToken: CancellationToken.None)).ConfigureAwait(continueOnCapturedContext: false) != read)
        {
            // Something it started holds its output open: what it printed itself has arrived by now, and what it left
            // running is ended, as on the Mac.
            EndTree(process: process);
            await StopReadingAsync(read: read, reading: reading).ConfigureAwait(continueOnCapturedContext: false);
        }
        else
        {
            // A read that failed, rather than reaching the end, is an error, not an empty answer.
            await read.ConfigureAwait(continueOnCapturedContext: false);
        }
        cancellationToken.ThrowIfCancellationRequested();
        return new ProcessResult(ExitCode: process.ExitCode, Output: Text(sink: output), Error: Text(sink: error));
    }

    public void StartInConsole(
        string program, IReadOnlyList<string> arguments, string? workingDirectory, IReadOnlyDictionary<string, string?> environment, bool keepOpen)
    {
        ArgumentNullException.ThrowIfNull(argument: environment);
        var info = StartInfo(program: program, arguments: arguments, keepOpen: keepOpen);
        // BriefBar has no console, so the program gets a window of its own, in the terminal Windows opens consoles in.
        info.CreateNoWindow = false;
        Apply(environment: environment, info: info);
        if (workingDirectory is not null)
        {
            info.WorkingDirectory = workingDirectory;
        }
        using var process = Process.Start(startInfo: info)
            ?? throw new InvalidOperationException(message: "Windows didn't start the program.");
    }

    /// Whether a program with process ID `pid` is running, as Windows lists its programs. One BriefBar may not look into,
    /// such as one run as administrator, is running.
    public static bool IsRunning(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(processId: pid);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            // None has that ID.
            return false;
        }
        catch (InvalidOperationException)
        {
            // It ended meanwhile.
            return false;
        }
        catch (Win32Exception)
        {
            // Listed, but not BriefBar's to look into.
            return true;
        }
    }

    /// When the program with process ID `pid` started, or null when none with that ID runs, or Windows won't say.
    public static DateTimeOffset? StartTime(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(processId: pid);
            return new DateTimeOffset(dateTime: process.StartTime);
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or Win32Exception)
        {
            return null;
        }
    }

    /// Whether `program` is a batch file, which `cmd.exe` runs: by its extension, without the dots and spaces that Windows
    /// takes off the end of a file's name, as Windows runs `az.cmd.` and `az.cmd ` in `cmd.exe` too.
    public static bool IsBatchFile(string program)
    {
        ArgumentNullException.ThrowIfNull(argument: program);
        var extension = Path.GetExtension(path: program.TrimEnd(trimChars: ['.', ' ']));
        return string.Equals(a: extension, b: ".cmd", comparisonType: StringComparison.OrdinalIgnoreCase)
            || string.Equals(a: extension, b: ".bat", comparisonType: StringComparison.OrdinalIgnoreCase);
    }

    /// `cmd.exe`'s arguments that run `batchFile` with `arguments`, which must be fixed words: `/d` without AutoRun
    /// commands, `/v:off` without delayed expansion, and `/s` so that the outer quotes are the only ones it takes off.
    public static string BatchCommandLine(string batchFile, IReadOnlyList<string> arguments, bool keepOpen)
    {
        ArgumentException.ThrowIfNullOrEmpty(argument: batchFile);
        ArgumentNullException.ThrowIfNull(argument: arguments);
        if (batchFile.IndexOfAny(anyOf: ['"', '%', '\r', '\n']) >= 0)
        {
            throw new ArgumentException(message: "A batch file's path can't hold quotes, percent signs or line breaks.", paramName: nameof(batchFile));
        }
        foreach (var argument in arguments)
        {
            if (!FixedWord().IsMatch(input: argument))
            {
                throw new ArgumentException(message: "A batch file takes only fixed arguments.", paramName: nameof(arguments));
            }
        }
        var command = "\"" + batchFile + "\"" + string.Concat(values: arguments.Select(selector: argument => " " + argument));
        return (keepOpen ? "/d /v:off /s /k \"" : "/d /v:off /s /c \"") + command + "\"";
    }

    /// Letters, digits and `-._:/=`, to the very end (`\z`, where `$` would let a final line break through): nothing
    /// `cmd.exe` reads as anything but text.
    [GeneratedRegex(pattern: @"^[A-Za-z0-9._:/=-]+\z", options: RegexOptions.CultureInvariant)]
    private static partial Regex FixedWord();

    /// Sets `environment`'s variables for the program on top of BriefBar's own, and removes those set to null.
    static void Apply(IReadOnlyDictionary<string, string?> environment, ProcessStartInfo info)
    {
        foreach (var (name, value) in environment)
        {
            if (value is null)
            {
                info.Environment.Remove(key: name);
            }
            else
            {
                info.Environment[name] = value;
            }
        }
    }

    static ProcessStartInfo StartInfo(string program, IReadOnlyList<string> arguments, bool keepOpen)
    {
        ArgumentException.ThrowIfNullOrEmpty(argument: program);
        ArgumentNullException.ThrowIfNull(argument: arguments);
        if (IsBatchFile(program: program))
        {
            var commandLine = BatchCommandLine(batchFile: program, arguments: arguments, keepOpen: keepOpen);
            // `cmd.exe` would start without it, and only say so in what it prints: it fails as a program that isn't there
            // does, so that what runs it can tell, as the Azure CLI's sign-in does to look for it again.
            if (Path.IsPathFullyQualified(path: program) && !File.Exists(path: program))
            {
                throw new Win32Exception(error: FileNotFound);
            }
            return new ProcessStartInfo
            {
                FileName = Path.Combine(path1: Environment.GetFolderPath(folder: Environment.SpecialFolder.System), path2: "cmd.exe"),
                Arguments = commandLine,
                UseShellExecute = false,
            };
        }
        var info = new ProcessStartInfo { FileName = program, UseShellExecute = false };
        foreach (var argument in arguments)
        {
            info.ArgumentList.Add(item: argument);
        }
        return info;
    }

    /// Ends `process` and everything it started, such as the Python that `az.cmd` runs: all of it at the time limit, or what
    /// it left running once it ended. One that has ended meanwhile has nothing left to end. One that can't be ended is
    /// logged rather than thrown: the caller still gets the time limit's error, or what the program printed, which is its
    /// whole answer.
    static void EndTree(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) when (process.HasExited)
        {
        }
        catch (AggregateException error)
        {
            Log.Write(error: error, context: $"process: couldn't end all of a program, or what it left running");
        }
    }

    /// Copies `stream` into `sink` as it comes, so that what arrived is there even if the stream never ends.
    static async Task Collect(Stream stream, MemoryStream sink, CancellationToken cancellationToken)
    {
        var buffer = new byte[4_096];
        while (true)
        {
            var count = await stream.ReadAsync(buffer: buffer.AsMemory(), cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            if (count == 0)
            {
                return;
            }
            lock (sink)
            {
                sink.Write(buffer: buffer, offset: 0, count: count);
            }
        }
    }

    /// Stops waiting for output that something it left running holds open: the reads stop, or end with an error once the
    /// output closes, which is logged, as nothing waits for them anymore.
    static async Task StopReadingAsync(Task read, CancellationTokenSource reading)
    {
        await reading.CancelAsync().ConfigureAwait(continueOnCapturedContext: false);
        _ = read.ContinueWith(
            continuationAction: abandoned => Log.Write(error: abandoned.Exception!.GetBaseException(), context: $"process: output read after BriefBar stopped waiting for it"),
            cancellationToken: CancellationToken.None,
            continuationOptions: TaskContinuationOptions.OnlyOnFaulted,
            scheduler: TaskScheduler.Default);
    }

    static string Text(MemoryStream sink)
    {
        lock (sink)
        {
            return Encoding.UTF8.GetString(bytes: sink.GetBuffer(), index: 0, count: (int)sink.Length);
        }
    }
}
