using BriefBar.Core.Logging;

namespace BriefBar.Core.Copilot;

/// Watches the Copilot folder and keeps one `EventLogReader` per listed session. Appends to a session's log are read
/// within moments; database changes trigger a throttled reload. Windows reports the app's writes to SQLite's
/// write-ahead log while the app keeps it open, so one watcher on the folder covers the database, which macOS's FSEvents
/// doesn't. A slow safety rescan covers anything the watchers miss, and a watcher's lost events mean a rescan at once.
///
/// All its state is guarded by one lock, and the handler it was made with is called with that lock held, one snapshot
/// at a time: the handler mustn't call the engine. The Mac's `SessionEngine`.
public sealed class SessionEngine : ISessionEngine, IDisposable
{
    readonly Lock gate = new();
    readonly Action<EngineSnapshot> onChange;
    readonly TimeSpan metadataThrottle;
    readonly TimeSpan logThrottle;
    readonly TimeSpan safetyInterval;
    readonly Dictionary<string, EventLogReader> readers = new(comparer: StringComparer.Ordinal);
    readonly HashSet<string> touchedSessions = new(comparer: StringComparer.Ordinal);
    List<SessionMeta> metas = [];
    AppViewState view = new();
    string? problem;
    bool metadataFromDatabase;
    bool databaseMissing;
    EngineSnapshot? lastPublished;
    FileSystemWatcher? databaseWatcher;
    FileSystemWatcher? logWatcher;
    Timer? safetyTimer;
    Timer? metadataTimer;
    Timer? logTimer;
    bool metadataReloadScheduled;
    bool logPassScheduled;
    bool isActive;

    /// - `metadataThrottle`: how long a burst of database writes is waited out before reloading, as one tool call makes
    ///   about ten.
    /// - `safetyInterval`: how often everything is read again, in case a watcher missed something.
    public SessionEngine(
        CopilotPaths paths, Action<EngineSnapshot> onChange, TimeSpan? metadataThrottle = null, TimeSpan? safetyInterval = null)
    {
        ArgumentNullException.ThrowIfNull(argument: paths);
        ArgumentNullException.ThrowIfNull(argument: onChange);
        Paths = paths;
        this.onChange = onChange;
        this.metadataThrottle = metadataThrottle ?? TimeSpan.FromMilliseconds(value: 250);
        logThrottle = TimeSpan.FromMilliseconds(value: 150);
        this.safetyInterval = safetyInterval ?? TimeSpan.FromSeconds(value: 60);
    }

    public CopilotPaths Paths { get; }

    /// One read, for tests: what a started engine would hand over first.
    public static EngineSnapshot LoadOnce(CopilotPaths paths)
    {
        using var engine = new SessionEngine(paths: paths, onChange: _ => { });
        lock (engine.gate)
        {
            engine.ReloadMetadata();
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
            metadataTimer = new Timer(callback: _ => Guarded(work: MetadataTimerFired), state: null, dueTime: Timeout.Infinite, period: Timeout.Infinite);
            logTimer = new Timer(callback: _ => Guarded(work: LogTimerFired), state: null, dueTime: Timeout.Infinite, period: Timeout.Infinite);
            // Watch before the first load, so that no change can slip in between.
            StartWatching();
            ReloadMetadata();
            Publish(force: true);
            safetyTimer = new Timer(callback: _ => Guarded(work: SafetyTimerFired), state: null, dueTime: safetyInterval, period: safetyInterval);
        }
    }

    public void Stop()
    {
        lock (gate)
        {
            isActive = false;
            StopWatching();
            safetyTimer?.Dispose();
            safetyTimer = null;
            metadataTimer?.Dispose();
            metadataTimer = null;
            logTimer?.Dispose();
            logTimer = null;
            metadataReloadScheduled = false;
            logPassScheduled = false;
            touchedSessions.Clear();
            readers.Clear();
            lastPublished = null;
        }
    }

    public void Refresh()
    {
        lock (gate)
        {
            if (isActive)
            {
                Rescan();
            }
        }
    }

    public void Dispose() => Stop();

