namespace BriefBar.Core.Tests;

/// Stands in for `ProcessRunner`, as the Swift tests' `ProcessRunning` stubs do, and starts nothing: it notes every run it
/// was asked for, answering with what `answer` makes of the run's number, from 1, and what it was asked to start in a
/// console window.
internal sealed class FakeProcessRunner(Func<int, ProcessResult>? answer = null) : IProcessRunner
{
    readonly Lock gate = new();
    readonly List<FakeProcessRun> runs = [];
    readonly List<FakeConsole> consoles = [];

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

    public Task<ProcessResult> RunAsync(
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
        return answer is null
            ? throw new InvalidOperationException(message: "Nothing should run without a window here.")
            : Task.FromResult(result: answer(arg: number));
    }

    public void StartInConsole(string program, IReadOnlyList<string> arguments, string? workingDirectory, bool keepOpen)
    {
        lock (gate)
        {
            consoles.Add(item: new FakeConsole(Program: program, Arguments: [.. arguments], WorkingDirectory: workingDirectory, KeepOpen: keepOpen));
        }
    }
}
