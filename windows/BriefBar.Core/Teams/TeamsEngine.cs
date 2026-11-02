using BriefBar.Core.Logging;

namespace BriefBar.Core.Teams;

/// Watches Teams' IndexedDB folders, and hands over each chat as it is, with the messages of those that may be unread,
/// whenever they change. The Mac's `ReadMarkerEngine`, which hands over read markers only.
///
/// LevelDB appends every write to its log, and Windows reports those writes as they happen (`FileSystemWatcher`), so a
/// write is read `reloadDelay` later, combining bursts, from where the last read stopped. A folder is read again from
/// scratch when its log is replaced or its databases change, and every `safetyInterval`, which also finds Teams' folders
/// once you sign in. Of Teams' message cache, it reads only the messages of the chats that may be unread, again when one
/// gets a message. A table that can't be read counts only once it has stayed so, unchanged, for `confirmationDelay`:
/// LevelDB writes a table where it'll stay, so one being written reads as broken until it's done.
///
/// All its state is guarded by one lock, and the handler it was made with is called with that lock held, one snapshot at
/// a time: the handler mustn't call the engine.
public sealed class TeamsEngine : ITeamsEngine, IDisposable
{
    /// LevelDB's own account of what it did, and its lock, say nothing about the data.
    static readonly HashSet<string> quietFiles = new(collection: ["LOG", "LOG.old", "LOCK"], comparer: StringComparer.OrdinalIgnoreCase);

    readonly Lock gate = new();
    readonly Action<TeamsSnapshot> onChange;
    readonly TimeSpan reloadDelay;
    readonly TimeSpan safetyInterval;
    readonly TimeSpan confirmationDelay;
    readonly TimeProvider time;
    readonly Dictionary<string, TeamsCacheFolder> folders = new(comparer: StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, FileSystemWatcher> watchers = new(comparer: StringComparer.OrdinalIgnoreCase);
    /// The messages read of each chat that may be unread, and the ID of its newest message then.
    readonly Dictionary<string, (long Newest, IReadOnlyList<TeamsMessage> Messages)> messages = new(comparer: StringComparer.Ordinal);
    /// Chats that may be unread that got a message since their messages were read.
    readonly HashSet<string> touched = new(comparer: StringComparer.Ordinal);
    /// Tables that couldn't be read, by path: as they were then, and since when.
    readonly Dictionary<string, (FileStamp? File, DateTimeOffset Since)> suspectTables = new(comparer: StringComparer.Ordinal);
    int unreadableFolders;
    int unreadableTables;
    bool found;
    bool failed;
    DateTimeOffset? readAt;
    TeamsSnapshot? lastPublished;
    Timer? readTimer;
    Timer? safetyTimer;
    Timer? confirmationTimer;
    bool readScheduled;
    bool confirmationScheduled;
    bool isActive;

    public TeamsEngine(
        TeamsCacheLocation location,
        Action<TeamsSnapshot> onChange,
        TimeSpan? reloadDelay = null,
        TimeSpan? safetyInterval = null,
        TimeSpan? confirmationDelay = null,
        TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: location);
        ArgumentNullException.ThrowIfNull(argument: onChange);
        Location = location;
        this.onChange = onChange;
        this.reloadDelay = reloadDelay ?? TimeSpan.FromMilliseconds(value: 500);
        this.safetyInterval = safetyInterval ?? TimeSpan.FromMinutes(value: 10);
        this.confirmationDelay = confirmationDelay ?? TimeSpan.FromSeconds(value: 5);
        this.time = time ?? TimeProvider.System;
    }

    public TeamsCacheLocation Location { get; }

    /// One read, without watching, for tests and checks: tables that can't be read count as such at once.
    public static TeamsSnapshot LoadOnce(TeamsCacheLocation location)
    {
        using var engine = new TeamsEngine(location: location, onChange: _ => { });
        lock (engine.gate)
        {
            engine.Rescan(confirmAtOnce: true);
            return engine.CurrentSnapshot();
        }
    }

    public void Start()
    {
        lock (gate)
        {
            if (isActive)
            {
                return;
            }
            isActive = true;
            readTimer = new Timer(callback: _ => Guarded(work: ReadTimerFired), state: null, dueTime: Timeout.Infinite, period: Timeout.Infinite);
            confirmationTimer = new Timer(callback: _ => Guarded(work: ConfirmationTimerFired), state: null, dueTime: Timeout.Infinite, period: Timeout.Infinite);
            Rescan(confirmAtOnce: false);
            Publish(force: true);
            safetyTimer = new Timer(callback: _ => Guarded(work: SafetyTimerFired), state: null, dueTime: safetyInterval, period: safetyInterval);
        }
    }

    public void Stop()
    {
        lock (gate)
        {
            isActive = false;
            foreach (var watcher in watchers.Values)
            {
                watcher.Dispose();
            }
            watchers.Clear();
            readTimer?.Dispose();
            readTimer = null;
            safetyTimer?.Dispose();
            safetyTimer = null;
            confirmationTimer?.Dispose();
            confirmationTimer = null;
            readScheduled = false;
            confirmationScheduled = false;
            folders.Clear();
            messages.Clear();
            touched.Clear();
            suspectTables.Clear();
            lastPublished = null;
        }
    }

