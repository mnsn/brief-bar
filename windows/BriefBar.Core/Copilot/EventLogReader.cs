namespace BriefBar.Core.Copilot;

/// Follows one session's append-only `events.jsonl`.
///
/// The first load reads only the file's tail, growing it until it reaches a `user.message` anchor; later updates read
/// only the appended bytes. A replaced, truncated or rewritten file triggers a fresh load. Each read opens the file with
/// full sharing and closes it at once (`SharedFile`). Not thread-safe: confine each reader to one thread at a time. The
/// Mac's `EventLogReader`.
public sealed class EventLogReader
{
    /// The last bytes before what's been read, to tell a rewritten file from one that's been appended to.
    const int BoundaryLength = 64;

    readonly IReadOnlyList<int> tailChunkSizes;
    readonly long maxIncrementalRead;
    long offset;
    long? fileId;
    long modified;
    byte[] boundary = [];
    byte[] carry = [];

    public EventLogReader(string path, IReadOnlyList<int>? tailChunkSizes = null, long maxIncrementalRead = 32 << 20)
    {
        ArgumentException.ThrowIfNullOrEmpty(argument: path);
        if (tailChunkSizes is { Count: 0 })
        {
            throw new ArgumentException(message: "There must be a chunk size.", paramName: nameof(tailChunkSizes));
        }
        Path = path;
        this.tailChunkSizes = tailChunkSizes ?? DefaultTailChunkSizes;
        this.maxIncrementalRead = maxIncrementalRead;
    }

    public static IReadOnlyList<int> DefaultTailChunkSizes { get; } = [512 << 10, 4 << 20, 16 << 20];

    public string Path { get; }

    /// What the log says so far. A new state replaces it on every change, so one given out never changes.
    public SessionLogState State { get; private set; } = new();

    public bool IsLoaded { get; private set; }

    /// Catches up with the file. Returns true when what it says changed.
    public bool Update()
    {
        var previousState = State;
        var wasLoaded = IsLoaded;
        // A file that went away keeps its last known state; the session list decides what shows.
        if (FileStamp.Of(path: Path) is not { } info)
        {
            return false;
        }
        if (!IsLoaded || info.Id != fileId || info.Size < offset || info.Size - offset > maxIncrementalRead)
        {
            LoadTail(info: info);
        }
        else if ((info.Size > offset || info.Modified != modified) && !ReadAppended(info: info))
        {
            LoadTail(info: info);
        }
        return !State.Equals(other: previousState) || IsLoaded != wasLoaded;
    }

    /// Calls `body` for each complete line of `data` and returns the partial line it ends with, if any.
    public static byte[] ForEachLine(ReadOnlySpan<byte> data, bool skipFirstPartial, LogLineAction body)
    {
        ArgumentNullException.ThrowIfNull(argument: body);
        var start = 0;
        if (skipFirstPartial)
        {
            var first = data.IndexOf(value: (byte)'\n');
            if (first < 0)
            {
                return [];
            }
            start = first + 1;
        }
        while (start < data.Length)
        {
            var newline = data[start..].IndexOf(value: (byte)'\n');
            if (newline < 0)
            {
                break;
            }
            if (newline > 0)
            {
                body(line: data.Slice(start: start, length: newline));
            }
            start += newline + 1;
        }
        return start < data.Length ? data[start..].ToArray() : [];
    }

    void LoadTail(FileStamp info)
    {
        State = new SessionLogState();
        carry = [];
        boundary = [];
        offset = 0;
        fileId = info.Id;
        modified = info.Modified;
        IsLoaded = true;
        var size = info.Size;
        if (size <= 0)
        {
            return;
        }

        for (var attempt = 0; attempt < tailChunkSizes.Count; attempt++)
        {
            var chunkSize = tailChunkSizes[attempt];
            var start = size > chunkSize ? size - chunkSize : 0;
            // One extra byte, to tell whether `start` already sits on a line's start.
            var readFrom = start > 0 ? start - 1 : 0;
            if (SharedFile.Read(path: Path, start: readFrom, end: size) is not { } data)
            {
                IsLoaded = false;
                return;
            }
            var events = new List<LogEvent>();
            var remainder = ForEachLine(data: data, skipFirstPartial: readFrom > 0, body: line =>
            {
                if (EventLineParser.Parse(raw: line) is { } parsed)
                {
                    events.Add(item: parsed);
                }
            });
            var isLastAttempt = attempt == tailChunkSizes.Count - 1;
            if (start == 0 || isLastAttempt || events.Exists(match: parsed => parsed.Kind.IsAnchor))
            {
                var fresh = new SessionLogState();
                fresh.Apply(events: events);
                State = fresh;
                carry = remainder;
                offset = readFrom + data.Length;
                boundary = data[Math.Max(val1: 0, val2: data.Length - BoundaryLength)..];
                return;
            }
        }
    }

    /// Reads what was appended since the last update. Returns false if the bytes before the old end changed, which means
    /// the file was rewritten in place. A failed read changes nothing, and is tried again on the next update.
    bool ReadAppended(FileStamp info)
    {
        var start = offset - boundary.Length;
        if (SharedFile.Read(path: Path, start: start, end: info.Size) is not { } data)
        {
            return true;
        }
        if (data.Length < boundary.Length || !data.AsSpan(start: 0, length: boundary.Length).SequenceEqual(other: boundary))
        {
            return false;
        }
        modified = info.Modified;
        if (data.Length <= boundary.Length)
        {
            return true;
        }

        offset = start + data.Length;
        var buffer = new byte[carry.Length + data.Length - boundary.Length];
        carry.CopyTo(array: buffer, index: 0);
        data.AsSpan(start: boundary.Length).CopyTo(destination: buffer.AsSpan(start: carry.Length));
        boundary = data[Math.Max(val1: 0, val2: data.Length - BoundaryLength)..];
        var next = State.Clone();
        carry = ForEachLine(data: buffer, skipFirstPartial: false, body: line =>
        {
            if (EventLineParser.Parse(raw: line) is { } parsed)
            {
                next.Apply(logEvent: parsed);
            }
        });
        State = next;
        return true;
    }
}
