import BriefBarCore
import Foundation
import NotificationCenterDB

/// Everything BriefBar knows of Teams' read markers at one point in time.
public struct ReadMarkerSnapshot: Sendable, Equatable {
    public var access: AccessStatus
    /// Each chat's read marker, by conversation ID.
    public var markers: [String: ReadMarker]
    public var report: ReadMarkerReport
    /// When the read that produced this started. Not part of equality, so an unchanged read isn't news.
    public var readAt: Date?

    public init(
        access: AccessStatus = .missing, markers: [String: ReadMarker] = [:], report: ReadMarkerReport = ReadMarkerReport(),
        readAt: Date? = nil
    ) {
        self.access = access
        self.markers = markers
        self.report = report
        self.readAt = readAt
    }

    public static func == (a: ReadMarkerSnapshot, b: ReadMarkerSnapshot) -> Bool {
        a.access == b.access && a.markers == b.markers && a.report == b.report
    }

    /// Teams' data was found, but not understood. Not having access says nothing new: Notification Center needs the
    /// same access, and says so.
    public var problem: PulseProblem? {
        access == .granted ? report.problem : nil
    }
}

/// Watches Teams' IndexedDB folders and publishes each chat's read marker whenever one changes.
///
/// LevelDB keeps its log open and appends every write to it, so, as with Notification Center's database, a kqueue watch
/// on the log reports writes as they happen, and FSEvents on the folder reports the log being replaced, as LevelDB moves
/// its writes into tables. Only the bytes appended since the last read are read, after `reloadDelay` to combine
/// bursts. A folder is read again from scratch when its log is replaced or its databases change, and every
/// `safetyInterval`, which also finds Teams' folders once it's signed in; that read skips every table block that can't
/// hold a conversation.
///
/// All mutable state is confined to `queue`; `onChange` is called on that queue.
public final class ReadMarkerEngine: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (ReadMarkerSnapshot) -> Void

    public let location: TeamsCacheLocation
    private let queue: DispatchQueue
    private let onChange: ChangeHandler
    private let reloadDelay: TimeInterval
    private let safetyInterval: TimeInterval
    private let confirmationDelay: TimeInterval

    private var folders: [URL: TeamsCacheFolder] = [:]
    private var unreadableFolders = 0
    /// Tables that couldn't be read at the last scan, by path, as they were then. LevelDB writes a table where it'll
    /// stay, so one being written reads as broken: only one still the same, and still unreadable, a while later counts.
    private var suspectTables: [String: FileInfo] = [:]
    private var unreadableTables = 0
    private var confirmationScheduled = false
    private var streams: [URL: FileEventStream] = [:]
    private var logWatchers: [URL: FileWriteWatcher] = [:]
    private var snapshot = ReadMarkerSnapshot()
    private var lastPublished: ReadMarkerSnapshot?
    private var safetyTimer: DispatchSourceTimer?
    private var readScheduled = false
    private var isActive = false

    public init(
        location: TeamsCacheLocation,
        reloadDelay: TimeInterval = 0.5,
        safetyInterval: TimeInterval = 600,
        confirmationDelay: TimeInterval = 5,
        onChange: @escaping ChangeHandler
    ) {
        self.location = location
        queue = DispatchQueue(label: "BriefBar.Teams.ReadMarkerEngine", qos: .utility)
        self.reloadDelay = reloadDelay
        self.safetyInterval = safetyInterval
        self.confirmationDelay = confirmationDelay
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard !isActive else { return }
            isActive = true
            rescan()
            publish(force: true)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + safetyInterval, repeating: safetyInterval, leeway: .seconds(30))
            timer.setEventHandler { [weak self] in
                guard let self, self.isActive else { return }
                self.rescan()
                self.publish()
            }
            timer.resume()
            safetyTimer = timer
        }
    }

    public func stop() {
        queue.async { [self] in
            isActive = false
            safetyTimer?.cancel()
            safetyTimer = nil
            folders = [:]
            watch()
        }
    }

    /// Reads every folder again, and publishes if anything changed.
    public func refresh() {
        queue.async { [self] in
            guard isActive else { return }
            rescan()
            publish()
        }
    }

    /// One read, without watching (command line and tests). Tables that can't be read count as such at once.
    public static func loadOnce(location: TeamsCacheLocation) -> ReadMarkerSnapshot {
        let engine = ReadMarkerEngine(location: location) { _ in }
        engine.rescan()
        engine.unreadableTables = engine.suspectTables.count
        return engine.makeSnapshot(access: engine.snapshot.access, readAt: engine.snapshot.readAt ?? Date())
    }

    // MARK: - Queue-confined

    private func rescan() {
        let started = Date()
        let access = location.access()
        var current: [URL: TeamsCacheFolder] = [:]
        unreadableFolders = 0
        if access == .granted {
            for url in location.folders() {
                var folder = TeamsCacheFolder(url)
                do {
                    try folder.scan()
                    current[url] = folder
                } catch {
                    unreadableFolders += 1
                }
            }
        }
        folders = current
        confirmUnreadableTables()
        if isActive {
            watch()
        }
        snapshot = makeSnapshot(access: access, readAt: started)
    }

    /// Counts the tables that couldn't be read at this scan and the one before, unchanged; for the others, scans again
    /// a little later, by when LevelDB has finished writing a table it was.
    private func confirmUnreadableTables() {
        var current: [String: FileInfo] = [:]
        for folder in folders.values {
            for (name, info) in folder.unreadableTables {
                current[folder.folder.url.appendingPathComponent(name).path] = info
            }
        }
        unreadableTables = current.filter { suspectTables[$0.key] == $0.value }.count
        suspectTables = current
        guard isActive, current.count > unreadableTables, !confirmationScheduled else { return }
        confirmationScheduled = true
        queue.asyncAfter(deadline: .now() + confirmationDelay) { [weak self] in
            guard let self else { return }
            self.confirmationScheduled = false
            guard self.isActive else { return }
            self.rescan()
            self.publish()
        }
    }

    /// Reads on in each folder's log; reads a folder again from scratch when that's needed.
    private func readLogs() {
        let started = Date()
        var rescans = false
        for url in folders.keys {
            if folders[url]?.readLog() == .rescan {
                rescans = true
            }
        }
        if rescans {
            rescan()
        } else {
            snapshot = makeSnapshot(access: snapshot.access, readAt: started)
        }
    }

    private func makeSnapshot(access: AccessStatus, readAt: Date) -> ReadMarkerSnapshot {
        var markers: [String: ReadMarker] = [:]
        var report = ReadMarkerReport()
        for folder in folders.values {
            markers.merge(folder.markers) { $0.messageID >= $1.messageID ? $0 : $1 }
            report.add(folder.report)
        }
        report.folders += unreadableFolders
        report.unreadableFiles = unreadableTables + unreadableFolders
        return ReadMarkerSnapshot(access: access, markers: markers, report: report, readAt: readAt)
    }

    /// Watches each folder, and the log it's written to now; stops watching folders that are gone.
    private func watch() {
        for url in streams.keys where folders[url] == nil {
            streams.removeValue(forKey: url)?.stop()
        }
        for url in logWatchers.keys where folders[url]?.log == nil {
            logWatchers.removeValue(forKey: url)?.cancel()
        }
        for (url, folder) in folders {
            if streams[url] == nil {
                let stream = FileEventStream(paths: [url.path], latency: 0.3, queue: queue) { [weak self] events in
                    self?.handle(events)
                }
                if stream.start() {
                    streams[url] = stream
                }
            }
            guard let log = folder.log else { continue }
            if logWatchers[url]?.path != log.url.path {
                logWatchers[url]?.cancel()
                logWatchers[url] = FileWriteWatcher(path: log.url.path, queue: queue) { [weak self] in
                    self?.scheduleRead()
                }
            }
            logWatchers[url]?.rearm()
        }
    }

    private func handle(_ events: [FileEventStream.Event]) {
        guard isActive else { return }
        // LevelDB's own account of what it did, and its lock, say nothing about the data.
        let relevant = events.contains { event in
            event.flags & FileEventStream.rescanFlags != 0
                || !["LOG", "LOG.old", "LOCK"].contains((event.path as NSString).lastPathComponent)
        }
        if relevant {
            scheduleRead()
        }
    }

    private func scheduleRead() {
        guard !readScheduled else { return }
        readScheduled = true
        queue.asyncAfter(deadline: .now() + reloadDelay) { [weak self] in
            guard let self else { return }
            self.readScheduled = false
            guard self.isActive else { return }
            self.readLogs()
            self.publish()
        }
    }

    private func publish(force: Bool = false) {
        guard force || snapshot != lastPublished else { return }
        lastPublished = snapshot
        onChange(snapshot)
    }
}
