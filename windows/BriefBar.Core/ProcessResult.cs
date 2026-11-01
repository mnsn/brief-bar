namespace BriefBar.Core;

/// How a program that `ProcessRunner` ran ended, and what it printed, as UTF-8.
public sealed record ProcessResult(int ExitCode, string Output, string Error);