    /// Reads what Teams wrote since the last read, as a panel opens, rather than waiting for the watcher; everything
    /// again when Teams' data wasn't found before, as when you've just signed in, or when it's needed.
    public void Refresh()
    {
        lock (gate)
        {
            if (!isActive)
            {
                return;
            }
            if (found)
            {
                ReadLogs();
            }
            else
            {
                Rescan(confirmAtOnce: false);
            }
            Publish(force: false);
        }
    }

    public void Dispose() => Stop();

    /// Reads every folder from scratch, and the messages of the chats that may be unread.
    void Rescan(bool confirmAtOnce)
    {
        var started = time.GetUtcNow();
        found = false;
        failed = false;
        unreadableFolders = 0;
        folders.Clear();
        foreach (var path in Location.Folders())
        {
            found = true;
            var folder = new TeamsCacheFolder(path: path);
            try
            {
                folder.Scan();
                folders[path] = folder;
            }
            catch (IOException)
            {
                unreadableFolders += 1;
            }
            catch (UnauthorizedAccessException)
            {
                unreadableFolders += 1;
            }
        }
        ConfirmUnreadableTables(confirmAtOnce: confirmAtOnce);
        if (isActive)
        {
            Watch();
        }
        // A chat's messages may have changed without its newest message changing, as when one is deleted.
        messages.Clear();
        touched.Clear();
        UpdateMessages();
        readAt = started;
    }

    /// Reads on in each folder's log; reads them all again from scratch when that's needed.
    void ReadLogs()
    {
        // Compaction can finish or remove a suspect table without replacing the current log.
        if (suspectTables.Any(predicate: pair => FileStamp.Of(path: pair.Key) != pair.Value.File))
        {
            Rescan(confirmAtOnce: false);
            return;
        }
        var started = time.GetUtcNow();
        var watched = messages.Keys.ToHashSet(comparer: StringComparer.Ordinal);
        foreach (var folder in folders.Values)
        {
            if (folder.ReadLog(watched: watched, touched: touched) == TeamsLogRead.Rescan)
            {
                Rescan(confirmAtOnce: false);
                return;
            }
        }
        UpdateMessages();
        readAt = started;
    }

