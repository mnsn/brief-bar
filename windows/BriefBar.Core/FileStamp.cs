namespace BriefBar.Core;

/// A file's identity, size and modification time, to tell when a path points at a new file or a file has grown. The
/// Mac's `FileInfo`, renamed, as .NET has its own. .NET doesn't give a file's index on Windows, so its identity is when
/// it was created, which tells most replaced files apart; `EventLogReader` also checks the bytes it read before.
public readonly record struct FileStamp(long Id, long Size, long Modified)
{
    /// The file at `path`, or null when there's no file there, such as a folder, or it can't be looked at.
    public static FileStamp? Of(string path)
    {
        try
        {
            var info = new FileInfo(fileName: path);
            return info.Exists
                ? new FileStamp(Id: info.CreationTimeUtc.Ticks, Size: info.Length, Modified: info.LastWriteTimeUtc.Ticks)
                : null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }
}
