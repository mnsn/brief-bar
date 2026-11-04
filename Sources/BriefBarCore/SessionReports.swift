import Foundation

// MARK: - The setting

/// Updates from Copilot Sessions, on the Agents page, which is off until you turn it on. Off, agents don't get its tools,
/// BriefBar shows nothing sessions told it and reads nothing sooner for them, and it forgets what they told.
public enum SessionUpdatesSetting {
    public static let defaultsKey = "sessionUpdates.enabled"

    public static func isOn(in defaults: some SettingsStorage) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

// MARK: - What a session told

/// What one Copilot session told BriefBar through its agents' tools: the work items and pull requests it's working on now
/// (`working_on`), and the pull requests it opened (`changed_in_azure_devops`). Only references and dates, never a title or
/// anything an agent wrote: BriefBar keeps only what Azure DevOps can't tell it, and reads the rest from Azure DevOps.
public struct SessionReport: Equatable, Sendable {
    public let session: ItemRef
    /// What it's working on, in the order it told them: nothing once it said it stopped.
    public private(set) var workingOn: [ItemRef] = []
    /// When it last told what it works on.
    public private(set) var workingOnSince: Date?
    /// The pull requests it said it opened, each with when it said so.
    public private(set) var opened: [ItemRef: Date] = [:]

    public init(session: ItemRef) {
        self.session = session
    }

    /// Whether it tells nothing, and so isn't kept.
    public var isEmpty: Bool { workingOn.isEmpty && opened.isEmpty }

    /// When it last told anything.
    public var lastTold: Date? {
        (opened.values.map { $0 } + [workingOnSince].compactMap { $0 }).max()
    }

    /// What it works on now, in place of what it said before: work items and pull requests, each once, the first
    /// `SessionReports.mostItems`; nothing when it stopped.
    public mutating func setWorkingOn(_ refs: [ItemRef], at date: Date) {
        var seen: Set<ItemRef> = []
        workingOn = Array(refs.filter { $0.kind != .session && seen.insert($0).inserted }.prefix(SessionReports.mostItems))
        workingOnSince = date
    }

    /// Pull requests it opened, with when it said so: the newest `SessionReports.mostOpened` are kept.
    public mutating func addOpened(_ refs: [ItemRef], at date: Date) {
        for ref in refs where ref.kind.isPullRequest {
            opened[ref] = date
        }
        guard opened.count > SessionReports.mostOpened else { return }
        let kept = opened.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(SessionReports.mostOpened)
        opened = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// Forgets what it said longer ago than BriefBar keeps it: what it works on, a week after it last said; a pull request
    /// it opened, 30 days after.
    public mutating func expire(now: Date) {
        if let since = workingOnSince, now.timeIntervalSince(since) > SessionReports.workingOnLifetime {
            workingOn = []
            workingOnSince = nil
        }
        opened = opened.filter { now.timeIntervalSince($0.value) <= SessionReports.openedLifetime }
    }

    /// Forgets these kinds of things, when their source is turned off.
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) {
        workingOn.removeAll { kinds.contains($0.kind) }
        opened = opened.filter { !kinds.contains($0.key.kind) }
    }
}

// MARK: - What sessions told

/// What every session told, each session's under its own key in the preferences (`sessionUpdates.session.<id>`): a
/// session's `--mcp` writes only its own, so that sessions telling at the same moment lose nothing, and the app reads
/// them all.
public struct SessionReports: Equatable, Sendable {
    public private(set) var reports: [ItemRef: SessionReport]