    /// Reads the messages of the chats that may be unread whose newest message changed, or that got a message, since their
    /// messages were last read; forgets those of chats that can't be unread anymore.
    void UpdateMessages()
    {
        var maybeUnread = MergedChats().Where(predicate: ChatReading.MayBeUnread).ToDictionary(keySelector: chat => chat.Id, comparer: StringComparer.Ordinal);
        foreach (var gone in messages.Keys.Where(predicate: id => !maybeUnread.ContainsKey(key: id)).ToList())
        {
            messages.Remove(key: gone);
        }
        var stale = maybeUnread.Values
            .Where(predicate: chat => touched.Contains(item: chat.Id) || !messages.TryGetValue(key: chat.Id, value: out var known) || known.Newest != chat.Newest!.Id)
            .Select(selector: chat => chat.Id)
            .ToHashSet(comparer: StringComparer.Ordinal);
        touched.Clear();
        if (stale.Count == 0)
        {
            return;
        }
        var read = new Dictionary<string, List<TeamsMessage>>(comparer: StringComparer.Ordinal);
        foreach (var folder in folders.Values)
        {
            try
            {
                foreach (var (chat, list) in folder.Messages(chats: stale))
                {
                    if (!read.TryGetValue(key: chat, value: out var all))
                    {
                        read[chat] = all = [];
                    }
                    all.AddRange(collection: list);
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // Its chats are read again at the next change: until then, their newest message stands in.
                touched.UnionWith(other: stale);
                return;
            }
        }
        foreach (var id in stale)
        {
            messages[id] = (
                maybeUnread[id].Newest!.Id,
                read.TryGetValue(key: id, value: out var list) ? list.DistinctBy(keySelector: message => message.Id).OrderBy(keySelector: message => message.Id).ToList() : []);
        }
    }

    /// Each chat once: one that more than one folder has, as with two profiles of the same account, as its newest copy,
    /// read as far as any copy says.
    List<TeamsChat> MergedChats() => folders.Values
        .SelectMany(selector: folder => folder.Chats.Select(selector: entry => entry.Chat))
        .GroupBy(keySelector: chat => chat.Id, comparer: StringComparer.Ordinal)
        .Select(selector: copies =>
        {
            var newest = copies.MaxBy(keySelector: chat => chat.Newest?.Id ?? 0)!;
            var marker = copies.Select(selector: chat => chat.Marker).OfType<ReadMarker>().MaxBy(keySelector: marker => marker.MessageId);
            return newest with { Marker = marker };
        })
        .OrderBy(keySelector: chat => chat.Id, comparer: StringComparer.Ordinal)
        .ToList();

    /// Counts tables unchanged and unreadable for `confirmationDelay`; checks the others again then.
    void ConfirmUnreadableTables(bool confirmAtOnce)
    {
        var now = time.GetUtcNow();
        var current = folders.Values.SelectMany(selector: folder => folder.UnreadableTables).ToList();
        var known = new Dictionary<string, (FileStamp? File, DateTimeOffset Since)>(dictionary: suspectTables, comparer: StringComparer.Ordinal);
        suspectTables.Clear();
        foreach (var (path, file) in current)
        {
            suspectTables[path] = known.TryGetValue(key: path, value: out var seen) && seen.File == file ? seen : (file, now);
        }
        unreadableTables = suspectTables.Values.Count(predicate: table => confirmAtOnce || now - table.Since >= confirmationDelay);
        if (isActive && suspectTables.Count > unreadableTables && !confirmationScheduled)
        {
            confirmationScheduled = true;
            confirmationTimer?.Change(dueTime: confirmationDelay, period: Timeout.InfiniteTimeSpan);
        }
    }

    /// Watches each folder; stops watching folders that are gone.
    void Watch()
    {
        foreach (var gone in watchers.Keys.Where(predicate: path => !folders.ContainsKey(key: path)).ToList())
        {
            watchers[gone].Dispose();
            watchers.Remove(key: gone);
        }
        foreach (var path in folders.Keys)
        {
            if (watchers.ContainsKey(key: path))
            {
                continue;
            }
            FileSystemWatcher? watcher = null;
            try
            {
                watcher = new FileSystemWatcher(path: path)
                {
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
                    InternalBufferSize = 64 * 1024,
                };
                watcher.Changed += FolderChanged;
                watcher.Created += FolderChanged;
                watcher.Deleted += FolderChanged;
                watcher.Renamed += (sender, e) => FolderChanged(sender: sender, e: e);
                watcher.Error += (sender, e) => Guarded(work: () => WatcherFailed(sender: sender, e: e));
                watcher.EnableRaisingEvents = true;
                watchers[path] = watcher;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
            {
                Log.Write(error: error, context: $"teams: can't watch a folder; the safety rescan covers it");
                watcher?.Dispose();
            }
        }
    }

    void FolderChanged(object? sender, FileSystemEventArgs e)
    {
        if (quietFiles.Contains(item: e.Name ?? string.Empty))
        {
            return;
        }
        lock (gate)
        {
            if (!isActive || sender is not FileSystemWatcher watcher || !watchers.ContainsValue(value: watcher) || readScheduled)
            {
                return;
            }
            readScheduled = true;
            readTimer?.Change(dueTime: reloadDelay, period: Timeout.InfiniteTimeSpan);
        }
    }

    /// The watcher lost events, as when its buffer overflowed, or stopped: everything is read again, with new watchers.
    void WatcherFailed(object sender, ErrorEventArgs e)
    {
        lock (gate)
        {
            if (!isActive || sender is not FileSystemWatcher watcher || !watchers.ContainsValue(value: watcher))
            {
                return;
            }
            Log.Write(error: e.GetException(), context: $"teams: a watcher lost events; reading everything again");
            foreach (var each in watchers.Values)
            {
                each.Dispose();
            }
            watchers.Clear();
            Rescan(confirmAtOnce: false);
            Publish(force: false);
        }
    }

    /// Runs a timer's or a watcher's work, on a thread that nothing waits on: a failure BriefBar doesn't expect is logged,
    /// by its type, and becomes the section's problem, rather than ending BriefBar. The next change or rescan tries again.
    void Guarded(Action work)
    {
        try
        {
            work();
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            Log.Write(error: error, context: $"teams: reading failed unexpectedly");
            lock (gate)
            {
                if (isActive)
                {
                    failed = true;
                    Publish(force: false);
                }
            }
        }
    }

    void ReadTimerFired()
    {
        lock (gate)
        {
            readScheduled = false;
            if (!isActive)
            {
                return;
            }
            ReadLogs();
            Publish(force: false);
        }
    }

    void SafetyTimerFired()
    {
        lock (gate)
        {
            if (isActive)
            {
                Rescan(confirmAtOnce: false);
                Publish(force: false);
            }
        }
    }

    void ConfirmationTimerFired()
    {
        lock (gate)
        {
            confirmationScheduled = false;
            if (isActive)
            {
                Rescan(confirmAtOnce: false);
                Publish(force: false);
            }
        }
    }

    TeamsSnapshot CurrentSnapshot()
    {
        var report = folders.Values.Aggregate(seed: new TeamsDataReport(), func: (total, folder) => total.Adding(other: folder.Report));
        return new TeamsSnapshot
        {
            Found = found,
            Failed = failed,
            Chats = MergedChats(),
            Messages = messages.ToDictionary(
                keySelector: pair => pair.Key, elementSelector: pair => pair.Value.Messages, comparer: StringComparer.Ordinal),
            Report = report with
            {
                Folders = report.Folders + unreadableFolders,
                UnreadableFiles = unreadableTables + unreadableFolders,
            },
            ReadAt = readAt,
        };
    }

    void Publish(bool force)
    {
        var current = CurrentSnapshot();
        if (!force && current.Equals(other: lastPublished))
        {
            return;
        }
        lastPublished = current;
        onChange(obj: current);
    }
}
