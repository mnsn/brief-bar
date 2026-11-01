using System.Globalization;

namespace BriefBar.Core.Copilot;

/// Whether a program has a session open. The Copilot app's runtime keeps `inuse.<pid>.lock` in a session's folder while it
/// has the session loaded, with its history in memory, and so does the Copilot CLI, from the moment it opens a session in
/// a terminal until it quits, on Windows as on the Mac: a turn another program runs in the session meanwhile is one the
/// first never sees, and the session's history forks. The Mac's `SessionLock`.
public static class SessionLock
{
    /// How much later than a lock was written its program may have started and still be the one that wrote it: start
    /// times and write times are both precise to well under a second.
    static readonly TimeSpan clockSlack = TimeSpan.FromSeconds(value: 1);

    /// The process ID of the running program that holds the session in `folder`, as Windows tells of its programs
    /// (`ProcessRunner.IsRunning`, `ProcessRunner.StartTime`); null when none does.
    public static int? Holder(string folder) =>
        Holder(folder: folder, isRunning: ProcessRunner.IsRunning, startTime: ProcessRunner.StartTime);

    /// The process ID of the running program that holds the session in `folder`; null when none does. A lock left by a
    /// program that's gone, as after the CLI quits, doesn't count; nor does one whose process ID a program that started
    /// after the lock was written has now, since Windows reuses them. One whose start time Windows won't tell counts.
    public static int? Holder(string folder, Func<int, bool> isRunning, Func<int, DateTimeOffset?> startTime)
    {
        ArgumentNullException.ThrowIfNull(argument: folder);
        ArgumentNullException.ThrowIfNull(argument: isRunning);
        ArgumentNullException.ThrowIfNull(argument: startTime);
        foreach (var (pid, written) in Holders(folder: folder))
        {
            if (!isRunning(arg: pid))
            {
                continue;
            }
            if (written is not { } wrote || startTime(arg: pid) is not { } started || started <= wrote + clockSlack)
            {
                return pid;
            }
        }
        return null;
    }

    /// 123, from `inuse.123.lock`; null for any other name.
    public static int? PidInLockNamed(string name)
    {
        ArgumentNullException.ThrowIfNull(argument: name);
        const string prefix = "inuse.";
        const string suffix = ".lock";
        if (!name.StartsWith(value: prefix, comparisonType: StringComparison.Ordinal) || !name.EndsWith(value: suffix, comparisonType: StringComparison.Ordinal)
            || name.Length <= prefix.Length + suffix.Length)
        {
            return null;
        }
        var digits = name[prefix.Length..^suffix.Length];
        return digits.Length <= 10 && digits.All(predicate: char.IsAsciiDigit)
            && int.TryParse(s: digits, style: NumberStyles.None, provider: CultureInfo.InvariantCulture, result: out var pid) && pid > 0
                ? pid
                : null;
    }

    /// The programs that left a lock in the folder, by their process IDs, with when each lock was written: none when the
    /// folder isn't there, or can't be read.
    static List<(int Pid, DateTimeOffset? Written)> Holders(string folder)
    {
        try
        {
            return new DirectoryInfo(path: folder).EnumerateFiles(searchPattern: "inuse.*.lock")
                .Select(selector: file => (Pid: PidInLockNamed(name: file.Name), Written: Written(file: file)))
                .Where(predicate: lockFile => lockFile.Pid is not null)
                .Select(selector: lockFile => (lockFile.Pid!.Value, lockFile.Written))
                .ToList();
        }
        catch (DirectoryNotFoundException)
        {
            return [];
        }
        catch (UnauthorizedAccessException)
        {
            return [];
        }
        catch (IOException)
        {
            return [];
        }
    }

    /// When `file` was last written, or null when it's gone meanwhile.
    static DateTimeOffset? Written(FileInfo file)
    {
        file.Refresh();
        return file.Exists ? new DateTimeOffset(dateTime: file.LastWriteTimeUtc, offset: TimeSpan.Zero) : null;
    }
}