    public init(_ reports: [SessionReport] = []) {
        self.reports = Dictionary(reports.map { ($0.session, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// At most this many things a session works on, or that an agent names in one call.
    public static let mostItems = 20
    /// At most this many pull requests a session opened, the newest.
    public static let mostOpened = 50
    /// At most this many sessions' reports, those told longest ago dropped first.
    public static let mostSessions = 100
    /// What a session works on is forgotten a week after it last said.
    public static let workingOnLifetime: TimeInterval = 7 * 86_400
    /// A pull request a session opened is forgotten 30 days after it said so.
    public static let openedLifetime: TimeInterval = 30 * 86_400
    /// A session idle this long shows on nothing it works on, until it works again.
    public static let idleAfter: TimeInterval = 86_400

    public var isEmpty: Bool { reports.isEmpty }

    public subscript(session: ItemRef) -> SessionReport? { reports[session] }

    // MARK: What shows

    /// The sessions the Copilot source lists now, the app's and the tasks BriefBar sent, and when each one that's idle got
    /// there: what a session told shows only while it's listed, so what an archived session told goes with it.
    public struct Listing: Equatable, Sendable {
        public var sessions: Set<ItemRef>
        public var idleSince: [ItemRef: Date]

        public init(sessions: Set<ItemRef> = [], idleSince: [ItemRef: Date] = [:]) {
            self.sessions = sessions
            self.idleSince = idleSince
        }
    }

    /// What each listed session works on, as it told: nothing for one that's been idle for a day or more.
    public func workingOn(_ listing: Listing, now: Date) -> [ItemRef: [ItemRef]] {
        var working: [ItemRef: [ItemRef]] = [:]
        for (session, report) in reports where listing.sessions.contains(session) && !report.workingOn.isEmpty {
            if let idle = listing.idleSince[session], now.timeIntervalSince(idle) >= Self.idleAfter { continue }
            working[session] = report.workingOn
        }
        return working
    }

    /// The pull requests each listed session told it opened.
    public func opened(_ listing: Listing) -> [ItemRef: [ItemRef]] {
        var opened: [ItemRef: [ItemRef]] = [:]
        for (session, report) in reports where listing.sessions.contains(session) && !report.opened.isEmpty {
            opened[session] = report.opened.keys.sorted()
        }
        return opened
    }

    /// For Show Links: each listed session linked to what it works on (`LinkOrigin.session`), as `workingOn` shows it, and
    /// to the pull requests it opened, as the Copilot app's records of those are (`LinkOrigin.copilot`).
    public func links(_ listing: Listing, now: Date) -> [ItemLink] {
        var links: [ItemLink] = []
        for (session, refs) in workingOn(listing, now: now) {
            links += refs.compactMap { ItemLink(session, $0, origin: .session) }
        }
        for (session, refs) in opened(listing) {
            links += refs.compactMap { ItemLink(session, $0, origin: .copilot) }
        }
        return links
    }

    // MARK: Changing

    /// Forgets these kinds of things in every report, when their source is turned off.
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) {
        for session in Array(reports.keys) {
            reports[session]?.forget(kinds)
            if reports[session]?.isEmpty == true { reports[session] = nil }
        }
    }

    // MARK: Saving

    public static let keyPrefix = "sessionUpdates.session."

    /// Where a session's report is kept.
    public static func key(for session: ItemRef) -> String {
        keyPrefix + session.id
    }

    private struct Record: Codable {
        var session: String
        var workingOn: [String]
        var since: Date?
        var opened: [String: Date]
    }

    /// Every session's report, but what's past its time, which goes when it's next saved. A record that can't be read,
    /// such as one another program wrote, is skipped, and so is a reference in it that isn't one.
    public static func load(from defaults: some SettingsStorage, now: Date) -> SessionReports {
        var reports: [SessionReport] = []
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            guard var report = report(defaults.data(forKey: key)), Self.key(for: report.session) == key else { continue }
            report.expire(now: now)
            if !report.isEmpty { reports.append(report) }
        }
        return SessionReports(reports)
    }

    /// One session's report, as it's kept.
    public static func load(_ session: ItemRef, from defaults: some SettingsStorage) -> SessionReport? {
        report(defaults.data(forKey: key(for: session))).flatMap { $0.session == session ? $0 : nil }
    }

    private static func report(_ data: Data?) -> SessionReport? {
        guard let data, let record = try? JSONDecoder().decode(Record.self, from: data),
              let session = ItemRef(record.session), session.kind == .session
        else { return nil }
        var report = SessionReport(session: session)
        let workingOn = record.workingOn.compactMap(ItemRef.init)
        if let since = record.since { report.setWorkingOn(workingOn, at: since) }
        for (text, date) in record.opened {
            if let ref = ItemRef(text) { report.addOpened([ref], at: date) }
        }
        return report
    }

    /// Keeps a session's report under its own key, or takes the key away once it tells nothing.
    public static func save(_ report: SessionReport, to defaults: some SettingsStorage) {
        let key = key(for: report.session)
        guard !report.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let record = Record(
            session: report.session.description, workingOn: report.workingOn.map(\.description), since: report.workingOnSince,
            opened: Dictionary(report.opened.map { ($0.key.description, $0.value) }, uniquingKeysWith: { first, _ in first })
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(record) {
            defaults.set(data, forKey: key)
        }
    }

    /// Changes what a session told, as `--mcp` does, and saves it at once, its key alone; and, with more than
    /// `mostSessions` kept, forgets those that told longest ago.
    @discardableResult
    public static func change(
        _ session: ItemRef, in defaults: some SettingsStorage, now: Date, _ body: (inout SessionReport) throws -> Void
    ) rethrows -> SessionReport {
        var report = load(session, from: defaults) ?? SessionReport(session: session)
        report.expire(now: now)
        try body(&report)
        save(report, to: defaults)
        let others = load(from: defaults, now: now).reports.values.filter { $0.session != session }
        let kept = others.count + (report.isEmpty ? 0 : 1)
        if kept > mostSessions {
            let oldest = others.sorted { ($0.lastTold ?? .distantPast, $0.session) < ($1.lastTold ?? .distantPast, $1.session) }
            for old in oldest.prefix(kept - mostSessions) {
                defaults.removeObject(forKey: key(for: old.session))
            }
        }
        return report
    }

    /// Forgets these kinds of things in every report kept, when their source is turned off.
    public static func forget(_ kinds: Set<ItemRef.Kind>, in defaults: some SettingsStorage, now: Date) {
        for var report in load(from: defaults, now: now).reports.values {
            let before = report
            report.forget(kinds)
            if report != before { save(report, to: defaults) }
        }
    }

    /// Forgets every report, and what agents asked to read again.
    public static func forgetAll(in defaults: some SettingsStorage) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(keyPrefix) || key.hasPrefix(RereadRequests.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - What to read again

/// What agents said they just changed in Azure DevOps (`changed_in_azure_devops`), for the app to read again sooner than
/// its next refresh: each `--mcp` keeps its own under a key of its own (`sessionUpdates.rereads.<id>`), so that two
/// writing at once lose nothing, for ten minutes; the app takes what's new as an agent's change arrives.
public enum RereadRequests {
    public struct Request: Equatable, Sendable {
        public var ref: ItemRef
        public var at: Date

        public init(ref: ItemRef, at: Date) {
            self.ref = ref
            self.at = at
        }
    }

    public static let keyPrefix = "sessionUpdates.rereads."
    /// How long a request is kept for the app to take.
    public static let lifetime: TimeInterval = 600
    /// At most this many kept for one `--mcp`, the newest.
    public static let most = 50

    private struct Record: Codable {
        var ref: String
        var at: Date
    }

    /// Adds to what one `--mcp` asked, under its own key, without what's older than `lifetime`: the newest `most`.
    /// - Parameter id: the `--mcp`'s own, made as it starts.
    public static func add(_ refs: [ItemRef], id: String, to defaults: some SettingsStorage, now: Date) {
        let key = keyPrefix + id
        var requests = requests(defaults.data(forKey: key)).filter { now.timeIntervalSince($0.at) < lifetime }
        requests += refs.map { Request(ref: $0, at: now) }
        requests = Array(requests.suffix(most))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(requests.map { Record(ref: $0.ref.description, at: $0.at) }) {
            defaults.set(data, forKey: key)
        }
    }

    /// What every `--mcp` asked after `date`, the oldest first; and takes away the keys of those that asked nothing for
    /// `lifetime`, such as one that ended.
    public static func take(after date: Date, from defaults: some SettingsStorage, now: Date) -> [Request] {
        var taken: [Request] = []
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            let requests = requests(defaults.data(forKey: key))
            guard let newest = requests.map(\.at).max(), now.timeIntervalSince(newest) < lifetime else {
                defaults.removeObject(forKey: key)
                continue
            }
            taken += requests.filter { $0.at > date && now.timeIntervalSince($0.at) < lifetime }
        }
        return taken.sorted { ($0.at, $0.ref) < ($1.at, $1.ref) }
    }

    private static func requests(_ data: Data?) -> [Request] {
        guard let data, let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records.compactMap { record in ItemRef(record.ref).map { Request(ref: $0, at: record.at) } }
    }
}
