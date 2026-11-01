namespace BriefBar.Core.Tests;

/// What `FakeProcessRunner` was asked to start in a console window: the program, its arguments, its folder, and whether
/// a batch file's window stays open.
internal sealed record FakeConsole(string Program, IReadOnlyList<string> Arguments, string? WorkingDirectory, bool KeepOpen);
