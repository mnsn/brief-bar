namespace BriefBar.Core.Tests;

/// A run that `FakeProcessRunner` was asked for: the program, its arguments, the variables it sets, and its time limit.
internal sealed record FakeProcessRun(string Program, IReadOnlyList<string> Arguments, IReadOnlyDictionary<string, string?> Environment, TimeSpan Timeout);
