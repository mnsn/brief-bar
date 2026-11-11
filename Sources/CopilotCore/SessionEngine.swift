import BriefBarCore
import Foundation

public struct SessionRecord: Sendable, Equatable, Identifiable {
    public var meta: SessionMeta
    /// Nil when the session has no event log yet.
    public var log: SessionLogState?

    public var id: String { meta.id }

    public init(meta: SessionMeta, log: SessionLogState?) {
        self.meta = meta
        self.log = log
    }
}

/// Everything the engine knows at one point in time.
public struct EngineSnapshot: Sendable, Equatable {
    public var records: [SessionRecord]
    public var view: AppViewState
    /// Set when the Copilot data couldn't be read (shown in the UI instead of an empty list).
    public var problem: String?
    /// The sessions are the ones the app's database lists, rather than every recent session folder, which is all there
    /// is to go on while the database has never been readable (`SessionStateScanner`).
    public var listedByApp: Bool
    /// There's a Copilot folder, but nothing at all where the app's database goes, as on a Mac with only the Copilot CLI,
    /// which keeps none; not a database that's there but can't be reached. Looked at on every read that fails.
    public var databaseMissing: Bool
    /// Its sessions were read with where each session's work goes (`SessionEngine.setReadsLinks`), from the app's
    /// database, or from session folders where there's no database at all, as with only the Copilot CLI, which records
    /// none: not from session folders while the database can't be read.
    public var readsLinks: Bool

    public init(
        records: [SessionRecord] = [], view: AppViewState = AppViewState(), problem: String? = nil, listedByApp: Bool = true,
        databaseMissing: Bool = false, readsLinks: Bool = false
    ) {
        self.records = records
        self.view = view
        self.problem = problem
        self.listedByApp = listedByApp
        self.databaseMissing = databaseMissing
        self.readsLinks = readsLinks
    }
}

