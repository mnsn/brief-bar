namespace BriefBar.Core.Copilot;

/// What opening a session in a terminal asks of Windows, which BriefBar.Core can't do itself: bring up the terminal that
/// the program with a process ID runs in, and tell you what went wrong, in a sentence and in what to do about it. Called
/// on any thread.
public sealed record CLISessionShell(Action<int> ShowTerminalOf, Action<string, string> Say);
