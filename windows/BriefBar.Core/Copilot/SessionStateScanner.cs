using System.Globalization;
using System.Text;

namespace BriefBar.Core.Copilot;

/// Fallback session discovery straight from `session-state`, used only while the app's database has never been
/// readable: the sessions whose event log changed recently. The Mac's `SessionStateScanner`.
public static class SessionStateScanner
{
    /// The most of a `workspace.yaml` that's read.
    const int MaxWorkspaceBytes = 1 << 20;

    public static List<SessionMeta> RecentSessions(CopilotPaths paths, DateTimeOffset now, TimeSpan? maxAge = null)
    {
        ArgumentNullException.ThrowIfNull(argument: paths);
        var age = maxAge ?? TimeSpan.FromDays(value: 1);
        IEnumerable<DirectoryInfo> directories;
        try
        {
            directories = new DirectoryInfo(path: paths.SessionState).EnumerateDirectories().ToList();
        }
        catch (IOException)
        {
            return [];
        }
        catch (UnauthorizedAccessException)
        {
            return [];
        }

        var sessions = new List<SessionMeta>();
        foreach (var directory in directories)
        {
            if (directory.Name.StartsWith(value: '.') || (directory.Attributes & FileAttributes.Hidden) != 0
                || FileStamp.Of(path: Path.Combine(path1: directory.FullName, path2: "events.jsonl")) is not { } events)
            {
                continue;
            }
            var modified = new DateTimeOffset(ticks: events.Modified, offset: TimeSpan.Zero);
            if (now - modified > age)
            {
                continue;
            }
            var id = directory.Name;
            sessions.Add(item: new SessionMeta
            {
                Id = id,
                Name = WorkspaceName(directory: directory.FullName) ?? "Session " + id[..Math.Min(val1: 8, val2: id.Length)],
                SessionType = "unknown",
                IsRunning = null,
                UpdatedAt = modified,
            });
        }
        return sessions;
    }

    /// The folder a session works in, as the `cwd` in its folder's `workspace.yaml` says: null when it doesn't say, or
    /// names a folder that isn't a whole path, or isn't there anymore, such as a worktree that was removed.
    public static string? WorkingFolder(string directory)
    {
        ArgumentNullException.ThrowIfNull(argument: directory);
        var folder = WorkspaceValue(directory: directory, key: "cwd");
        return folder is not null && Path.IsPathFullyQualified(path: folder) && Directory.Exists(path: folder) ? folder : null;
    }
    /// The `name` in a session folder's `workspace.yaml`, on one line; null when there's none.
    internal static string? WorkspaceName(string directory)
    {
        // A name in double quotes can have line breaks, written `\n`.
        var name = WorkspaceValue(directory: directory, key: "name");
        return name is null ? null : PlainText.SingleLine(text: name) is { Length: > 0 } single ? single : null;
    }


    /// One of the top-level values in a session's `workspace.yaml`, such as its `name`, or its `cwd`, the folder it works
    /// in, as YAML reads it (`Scalar`); null when it isn't there or is empty.
    public static string? Value(string key, string workspaceText)
    {
        ArgumentNullException.ThrowIfNull(argument: workspaceText);
        foreach (var line in workspaceText.Split(separator: '\n', options: StringSplitOptions.RemoveEmptyEntries))
        {
            if (!line.StartsWith(value: key + ":", comparisonType: StringComparison.Ordinal))
            {
                continue;
            }
            // Spaces and tabs around it, and a carriage return that ends a line written on Windows.
            var value = Scalar(text: line[(key.Length + 1)..].Trim(trimChars: [' ', '\t', '\r']));
            return value.Length == 0 ? null : value;
        }
        return null;
    }


    /// A value on one line, without its quotes: in single quotes, `''` is a quote; in double quotes, `\` starts an
    /// escape, such as `\"`, `\\`, `\n` or `\u00e9`. One that isn't quoted is as it is.
    internal static string Scalar(string text)
    {
        if (text.Length < 2 || text[0] is not ('"' or '\'') || text[^1] != text[0])
        {
            return text;
        }
        var inner = text[1..^1];
        if (text[0] == '\'')
        {
            return inner.Replace(oldValue: "''", newValue: "'", comparisonType: StringComparison.Ordinal);
        }
        var runes = inner.EnumerateRunes().ToList();
        var result = new StringBuilder();
        var index = 0;
        while (index < runes.Count)
        {
            var rune = runes[index];
            index++;
            if (rune.Value != '\\' || index >= runes.Count)
            {
                result.Append(value: rune.ToString());
                continue;
            }
            var escape = runes[index];
            index++;
            switch (escape.Value)
            {
                case 'n':
                    result.Append(value: '\n');
                    break;
                case 't':
                    result.Append(value: '\t');
                    break;
                case 'r':
                    result.Append(value: '\r');
                    break;
                case '0':
                    result.Append(value: '\0');
                    break;
                case '"' or '\\' or '/' or ' ':
                    result.Append(value: escape.ToString());
                    break;
                case 'x' or 'u' or 'U':
                    var length = escape.Value == 'x' ? 2 : escape.Value == 'u' ? 4 : 8;
                    var end = Math.Min(val1: index + length, val2: runes.Count);
                    var digits = string.Concat(values: runes.Skip(count: index).Take(count: end - index).Select(selector: digit => digit.ToString()));
                    if (end - index == length
                        && uint.TryParse(s: digits, style: NumberStyles.AllowHexSpecifier, provider: CultureInfo.InvariantCulture, result: out var code)
                        && Rune.IsValid(value: code))
                    {
                        result.Append(value: new Rune(value: code).ToString());
                        index = end;
                    }
                    else
                    {
                        result.Append(value: rune.ToString()).Append(value: escape.ToString());
                    }
                    break;
                default:
                    result.Append(value: rune.ToString()).Append(value: escape.ToString());
                    break;
            }
        }
        return result.ToString();
    }

    /// A value, `key`, in a session folder's `workspace.yaml`; null when the file can't be read, or doesn't have it.
    static string? WorkspaceValue(string directory, string key)
    {
        var file = Path.Combine(path1: directory, path2: "workspace.yaml");
        return SharedFile.ReadAll(path: file, maxBytes: MaxWorkspaceBytes) is { } bytes
            ? Value(key: key, workspaceText: Encoding.UTF8.GetString(bytes: bytes))
            : null;
    }
}
