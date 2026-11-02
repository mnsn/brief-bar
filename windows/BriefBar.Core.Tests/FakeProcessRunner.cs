namespace BriefBar.Core.Tests;

/// Stands in for `ProcessRunner`, as the Swift tests' `ProcessRunning` stubs do, and starts nothing: it notes every run it
/// was asked for, answering with what `answer` makes of the run's number, from 1, after `delay`, if any, so that callers
/// can overlap; and what it was asked to start in a console window.
internal sealed class FakeProcessRunner(Func<int, ProcessResult>? answer = null, TimeSpan? delay = null) : IProcessRunner
{
    readonly Lock gate = new();
    readonly List<FakeProcessRun> runs = [];
    readonly List<FakeConsole> consoles = [];
    Exception? failsToStart;

    public IReadOnlyList<FakeProcessRun> Runs
    {
        get
        {
            lock (gate)
            {
                return [.. runs];
            }
        }
    }

    /// What it was asked to start in a console window, in order.
    public IReadOnlyList<FakeConsole> Consoles
    {
        get
        {
            lock (gate)
            {
                return [.. consoles];
            }
        }
    }

    /// Runs each time it's asked to start something in a console window, before it notes it: as a terminal that takes a
    /// while to start.
    public Action? Starting { get; set; }

    public async Task<ProcessResult> RunAsync(
        string program,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string?> environment,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        int number;
        lock (gate)
        {
            runs.Add(item: new FakeProcessRun(
                Program: program,
                Arguments: [.. arguments],
                Environment: new Dictionary<string, string?>(collection: environment, comparer: StringComparer.Ordinal),
                Timeout: timeout));
            number = runs.Count;
        }
        if (answer is null)
        {
            throw new InvalidOperationException(message: "Nothing should run without a window here.");
        }
        if (delay is { } wait)
        {
            await Task.Delay(delay: wait, cancellationToken: cancellationToken);
        }
        return answer(arg: number);
    }

    public void StartInConsole(
        string program, IReadOnlyList<string> arguments, string? workingDirectory, IReadOnlyDictionary<string, string?> environment, bool keepOpen)
    {
        Starting?.Invoke();
        lock (gate)
        {
            if (failsToStart is { } failure)
            {
                throw failure;
            }
            consoles.Add(item: new FakeConsole(
                Program: program,
                Arguments: [.. arguments],
                WorkingDirectory: workingDirectory,
                Environment: new Dictionary<string, string?>(collection: environment, comparer: StringComparer.Ordinal),
                KeepOpen: keepOpen));
        }
    }

    /// Starting in a console window throws `failure` from now on, as Windows does for a program that isn't there.
    public void FailToStart(Exception failure)
    {
        lock (gate)
        {
            failsToStart = failure;
        }
    }
}
