import Foundation

// MARK: - What one session set

/// The stages one Copilot session set on pull requests it works on, through `pull_request_stage`: each pull request's,
/// with when, and of what it was set over only what would end it, as a stage you set keeps (`StageRules.mark`). Only
/// references, codes and dates, never a title or anything an agent wrote. Only Azure DevOps' pull requests have stages
/// for now, and a session sets only the stages you can (`PullRequestStage.settable`).
public struct SessionStage: Equatable, Sendable {
    public let session: ItemRef
    /// Each pull request's stage, as this session set it: each mark says it's this session's (`StageMark.by`).
    public private(set) var marks: [ItemRef: StageMark] = [:]

    public init(session: ItemRef) {
        self.session = session
    }

    /// Whether it sets nothing, and so isn't kept.
    public var isEmpty: Bool { marks.isEmpty }

    /// When it last set one.
    public var lastSet: Date? { marks.values.map(\.at).max() }

    /// Sets a pull request's stage, in place of what this session set on it before: only a stage you can set, on a pull
    /// request, as this session's. The newest `SessionStages.mostPullRequests` are kept.
    public mutating func set(_ mark: StageMark, of ref: ItemRef) {
        guard ref.kind.isPullRequest, mark.stage.isSettable else { return }
        var mark = mark
        mark.by = session
        marks[ref] = mark
        guard marks.count > SessionStages.mostPullRequests else { return }
        let kept = marks.sorted { ($0.value.at, $1.key) > ($1.value.at, $0.key) }.prefix(SessionStages.mostPullRequests)
        marks = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// Takes away what this session set on a pull request: true when it had set something.
    @discardableResult
    public mutating func clear(_ ref: ItemRef) -> Bool {
        marks.removeValue(forKey: ref) != nil
    }

    /// Forgets what it set longer ago than BriefBar keeps it: 30 days, as a pull request a session opened.
    public mutating func expire(now: Date) {
        marks = marks.filter { now.timeIntervalSince($0.value.at) <= SessionStages.lifetime }
    }

    /// Forgets what it set on these kinds of things, when their source is turned off.
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) {
        marks = marks.filter { !kinds.contains($0.key.kind) }
    }
}

// MARK: - What sessions set

/// The stages every session set, each session's under its own key in the preferences (`order.stage.<id>`), as what
/// sessions tell is kept (`SessionReports`): a session's `--mcp` writes only its own, so that sessions setting stages at the
/// same moment lose nothing, and the app reads them all, found by their keys' start. What a session set shows only while
/// the Copilot app lists it (`marks(listed:now:)`), so what an archived session set goes with it. The app takes away one
/// that no longer stands, or whose pull request merged or closed (`end`), so that it doesn't come back, and what's past
/// its time (`prune`). Turning Pull Request Order off keeps them; turning Azure DevOps or GitHub Copilot off forgets them,
/// as does Forget Stages….
public struct SessionStages: Equatable, Sendable {
    public private(set) var sessions: [ItemRef: SessionStage]

    public init(_ sessions: [SessionStage] = []) {
        self.sessions = Dictionary(
            sessions.filter { !$0.isEmpty }.map { ($0.session, $0) }, uniquingKeysWith: { first, _ in first }
        )
    }

    /// At most this many pull requests' stages for one session, the newest.
    public static let mostPullRequests = SessionReports.mostOpened
    /// At most this many sessions', those that set one longest ago dropped first.
    public static let mostSessions = SessionReports.mostSessions
    /// What a session set is forgotten 30 days after it set it.
    public static let lifetime: TimeInterval = SessionReports.openedLifetime
    /// At most this many pull requests in one call.
    public static let mostAtOnce = SessionReports.mostItems

    public var isEmpty: Bool { sessions.isEmpty }

    public subscript(session: ItemRef) -> SessionStage? { sessions[session] }

    /// What the listed sessions set on each pull request, but what's past its time, the earliest first: each mark says
    /// which session set it.
    public func marks(listed: Set<ItemRef>, now: Date) -> [ItemRef: [StageMark]] {
        var marks: [ItemRef: [StageMark]] = [:]
        for (session, var stage) in sessions where listed.contains(session) {
            stage.expire(now: now)
            for (ref, mark) in stage.marks { marks[ref, default: []].append(mark) }
        }
        return marks.mapValues { marks in
            marks.sorted { lhs, rhs in lhs.at != rhs.at ? lhs.at < rhs.at : (lhs.by?.id ?? "") < (rhs.by?.id ?? "") }
        }
    }

