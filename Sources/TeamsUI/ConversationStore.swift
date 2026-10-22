import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import NotificationCenterDB
import TeamsCore

/// Where Teams' chats are read from and what may be written, depending on how BriefBar runs.
struct StorageMode {
    var paths: NotificationPaths
    /// Holds the key for the saved unread chats; nil when they're neither read nor written.
    var keyStore: (any KeyStore)?
    /// Whether to save its state and the unread chats.
    var writes: Bool

    /// - Another database (demo data, fixtures) holds nothing private: its key sits in a file next to
    ///   its state.
    /// - Notification Center's own database: only the installed app saves chats from it, with the key
    ///   in the keychain, and only the app reads them back (`readOnly`). A bare binary (`make run`)
    ///   saves nothing, so it never touches the installed app's files or keychain item.
    static func current(paths: NotificationPaths = .default(), isBundled: Bool = AppIdentity.isBundled) -> StorageMode {
        if !paths.isSystemDatabase {
            return StorageMode(paths: paths, keyStore: FileKeyStore(url: paths.stateDirectory.appendingPathComponent("key")),
                               writes: true)
        }
        if isBundled {
            return StorageMode(paths: paths, keyStore: KeychainKeyStore(), writes: true)
        }
        return StorageMode(paths: paths, keyStore: nil, writes: false)
    }

    /// For the demo: only a database that `BRIEFBAR_TEAMS_DB` names, never Notification Center's own.
    /// Without one, a database that doesn't exist, which shows as missing.
    static func demo(paths: NotificationPaths = .default()) -> StorageMode {
        guard paths.isSystemDatabase else { return current(paths: paths) }
        let nowhere = URL(fileURLWithPath: "/var/empty/BriefBar demo/db2/db")
        return StorageMode(paths: NotificationPaths(database: nowhere, stateDirectory: nowhere.deletingLastPathComponent()),
                           keyStore: nil, writes: false)
    }

    /// For the command line and `--render`: writes nothing, and reads only what whoever runs it can read.
    /// Any program can run BriefBar's binary, and the keychain gives that binary the key to the chats the app
    /// saved from Notification Center's database without asking, so that key is the app's alone: these show
    /// Notification Center as it is now. Another database keeps its key file, which sits next to its state.
    var readOnly: StorageMode {
        StorageMode(paths: paths, keyStore: paths.isSystemDatabase ? nil : keyStore, writes: false)
    }

    /// Unread chats as of now, from one read of the database (command line).
    func loadState(settings: TrackerSettings, now: Date = Date()) -> (UnreadState, EngineSnapshot) {
        let cached = keyStore.map { UnreadCache(url: paths.unreadFile, keyStore: $0).load(discardingUnreadable: false) }?
            .conversations ?? []
        var tracker = UnreadTracker(launch: LaunchContext(state: StateStore(url: paths.stateFile).load(), cached: cached,
                                                          launchedAt: now))
        let snapshot = NotificationEngine.loadOnce(paths: paths)
        if let notifications = snapshot.notifications {
            tracker.apply(notifications, now: now)
        }
        return (tracker.state(now: now, settings: settings), snapshot)
    }
}

