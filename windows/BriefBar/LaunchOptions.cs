namespace BriefBar;

/// How BriefBar was started: `--demo` shows every source's made-up data and reads nothing of yours, as on the Mac.
internal sealed record LaunchOptions(bool IsDemo)
{
    public static LaunchOptions Parse(IReadOnlyList<string> arguments) => new(
        IsDemo: arguments.Contains(value: "--demo", comparer: StringComparer.OrdinalIgnoreCase));
}