    /// Forgets what sessions set on these kinds of things, when their source is turned off: everything, with GitHub
    /// Copilot's sessions.
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) {
        if kinds.contains(.session) {
            sessions = [:]
            return
        }
        for session in Array(sessions.keys) {
            sessions[session]?.forget(kinds)
            if sessions[session]?.isEmpty == true { sessions[session] = nil }
        }
    }

    /// Takes away what a session set on a pull request, set then, as `end` does with what's kept: true when it did.
    @discardableResult
    public mutating func remove(_ ref: ItemRef, of session: ItemRef, setAt date: Date) -> Bool {
        guard var stage = sessions[session], stage.marks[ref]?.at == date else { return false }
        stage.clear(ref)
        sessions[session] = stage.isEmpty ? nil : stage
        return true
    }

    /// Sets what a session set, in place of what it had: for the demo's sessions, which BriefBar keeps in memory.
    public mutating func replace(_ stage: SessionStage) {
        sessions[stage.session] = stage.isEmpty ? nil : stage
    }

    // MARK: Saving

    public static let keyPrefix = "order.stage."

    /// Where a session's stages are kept.
    public static func key(for session: ItemRef) -> String {
        keyPrefix + session.id
    }

    private struct Record: Codable {
        var session: String
        var stages: [Lossy]
    }

    private struct Entry: Codable {
        var pullRequest: String
        var stage: PullRequestStage
        var at: Date
        var votes: String?
        var commit: String?
    }

    /// One that can be read, or none, so that one BriefBar can't read, such as a stage of a later version's, drops alone.
    private struct Lossy: Codable {
        var value: Entry?

        init(_ value: Entry) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Entry.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    /// Every session's stages, but what's past its time, which goes when it's next saved or pruned. A record that can't be
    /// read, such as one another program wrote, is skipped, and so is an entry in it that isn't one.
    public static func load(from defaults: some SettingsStorage, now: Date) -> SessionStages {
        var stages: [SessionStage] = []
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            guard var stage = stage(defaults.data(forKey: key)), Self.key(for: stage.session) == key else { continue }
            stage.expire(now: now)
            if !stage.isEmpty { stages.append(stage) }
        }
        return SessionStages(stages)
    }

    /// One session's stages, as they're kept.
    public static func load(_ session: ItemRef, from defaults: some SettingsStorage) -> SessionStage? {
        stage(defaults.data(forKey: key(for: session))).flatMap { $0.session == session ? $0 : nil }
    }

    private static func stage(_ data: Data?) -> SessionStage? {
        guard let data, let record = try? JSONDecoder().decode(Record.self, from: data),
              let session = ItemRef(record.session), session.kind == .session
        else { return nil }
        var stage = SessionStage(session: session)
        for entry in record.stages.compactMap(\.value) {
            guard let ref = ItemRef(entry.pullRequest) else { continue }
            stage.set(StageMark(stage: entry.stage, at: entry.at, votes: entry.votes, commit: entry.commit), of: ref)
        }
        return stage
    }

    /// Keeps a session's stages under its own key, or takes the key away once it sets nothing.
    public static func save(_ stage: SessionStage, to defaults: some SettingsStorage) {
        let key = key(for: stage.session)
        guard !stage.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let entries = stage.marks.sorted { $0.key < $1.key }.map { ref, mark in
            Lossy(Entry(pullRequest: ref.description, stage: mark.stage, at: mark.at, votes: mark.votes, commit: mark.commit))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(Record(session: stage.session.description, stages: entries)) {
            defaults.set(data, forKey: key)
        }
    }

    /// Takes away from what's kept what's past its time: a record that changes by it is saved again, or taken away once it
    /// sets nothing, but only if it's still as it was read, so that a session setting a stage at that moment loses nothing,
    /// as far as the preferences, which have no transactions, allow. A record that can't be read is left alone.
    public static func prune(in defaults: some SettingsStorage, now: Date) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            let data = defaults.data(forKey: key)
            guard var stage = stage(data), Self.key(for: stage.session) == key else { continue }
            let kept = stage
            stage.expire(now: now)
            guard stage != kept, defaults.data(forKey: key) == data else { continue }
            save(stage, to: defaults)
        }
    }

    /// Takes away what a session set on a pull request once the app sees it no longer stands, or its pull request merged or
    /// closed, so that it doesn't come back: only the mark it read, set then, and only if the session's record is still as
    /// it was read. True when it took it away.
    @discardableResult
    public static func end(_ ref: ItemRef, of session: ItemRef, setAt date: Date, in defaults: some SettingsStorage) -> Bool {
        let key = key(for: session)
        let data = defaults.data(forKey: key)
        guard var stage = stage(data), stage.session == session, stage.marks[ref]?.at == date else { return false }
        stage.clear(ref)
        guard defaults.data(forKey: key) == data else { return false }
        save(stage, to: defaults)
        return true
    }

    /// Changes what a session set, as its `--mcp` does, and saves it at once, its key alone; and, with more than
    /// `mostSessions` kept, forgets those that set one longest ago, once what's past its time is gone.
    @discardableResult
    public static func change(
        _ session: ItemRef, in defaults: some SettingsStorage, now: Date, _ body: (inout SessionStage) throws -> Void
    ) rethrows -> SessionStage {
        prune(in: defaults, now: now)
        var stage = load(session, from: defaults) ?? SessionStage(session: session)
        stage.expire(now: now)
        try body(&stage)
        save(stage, to: defaults)
        let others = load(from: defaults, now: now).sessions.values.filter { $0.session != session }
        let kept = others.count + (stage.isEmpty ? 0 : 1)
        if kept > mostSessions {
            let oldest = others.sorted { ($0.lastSet ?? .distantPast, $0.session) < ($1.lastSet ?? .distantPast, $1.session) }
            for old in oldest.prefix(kept - mostSessions) {
                defaults.removeObject(forKey: key(for: old.session))
            }
        }
        return stage
    }

    /// Forgets what sessions set on these kinds of things in every record kept, when their source is turned off: every
    /// record, with GitHub Copilot's sessions.
    public static func forget(_ kinds: Set<ItemRef.Kind>, in defaults: some SettingsStorage, now: Date) {
        guard !kinds.contains(.session) else { return forgetAll(in: defaults) }
        for var stage in load(from: defaults, now: now).sessions.values {
            let before = stage
            stage.forget(kinds)
            if stage != before { save(stage, to: defaults) }
        }
    }

    /// Whether any session's stages are kept, whether they still show or not: for Forget Stages….
    public static func keepsAny(in defaults: some SettingsStorage) -> Bool {
        defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(keyPrefix) }
    }

    /// Forget Stages…: every session's.
    public static func forgetAll(in defaults: some SettingsStorage) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