/// Watches `~/.copilot` with FSEvents and keeps one `EventLogReader` per visible session.
/// Event-log appends are applied immediately; database changes trigger a throttled metadata
/// reload, and one more read a moment after the last (`scheduleReread`). The app keeps its database
/// open, and FSEvents only reports a file's writes once it's closed, so database commits are picked
/// up by a kqueue watch on SQLite's write-ahead log. A slow safety rescan covers anything the
/// watches might miss.
///
/// All mutable state is confined to `queue`; `onChange` is called on that queue.
public final class SessionEngine: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (EngineSnapshot) -> Void

    public let paths: CopilotPaths
    private let queue: DispatchQueue
    private let onChange: ChangeHandler
    private let metadataThrottle: TimeInterval
    private let rereadDelay: TimeInterval
    private let safetyInterval: TimeInterval
    private let loadDatabase: @Sendable (URL, Bool) throws -> DatabaseSnapshot

    private var metas: [SessionMeta] = []
    private var view = AppViewState()
    private var problem: String?
    private var metadataFromDatabase = false
    private var databaseMissing = false
    private var readers: [String: EventLogReader] = [:]
    private var lastPublished: EngineSnapshot?
    private var stream: FileEventStream?
    private var walWatcher: FileWriteWatcher?
    private var safetyTimer: DispatchSourceTimer?
    private var metadataReloadScheduled = false
    /// Counts the reads writes bring, so that only the last one's reread happens.
    private var writeReads = 0
    private var isActive = false
    /// Reads where each session's work goes too, for Show Links.
    private var readsLinks = false
    /// The sessions it lists were read with where each session's work goes, as far as that's anywhere to read.
    private var linksRead = false

    /// - Parameters:
    ///   - metadataThrottle: how long after a write to the database to read it, so that a burst of writes is read once.
    ///   - rereadDelay: how long after the last such read to read once more (`scheduleReread`).
    ///   - loadDatabase: reads the app's database, with where each session's work goes or not; tests replace it.
    public init(
        paths: CopilotPaths = .default(),
        metadataThrottle: TimeInterval = 0.25,
        rereadDelay: TimeInterval = 1,
        safetyInterval: TimeInterval = 60,
        loadDatabase: @escaping @Sendable (URL, Bool) throws -> DatabaseSnapshot = { try AppDatabase.load(at: $0, links: $1) },
        onChange: @escaping ChangeHandler
    ) {
        self.paths = paths
        self.queue = DispatchQueue(label: "BriefBar.Copilot.SessionEngine", qos: .utility)
        self.metadataThrottle = metadataThrottle
        self.rereadDelay = rereadDelay
        self.safetyInterval = safetyInterval
        self.loadDatabase = loadDatabase
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard !isActive else { return }
            isActive = true
            // Watch before the first load so no change can slip in between.
            startWatching()
            reloadMetadata()
            publish(force: true)
            startSafetyTimer()
        }
    }

    public func stop() {
        queue.async { [self] in
            isActive = false
            stream?.stop()
            stream = nil
            walWatcher?.cancel()
            walWatcher = nil
            safetyTimer?.cancel()
            safetyTimer = nil
        }
    }

    /// Whether to read where each session's work goes too (`SessionLinks`), for Show Links: read again at once when it
    /// changes, and forgotten when it's off.
    public func setReadsLinks(_ reads: Bool) {
        queue.async { [self] in
            guard reads != readsLinks else { return }
            readsLinks = reads
            guard isActive else { return }
            reloadMetadata()
            publish()
        }
    }

    /// Re-reads metadata and all logs, then publishes if anything changed.
    public func refresh() {
        queue.async { [self] in
            guard isActive else { return }
            rescan()
        }
    }

    /// One-shot synchronous load (CLI and tests).
    /// - Parameter links: read where each session's work goes too, for Show Links.
    public static func loadOnce(paths: CopilotPaths = .default(), links: Bool = false) -> EngineSnapshot {
        let engine = SessionEngine(paths: paths) { _ in }
        return engine.queue.sync {
            engine.readsLinks = links
            engine.reloadMetadata()
            return engine.currentSnapshot()
        }
    }

    // MARK: - Queue-confined

    private func startWatching() {
        let stream = FileEventStream(paths: [paths.root.path], latency: 0.15, queue: queue) { [weak self] events in
            self?.handle(events)
        }
        if stream.start() {
            self.stream = stream
        }
        let walWatcher = FileWriteWatcher(path: paths.databaseWAL.path, queue: queue) { [weak self] in
            self?.scheduleMetadataReload()
        }
        // The log may not exist yet (e.g. the app isn't running); FSEvents reports its creation.
        walWatcher.rearm()
        self.walWatcher = walWatcher
    }

    private func startSafetyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + safetyInterval, repeating: safetyInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            self.rescan()
        }
        timer.resume()
        safetyTimer = timer
    }

    private func handle(_ events: [FileEventStream.Event]) {
        guard isActive else { return }
        var touchedSessions = Set<String>()
        var databaseChanged = false
        var walChanged = false
        var mustRescan = false

        for event in events {
            if event.flags & FileEventStream.rescanFlags != 0 {
                mustRescan = true
                continue
            }
            let path = event.path
            if path.hasSuffix("/events.jsonl") {
                let sessionDirectory = (path as NSString).deletingLastPathComponent
                let container = ((sessionDirectory as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if container == "session-state" {
                    touchedSessions.insert((sessionDirectory as NSString).lastPathComponent)
                }
            } else if path.hasSuffix("/data.db-wal") {
                // Created, removed or closed: the kqueue watch may need to move to a new file.
                walChanged = true
                databaseChanged = true
            } else if path.hasSuffix("/data.db") || path.hasSuffix("/data.db-journal") {
                databaseChanged = true
            }
        }

        if mustRescan {
            rescan()
            return
        }
        if walChanged {
            walWatcher?.rearm()
        }
        for id in touchedSessions {
            readers[id]?.update()
        }
        if databaseChanged {
            scheduleMetadataReload()
        }
        if !touchedSessions.isEmpty {
            publish()
        }
    }

    private func scheduleMetadataReload() {
        guard !metadataReloadScheduled else { return }
        metadataReloadScheduled = true
        queue.asyncAfter(deadline: .now() + metadataThrottle) { [weak self] in
            guard let self else { return }
            self.metadataReloadScheduled = false
            guard self.isActive else { return }
            self.reloadMetadata()
            self.publish()
            self.scheduleReread()
        }
    }

    /// Reads the database once more, `rereadDelay` after the last read a write brought. SQLite writes a commit to its
    /// write-ahead log before it lets readers see it, and only the write is heard of, so a writer held up between the
    /// two, as on a busy Mac, leaves that read without the commit. When nothing is written after it, as when a session
    /// ends, nothing else would read it before the safety rescan, a minute later.
    private func scheduleReread() {
        writeReads += 1
        let readsSoFar = writeReads
        queue.asyncAfter(deadline: .now() + rereadDelay) { [weak self] in
            // A later write's read, made or to come, has its own.
            guard let self, self.isActive, readsSoFar == self.writeReads, !self.metadataReloadScheduled else { return }
            self.reloadMetadata()
            self.publish()
        }
    }

    private func rescan() {
        walWatcher?.rearm()
        reloadMetadata()
        for reader in readers.values {
            reader.update()
        }
        publish()
    }

    private func reloadMetadata() {
        do {
            let snapshot = try loadDatabase(paths.database, readsLinks)
            metas = snapshot.sessions
            view = snapshot.view
            metadataFromDatabase = true
            linksRead = readsLinks
            databaseMissing = false
            problem = nil
        } catch {
            let hasFolder = FileManager.default.fileExists(atPath: paths.root.path)
            databaseMissing = hasFolder && Self.isMissing(paths.database)
            if metadataFromDatabase {
                // Keep the last good list, but its running flags may be out of date, so the
                // logs decide until the database can be read again.
                for index in metas.indices {
                    metas[index].isRunning = nil
                }
                problem = "\(error). The list may be out of date."
            } else {
                metas = SessionStateScanner.recentSessions(paths: paths)
                // Nothing at all where the database goes, its folder or not: the folders are all there is.
                linksRead = readsLinks && Self.isMissing(paths.database)
                problem = hasFolder
                    ? String(describing: error)
                    : "No Copilot data found at \(paths.root.path)"
            }
        }
        syncReaders()
    }

    /// Whether there's nothing at all at `url`, rather than something that can't be reached, which
    /// `FileManager.fileExists` doesn't tell apart.
    public static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    private func syncReaders() {
        let visible = Set(metas.map(\.id))
        readers = readers.filter { visible.contains($0.key) }
        for id in visible where readers[id] == nil {
            let reader = EventLogReader(url: paths.eventsFile(id))
            reader.update()
            readers[id] = reader
        }
    }

    private func currentSnapshot() -> EngineSnapshot {
        let records = metas.map { meta in
            let reader = readers[meta.id]
            return SessionRecord(meta: meta, log: reader?.isLoaded == true ? reader?.state : nil)
        }
        return EngineSnapshot(
            records: records, view: view, problem: problem, listedByApp: metadataFromDatabase, databaseMissing: databaseMissing,
            readsLinks: readsLinks && linksRead
        )
    }

    private func publish(force: Bool = false) {
        let current = currentSnapshot()
        guard force || current != lastPublished else { return }
        lastPublished = current
        onChange(current)
    }
}
