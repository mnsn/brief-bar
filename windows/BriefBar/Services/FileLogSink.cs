using BriefBar.Core.Logging;

namespace BriefBar.Services;

/// The log on disk: `%LOCALAPPDATA%\BriefBar\Logs\BriefBar.log`, kept under 1 MB, with two older files beside it. It
/// holds what `LogLine` lets through: counts, states and errors, never content. A line it can't write, as on a full
/// disk, is dropped, and the next line it writes says how many were; the log never stops BriefBar.
internal sealed class FileLogSink : ILogSink
{
    const long MaxBytes = 1024 * 1024;
    const int OlderFiles = 2;

    readonly Lock gate = new();
    readonly string folder;
    int dropped;

    FileLogSink(string folder)
    {
        this.folder = folder;
    }

    public string FilePath => Path.Combine(path1: folder, path2: "BriefBar.log");

    /// The log in the user's local application data, its folder made if it isn't there.
    public static FileLogSink Open()
    {
        var folder = Path.Combine(
            path1: Environment.GetFolderPath(folder: Environment.SpecialFolder.LocalApplicationData),
            path2: "BriefBar",
            path3: "Logs");
        Directory.CreateDirectory(path: folder);
        return new FileLogSink(folder: folder);
    }

    public void Write(string line)
    {
        lock (gate)
        {
            try
            {
                RollIfFull();
                var lines = dropped > 0 ? [$"({dropped} log lines couldn't be written)", line] : new[] { line };
                File.AppendAllLines(path: FilePath, contents: lines);
                dropped = 0;
            }
            catch (IOException)
            {
                dropped++;
            }
            catch (UnauthorizedAccessException)
            {
                dropped++;
            }
        }
    }

    /// Moves a full log aside, as BriefBar.1.log, and BriefBar.1.log to BriefBar.2.log.
    void RollIfFull()
    {
        var current = new FileInfo(fileName: FilePath);
        if (!current.Exists || current.Length < MaxBytes)
        {
            return;
        }
        for (var index = OlderFiles; index >= 1; index--)
        {
            var older = Path.Combine(path1: folder, path2: $"BriefBar.{index}.log");
            var newer = index == 1 ? FilePath : Path.Combine(path1: folder, path2: $"BriefBar.{index - 1}.log");
            if (File.Exists(path: newer))
            {
                File.Move(sourceFileName: newer, destFileName: older, overwrite: true);
            }
        }
    }
}
