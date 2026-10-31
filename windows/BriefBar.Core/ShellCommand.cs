namespace BriefBar.Core;

/// What a Windows shell command, as the registry keeps one for a link's scheme, runs.
public static class ShellCommand
{
    /// The program `command` runs: `C:\Apps\app.exe` in `"C:\Apps\app.exe" "%1"`, the quoted path, or everything up to
    /// the first space when it isn't quoted. Null for none.
    public static string? Program(string? command)
    {
        var text = command?.Trim();
        if (string.IsNullOrEmpty(value: text))
        {
            return null;
        }
        if (text[0] == '"')
        {
            var end = text.IndexOf(value: '"', startIndex: 1);
            var quoted = end < 0 ? null : text[1..end].Trim();
            return string.IsNullOrEmpty(value: quoted) ? null : quoted;
        }
        var space = text.IndexOf(value: ' ', comparisonType: StringComparison.Ordinal);
        return space < 0 ? text : text[..space];
    }
}
