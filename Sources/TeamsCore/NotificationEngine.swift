import BriefBarCore
import Foundation
import NotificationCenterDB
import SQLite3

/// Everything the engine knows at one point in time.
public struct EngineSnapshot: Sendable, Equatable {
    public var access: AccessStatus
    /// Every Teams notification Notification Center has stored, parsed. Nil when the database couldn't
    /// be read: an empty list would look as if every notification had left.
    public var notifications: [ParsedNotification]?
    public var report: FormatReport
    /// `app.badge` for Teams, if Notification Center records one.
    public var badge: Int?
    /// Teams' entries in Notification Center; empty if Teams never posted a notification.
    public var teamsIdentifiers: [String]
    public var problem: PulseProblem?
    /// When the read that produced `notifications` started: everything Notification Center had by then
    /// is in them. Nil when the read failed. Not part of equality, so an unchanged read isn't news.
    public var readAt: Date?

    public init(
        access: AccessStatus = .missing, notifications: [ParsedNotification]? = nil, report: FormatReport = FormatReport(),
        badge: Int? = nil, teamsIdentifiers: [String] = [], problem: PulseProblem? = nil, readAt: Date? = nil
    ) {
        self.access = access
        self.notifications = notifications
        self.report = report
        self.badge = badge
        self.teamsIdentifiers = teamsIdentifiers
        self.problem = problem
        self.readAt = readAt
    }

    public static func == (a: EngineSnapshot, b: EngineSnapshot) -> Bool {
        a.access == b.access && a.notifications == b.notifications && a.report == b.report && a.badge == b.badge
            && a.teamsIdentifiers == b.teamsIdentifiers && a.problem == b.problem
    }
}

