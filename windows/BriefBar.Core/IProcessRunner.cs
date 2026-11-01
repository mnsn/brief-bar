namespace BriefBar.Core;

/// Starts programs, as `ProcessRunner` does, so that tests can stand in for it. The Mac's `ProcessRunning`.
public interface IProcessRunner
{
    /// Runs `program` with `arguments`, without a window, and waits for it to end, at most `timeout`: then it and
    /// everything it started are ended, and it throws `TimeoutException`. Once it has ended, output that something it
    /// started holds open is waited for only briefly, and that is ended too. Cancelled, it's ended as at the time limit,
    /// and it throws `OperationCanceledException`; cancelled before it starts, it doesn't start. A program that isn't
    /// there throws `Win32Exception`. `environment` sets variables for it on top of BriefBar's own, or removes those set
    /// to null.
    Task<ProcessResult> RunAsync(
        string program,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string?> environment,
        TimeSpan timeout,
        CancellationToken cancellationToken);

    /// Starts `program` with `arguments` in a console window of its own, in `workingDirectory`, and leaves it running:
    /// Windows opens it in your default terminal, such as Windows Terminal. With `keepOpen`, a batch file's window stays
    /// open once it's done, so you can read what it said. A program that isn't there throws `Win32Exception`.
    void StartInConsole(string program, IReadOnlyList<string> arguments, string? workingDirectory, bool keepOpen);
}
