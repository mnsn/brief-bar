namespace BriefBar.Core;

/// Reads another app's files without getting in its way: each read opens the file read-only, sharing reading, writing
/// and deleting with everyone, and closes it at once. Windows won't let an app replace or delete a file that another
/// process has open without sharing deletion, so BriefBar never holds one between reads.
public static class SharedFile
{
    /// The bytes from `start` up to `end`, fewer if the file is shorter now; null when it can't be read, as when it's
    /// gone.
    public static byte[]? Read(string path, long start, long end)
    {
        if (end <= start)
        {
            return [];
        }
        try
        {
            using var stream = Open(path: path);
            stream.Seek(offset: start, origin: SeekOrigin.Begin);
            var buffer = new byte[end - start];
            var read = stream.ReadAtLeast(buffer: buffer, minimumBytes: buffer.Length, throwOnEndOfStream: false);
            return read == buffer.Length ? buffer : buffer[..read];
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

    /// The whole file, if it's at most `maxBytes`; null when it's larger or can't be read.
    public static byte[]? ReadAll(string path, int maxBytes)
    {
        try
        {
            using var stream = Open(path: path);
            return ReadAll(stream: stream, maxBytes: maxBytes);
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

    /// All of `stream`, if it's at most `maxBytes`; null when it's larger. Its length is asked once: the app may write to
    /// the file as it's read, which sharing allows, and a second look could find it larger.
    internal static byte[]? ReadAll(Stream stream, int maxBytes)
    {
        ArgumentNullException.ThrowIfNull(argument: stream);
        var length = stream.Length;
        if (length > maxBytes)
        {
            return null;
        }
        var buffer = new byte[length];
        var read = stream.ReadAtLeast(buffer: buffer, minimumBytes: buffer.Length, throwOnEndOfStream: false);
        return read == buffer.Length ? buffer : buffer[..read];
    }

    static FileStream Open(string path) => new(
        path: path,
        options: new FileStreamOptions
        {
            Mode = FileMode.Open,
            Access = FileAccess.Read,
            Share = FileShare.ReadWrite | FileShare.Delete,
            BufferSize = 0,
        });
}