/// Watches Notification Center's database and publishes Teams' notifications whenever they change.
///
/// Notification Center keeps its database open, and FSEvents only reports a file's writes once it's
/// closed, so commits are picked up by a kqueue watch on SQLite's write-ahead log (`db-wal`). FSEvents
/// on the folder reports the log being created or replaced. Bursts are combined into one read after
/// `reloadDelay`. A slow safety rescan covers anything the watches miss, and while BriefBar can't
/// read the database, it checks for access on a timer.
///
/// All mutable state is confined to `queue`; `onChange` is called on that queue.
public final class NotificationEngine: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (EngineSnapshot) -> Void

    public let paths: NotificationPaths
    private let queue: DispatchQueue
    private let onChange: ChangeHandler
    private let reloadDelay: TimeInterval
    private let safetyInterval: TimeInterval
    private let accessIntervals: (waiting: TimeInterval, idle: TimeInterval)

    private var snapshot = EngineSnapshot()
    private var lastPublished: EngineSnapshot?
    private var stream: FileEventStream?
    private var walWatcher: FileWriteWatcher?
    private var safetyTimer: DispatchSourceTimer?
    private var accessTimer: DispatchSourceTimer?
    private var accessTimerInterval: TimeInterval = 0
    private var waitingForAccess = false
    private var reloadScheduled = false
    private var isActive = false

    public init(
        paths: NotificationPaths = .default(),
        reloadDelay: TimeInterval = 0.3,
        safetyInterval: TimeInterval = 60,
        accessIntervals: (waiting: TimeInterval, idle: TimeInterval) = (2, 30),
        onChange: @escaping ChangeHandler
    ) {
        self.paths = paths
        self.queue = DispatchQueue(label: "BriefBar.Teams.NotificationEngine", qos: .utility)
        self.reloadDelay = reloadDelay
        self.safetyInterval = safetyInterval
        self.accessIntervals = accessIntervals
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard !isActive else { return }
            isActive = true
            // Watch before the first read so no change can slip in between.
            startWatching()
            reload()
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
            accessTimer?.cancel()
            accessTimer = nil
        }
    }

    /// Reads the database again, and publishes if anything changed.
    public func refresh() {
        queue.async { [self] in
            guard isActive else { return }
            rescan()
        }
    }

    /// Checks for access often while someone is waiting for it (onboarding is open), rarely otherwise.
    public func setWaitingForAccess(_ waiting: Bool) {
        queue.async { [self] in
            waitingForAccess = waiting
            updateAccessTimer()
        }
    }

    /// One read, without watching (command line and tests).
    public static func loadOnce(paths: NotificationPaths = .default()) -> EngineSnapshot {
        read(paths)
    }

    /// Reads and parses Teams' notifications. Never throws: problems end up in the snapshot.
    static func read(_ paths: NotificationPaths) -> EngineSnapshot {
        let started = Date()
        switch DatabaseAccess.check(paths.database) {
        case .denied:
            return EngineSnapshot(access: .denied, problem: .noAccess)
        case .missing:
            return EngineSnapshot(access: .missing, problem: .databaseMissing(path: paths.database.path))
        case .granted:
            break
        }
        do {
            let contents = try NotificationDatabase.load(at: paths.database, bundleIdentifiers: TeamsBundle.identifiers)
            let parsed = contents.records.map { record in
                var notification = TeamsNotificationParser.parse(record)
                notification.raw = nil
                return notification
            }
            let report = FormatReport(parsed)
            var problem: PulseProblem?
            switch report.verdict {
            case .unrecognized(let total): problem = .formatChanged(total: total)
            case .partlyUnreadable(let unreadable, let total): problem = .partlyUnreadable(unreadable: unreadable, total: total)
            case .ok, .empty: problem = nil
            }
            return EngineSnapshot(
                access: .granted, notifications: parsed, report: report, badge: contents.badge,
                teamsIdentifiers: contents.appIdentifiers, problem: problem, readAt: started
            )
        } catch NotificationDatabaseError.layoutChanged(let missing, _) {
            return EngineSnapshot(access: .granted, problem: .layoutChanged(missing: missing))
        } catch NotificationDatabaseError.sqlite(let error)
            where error.primaryCode == SQLITE_AUTH || error.primaryCode == SQLITE_PERM {
            // SQLite runs into privacy protection on its own files (`-wal`, `-shm`) too.
            return EngineSnapshot(access: .denied, problem: .noAccess)
        } catch {
            return EngineSnapshot(access: .granted, problem: .readFailed(String(describing: error)))
        }
    }

    // MARK: - Queue-confined

    private func startWatching() {
        if stream == nil {
            let stream = FileEventStream(paths: [paths.directory.path], latency: 0.15, queue: queue) { [weak self] events in
                self?.handle(events)
            }
            if stream.start() {
                self.stream = stream
            }
        }
        if walWatcher == nil {
            walWatcher = FileWriteWatcher(path: paths.writeAheadLog.path, queue: queue) { [weak self] in
                self?.scheduleReload()
            }
        }
        // The log may not exist yet, or may not be readable yet; FSEvents and rescans rearm it.
        walWatcher?.rearm()
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

    private func updateAccessTimer() {
        let interval = waitingForAccess ? accessIntervals.waiting : accessIntervals.idle
        guard isActive, snapshot.access != .granted else {
            accessTimer?.cancel()
            accessTimer = nil
            return
        }
        guard accessTimer == nil || accessTimerInterval != interval else { return }
        accessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            if DatabaseAccess.check(self.paths.database) != self.snapshot.access {
                self.rescan()
            }
        }
        timer.resume()
        accessTimer = timer
        accessTimerInterval = interval
    }

    private func handle(_ events: [FileEventStream.Event]) {
        guard isActive else { return }
        let name = paths.database.lastPathComponent
        var changed = false
        var walChanged = false
        for event in events {
            if event.flags & FileEventStream.rescanFlags != 0 {
                changed = true
                walChanged = true
                continue
            }
            switch (event.path as NSString).lastPathComponent {
            case name + "-wal":
                // Created, removed or replaced: the kqueue watch may need to move to the new file.
                walChanged = true
                changed = true
            case name, name + "-journal":
                changed = true
            default:
                break
            }
        }
        if walChanged {
            walWatcher?.rearm()
        }
        if changed {
            scheduleReload()
        }
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        queue.asyncAfter(deadline: .now() + reloadDelay) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            guard self.isActive else { return }
            self.reload()
            self.publish()
        }
    }

    private func rescan() {
        startWatching()
        reload()
        publish()
    }

    private func reload() {
        let hadAccess = snapshot.access == .granted
        snapshot = Self.read(paths)
        if !hadAccess, snapshot.access == .granted {
            // A stream started without access may never report anything: start over with access.
            stream?.stop()
            stream = nil
            startWatching()
        }
        updateAccessTimer()
    }

    /// Publishes changes, and also an unchanged read when the last one published is 30 s old, so
    /// subscribers know how recent their view is (`readAt`).
    private func publish(force: Bool = false) {
        let refreshes = snapshot.readAt.map { read in
            lastPublished?.readAt.map { read.timeIntervalSince($0) >= Self.readAtRefresh } ?? true
        } ?? false
        guard force || snapshot != lastPublished || refreshes else { return }
        lastPublished = snapshot
        onChange(snapshot)
    }

    static let readAtRefresh: TimeInterval = 30
}