    /// Whether there's nothing at all at `path`, rather than something that can't be reached, which `File.Exists`
    /// doesn't tell apart.
    internal static bool IsMissing(string path)
    {
        try
        {
            File.GetAttributes(path: path);
            return false;
        }
        catch (FileNotFoundException)
        {
            return true;
        }
        catch (DirectoryNotFoundException)
        {
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    void StartWatching()
    {
        if (databaseWatcher is null && Directory.Exists(path: Paths.Root))
        {
            // Not `data.db-shm`, which readers change too, BriefBar included.
            databaseWatcher = Watcher(folder: Paths.Root, names: ["data.db", "data.db-wal", "data.db-journal"], subfolders: false, changed: DatabaseChanged);
        }
        if (logWatcher is null && Directory.Exists(path: Paths.SessionState))
        {
            logWatcher = Watcher(folder: Paths.SessionState, names: ["events.jsonl"], subfolders: true, changed: LogChanged);
        }
    }

    void StopWatching()
    {
        databaseWatcher?.Dispose();
        databaseWatcher = null;
        logWatcher?.Dispose();
        logWatcher = null;
    }

    /// A watcher for `names` in `folder`, or null when it can't watch it, which the next rescan tries again.
    FileSystemWatcher? Watcher(string folder, string[] names, bool subfolders, FileSystemEventHandler changed)
    {
        FileSystemWatcher? watcher = null;
        try
        {
            watcher = new FileSystemWatcher(path: folder)
            {
                IncludeSubdirectories = subfolders,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
                InternalBufferSize = 64 * 1024,
            };
            foreach (var name in names)
            {
                watcher.Filters.Add(item: name);
            }
            watcher.Changed += changed;
            watcher.Created += changed;
            watcher.Deleted += changed;
            watcher.Renamed += (sender, e) => changed(sender: sender, e: e);
            watcher.Error += (sender, e) => Guarded(work: () => WatcherFailed(sender: sender, e: e));
            watcher.EnableRaisingEvents = true;
            return watcher;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            Log.Write(error: error, context: $"copilot: can't watch a folder; the safety rescan covers it");
            watcher?.Dispose();
            return null;
        }
    }

    void DatabaseChanged(object? sender, FileSystemEventArgs e)
    {
        lock (gate)
        {
            if (isActive && sender == databaseWatcher)
            {
                ScheduleMetadataReload();
            }
        }
    }

    void LogChanged(object? sender, FileSystemEventArgs e)
    {
        var folder = Path.GetDirectoryName(path: e.FullPath);
        if (folder is null || !string.Equals(a: Path.GetDirectoryName(path: folder), b: Paths.SessionState, comparisonType: StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        lock (gate)
        {
            if (!isActive || sender != logWatcher)
            {
                return;
            }
            touchedSessions.Add(item: Path.GetFileName(path: folder));
            if (!logPassScheduled)
            {
                logPassScheduled = true;
                logTimer?.Change(dueTime: logThrottle, period: Timeout.InfiniteTimeSpan);
            }
        }
    }

    /// The watcher lost events, as when its buffer overflowed, or stopped: everything is read again, with new watchers.
    void WatcherFailed(object sender, ErrorEventArgs e)
    {
        lock (gate)
        {
            if (!isActive || (sender != databaseWatcher && sender != logWatcher))
            {
                return;
            }
            Log.Write(error: e.GetException(), context: $"copilot: a watcher lost events; reading everything again");
            StopWatching();
            Rescan();
        }
    }

    void ScheduleMetadataReload()
    {
        if (metadataReloadScheduled)
        {
            return;
        }
        metadataReloadScheduled = true;
        metadataTimer?.Change(dueTime: metadataThrottle, period: Timeout.InfiniteTimeSpan);
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
            Log.Write(error: error, context: $"copilot: reading failed unexpectedly");
            lock (gate)
            {
                if (isActive)
                {
                    problem = CopilotApp.UnexpectedProblem;
                    Publish(force: false);
                }
            }
        }
    }

    void MetadataTimerFired()
    {
        lock (gate)
        {
            metadataReloadScheduled = false;
            if (!isActive)
            {
                return;
            }
            ReloadMetadata();
            Publish(force: false);
        }
    }

    void LogTimerFired()
    {
        lock (gate)
        {
            logPassScheduled = false;
            if (!isActive)
            {
                return;
            }
            foreach (var id in touchedSessions)
            {
                if (readers.TryGetValue(key: id, value: out var reader))
                {
                    reader.Update();
                }
            }
            touchedSessions.Clear();
            Publish(force: false);
        }
    }

    void SafetyTimerFired()
    {
        lock (gate)
        {
            if (isActive)
            {
                Rescan();
            }
        }
    }

    void Rescan()
    {
        StartWatching();
        ReloadMetadata();
        foreach (var reader in readers.Values)
        {
            reader.Update();
        }
        Publish(force: false);
    }

    void ReloadMetadata()
    {
        try
        {
            var snapshot = AppDatabase.Load(path: Paths.Database);
            metas = [.. snapshot.Sessions];
            view = snapshot.View;
            metadataFromDatabase = true;
            databaseMissing = false;
            problem = null;
        }
        catch (AppDatabaseException error)
        {
            var hasFolder = Directory.Exists(path: Paths.Root);
            databaseMissing = hasFolder && IsMissing(path: Paths.Database);
            if (metadataFromDatabase)
            {
                // The last good list stays, but its running flags may be out of date, so the logs decide until the
                // database can be read again.
                metas = metas.Select(selector: meta => meta with { IsRunning = null }).ToList();
                problem = error.Message + ". The list may be out of date.";
            }
            else
            {
                metas = SessionStateScanner.RecentSessions(paths: Paths, now: DateTimeOffset.UtcNow);
                problem = hasFolder ? error.Message : "No Copilot data found at " + Paths.Root;
            }
        }
        SyncReaders();
    }

    void SyncReaders()
    {
        var visible = metas.Select(selector: meta => meta.Id).Where(predicate: IsPlainName).ToHashSet(comparer: StringComparer.Ordinal);
        foreach (var gone in readers.Keys.Where(predicate: id => !visible.Contains(item: id)).ToList())
        {
            readers.Remove(key: gone);
        }
        foreach (var id in visible)
        {
            if (!readers.ContainsKey(key: id))
            {
                var reader = new EventLogReader(path: Paths.EventsFile(id: id));
                reader.Update();
                readers[id] = reader;
            }
        }
    }

    /// A session's ID names its folder in `session-state`: one that would name another folder, such as `..`, has none.
    static bool IsPlainName(string id) =>
        id.Length > 0 && id != "." && id != ".." && id.IndexOfAny(anyOf: Path.GetInvalidFileNameChars()) < 0;

    EngineSnapshot CurrentSnapshot()
    {
        var records = metas.Select(selector: meta => new SessionRecord(
            Meta: meta,
            Log: readers.TryGetValue(key: meta.Id, value: out var reader) && reader.IsLoaded ? reader.State : null));
        return new EngineSnapshot
        {
            Records = new ValueList<SessionRecord>(items: records),
            View = view,
            Problem = problem,
            ListedByApp = metadataFromDatabase,
            DatabaseMissing = databaseMissing,
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