/// Main-thread view model: feeds the engine's snapshots to the unread tracker, and saves what has to
/// survive a restart.
@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var state = UnreadState()
    /// Reference time for relative labels; ticks every 15 s.
    @Published private(set) var now = Date()
    /// Nil until the first read.
    @Published private(set) var access: AccessStatus?
    @Published private(set) var problem: PulseProblem?
    /// BriefBar could read the database before, but can't now.
    @Published private(set) var lostAccess = false
    /// False when Notification Center has nothing from Teams at all.
    @Published private(set) var hasTeamsNotifications = true
    @Published private(set) var hasLoaded = false

    let storage: StorageMode
    private let settings: AppSettings
    private var tracker: UnreadTracker
    private var pulseState: PulseState
    private let stateStore: StateStore
    private let cache: UnreadCache?
    private let saveQueue = DispatchQueue(label: "BriefBar.Teams.save", qos: .utility)
    private var engine: NotificationEngine?
    /// What the file holds, as far as this process knows.
    private var savedConversations: [CachedConversation]
    /// The saved chats couldn't be loaded (their key was unavailable), so the file mustn't be
    /// overwritten until they are. Retried a few times, so a declined keychain prompt doesn't nag.
    private var cacheBlocked: Bool
    private var cacheRetries: [TimeInterval] = [60, 300, 900, 3_600]
    private var nextCacheRetry: Date
    private var hasApplied = false
    /// When the last read that the tracker took in started: what `lastRunAt` records, so a stretch
    /// when the database couldn't be read never counts as seen.
    private var lastAppliedReadAt: Date?
    private var badge = DockBadgeTracker()
    private var timers: [Timer] = []
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings, storage: StorageMode, launchedAt: Date = Date()) {
        self.settings = settings
        self.storage = storage
        stateStore = StateStore(url: storage.paths.stateFile)
        cache = storage.keyStore.map { UnreadCache(url: storage.paths.unreadFile, keyStore: $0) }
        let saved = stateStore.load()
        let load = cache?.load(discardingUnreadable: storage.writes) ?? .loaded([])
        tracker = UnreadTracker(launch: LaunchContext(state: saved, cached: load.conversations, launchedAt: launchedAt))
        savedConversations = load.conversations
        cacheBlocked = load == .keyUnavailable
        nextCacheRetry = launchedAt.addingTimeInterval(cacheRetries.removeFirst())
        pulseState = saved ?? PulseState()
        if pulseState.firstLaunchAt == nil {
            pulseState.firstLaunchAt = launchedAt
        }
    }

    var paths: NotificationPaths { storage.paths }

    func start() {
        guard engine == nil else { return }
        let engine = NotificationEngine(paths: storage.paths) { [weak self] snapshot in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.receive(snapshot) }
            }
        }
        self.engine = engine
        engine.start()

        settings.$keepUnread.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &cancellables)

        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        ticker.tolerance = 3
        // While it runs, it records that it does, so the next launch knows what arrived while it didn't.
        let heartbeat = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryBlockedCache()
                self?.recordRun()
            }
        }
        heartbeat.tolerance = 10
        for timer in [ticker, heartbeat] {
            RunLoop.main.add(timer, forMode: .common)
        }
        timers = [ticker, heartbeat]
    }

    /// Saves everything before the app quits.
    func stop() {
        engine?.stop()
        timers.forEach { $0.invalidate() }
        recordRun()
        saveQueue.sync {}
    }

    /// Waits for what's being saved, after `stop()`.
    func finishSaving() {
        saveQueue.sync {}
    }

    /// Deletes what was saved, without reading it: the encrypted unread chats, their key, and the state
    /// file. For when Teams is turned off, after `stop()`. Only the files written here are deleted, and
    /// their folder only if that leaves it empty.
    static func deleteSavedData(_ storage: StorageMode) {
        guard storage.writes else { return }
        if let keyStore = storage.keyStore {
            UnreadCache(url: storage.paths.unreadFile, keyStore: keyStore).discard()
        }
        try? FileManager.default.removeItem(at: storage.paths.stateFile)
        rmdir(storage.paths.stateDirectory.path)
        Log.app.info("Deleted Teams' saved chats and state")
    }

    func refresh() {
        engine?.refresh()
    }

    func setWaitingForAccess(_ waiting: Bool) {
        engine?.setWaitingForAccess(waiting)
    }

    func receive(_ snapshot: EngineSnapshot) {
        access = snapshot.access
        if problem != snapshot.problem {
            problem = snapshot.problem
            if let problem {
                Log.app.error("\(problem.title, privacy: .public)")
            }
        }
        hasTeamsNotifications = snapshot.notifications.map { !$0.isEmpty || !snapshot.teamsIdentifiers.isEmpty } ?? true
        if snapshot.access == .granted, snapshot.notifications != nil, !pulseState.hadAccess {
            pulseState.hadAccess = true
            saveState()
        }
        lostAccess = snapshot.access == .denied && pulseState.hadAccess
        if let notifications = snapshot.notifications {
            tracker.apply(notifications, now: Date())
            lastAppliedReadAt = snapshot.readAt ?? lastAppliedReadAt
            if !hasApplied {
                hasApplied = true
                recordRun()
            }
        }
        hasLoaded = true
        recompute()
    }

    /// Opens the chat in Teams, at its oldest unread message, and marks it read.
    func open(_ conversation: ConversationSummary) {
        TeamsApp.open(conversation.link)
        markRead(conversation)
    }

    func markRead(_ conversation: ConversationSummary) {
        tracker.markRead(conversationID: conversation.id, at: Date())
        recompute()
    }

    func markAllRead(_ group: ChatGroup) {
        tracker.markAllRead(group, at: Date())
        recompute()
    }

    /// With **Mark All Read When Teams' Badge Clears** on, a badge seen to disappear, and stay gone for
    /// `DockBadgeTracker.confirmation`, in the same Teams process, reads everything delivered until it
    /// went: Teams has nothing unread. No badge right after Teams starts, or with no reading at all,
    /// says nothing. Nil means `lsappinfo` had nothing to say.
    func dockBadgeChanged(_ reading: DockBadge?, teamsProcess: pid_t) {
        guard let clearedAt = badge.update(reading, process: teamsProcess, at: Date()), settings.clearWithDockBadge,
              hasApplied
        else { return }
        Log.app.info("Teams' dock badge cleared; marking everything read")
        tracker.markEverythingRead(at: clearedAt)
        recompute()
    }

    /// Teams started or quit: its badge starts over.
    func resetDockBadge() {
        badge.reset()
    }

    private func recompute() {
        let now = Date()
        let trackerSettings = settings.trackerSettings
        tracker.expire(now: now, settings: trackerSettings)
        let newState = tracker.state(now: now, settings: trackerSettings)
        self.now = now
        if newState != state {
            state = newState
        }
        saveUnread(now: now)
    }

    /// Saves the unread chats whenever they change; read chats leave the file at once. Before the first
    /// read, the unread chats are what was saved, minus those read or expired since, so saving them is
    /// safe too.
    private func saveUnread(now: Date) {
        guard storage.writes, !cacheBlocked, let cache else { return }
        let conversations = tracker.savedConversations(now: now, settings: settings.trackerSettings)
        guard conversations != savedConversations else { return }
        savedConversations = conversations
        saveQueue.async {
            do {
                try cache.save(conversations, at: now)
            } catch {
                Log.app.error("Couldn't save the unread chats: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Records how far this run has seen. Not while the saved chats couldn't be loaded: the next launch
    /// must then count everything since the last record as unread, since those chats weren't saved.
    private func recordRun() {
        guard !cacheBlocked, let readAt = lastAppliedReadAt, readAt != pulseState.lastRunAt else { return }
        pulseState.lastRunAt = readAt
        saveState()
    }

    /// Loads the saved chats once their key can be read, and merges them in.
    private func retryBlockedCache() {
        guard cacheBlocked, let cache, Date() >= nextCacheRetry else { return }
        switch cache.load(discardingUnreadable: storage.writes) {
        case .loaded(let conversations):
            cacheBlocked = false
            tracker.restore(conversations)
            savedConversations = conversations
            recompute()
            recordRun()
        case .keyUnavailable:
            if cacheRetries.isEmpty {
                nextCacheRetry = .distantFuture
            } else {
                nextCacheRetry = Date().addingTimeInterval(cacheRetries.removeFirst())
            }
        }
    }

    private func saveState() {
        guard storage.writes else { return }
        let state = pulseState
        let store = stateStore
        saveQueue.async {
            do {
                try store.save(state)
            } catch {
                Log.app.error("Couldn't save the app state: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
