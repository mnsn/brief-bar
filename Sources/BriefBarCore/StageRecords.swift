import Foundation

/// The stages you set, in BriefBar's preferences, for each Azure DevOps account you sign in with, as what you've seen is:
/// one key, `order.stages`, which only the app writes, of references, stages and dates, and of what a stage was set over
/// only what would end it (`StageRules.mark`): the commit, for In progress and for Teammate's review on someone else's;
/// the votes, for Teammate's review alone, on yours a digest of the votes others cast, how many of each, never who cast
/// them, and on someone else's your own vote. A pull request listed only because someone sent it to you isn't kept here:
/// its stage stays in memory (`PullRequestOrder`). One goes once it no longer stands, its pull request merges or closes,
/// or no list has had it for 30 days; turning a source off forgets its own, and Forget Stages… all of them. At most 500
/// for each account, counting those `PullRequestOrder` keeps in memory for it: past that, a new one is refused, never
/// one dropped to make room.
public struct StageMarks: Equatable, Sendable {
    public static let defaultsKey = "order.stages"
    public static let mostPerAccount = 500
    /// How long one stays once no list has its pull request.
    public static let unlistedFor: TimeInterval = 30 * 86_400
    /// How seldom it notes that a list still has a pull request, so that a list read every minute doesn't write each time.
    static let listedEvery: TimeInterval = 86_400

    public struct Entry: Equatable, Sendable {
        public var mark: StageMark
        /// When a list last had its pull request, as `listed` notes it.
        public var listedAt: Date

        public init(mark: StageMark, listedAt: Date) {
            self.mark = mark
            self.listedAt = listedAt
        }

        /// Whether no list has had its pull request for 30 days, so it goes.
        public func isUnlisted(at now: Date) -> Bool {
            now.timeIntervalSince(listedAt) > StageMarks.unlistedFor
        }
    }

    /// Each account's, by its name lowercased, then by pull request.
    public private(set) var accounts: [String: [ItemRef: Entry]]

    public init(accounts: [String: [ItemRef: Entry]] = [:]) {
        var kept: [String: [ItemRef: Entry]] = [:]
        for (account, entries) in accounts {
            let mine = entries.filter { $0.key.kind.isPullRequest && $0.value.mark.isYours && $0.value.mark.stage.isSettable }
            if !mine.isEmpty { kept[account.lowercased(), default: [:]].merge(mine) { first, _ in first } }
        }
        self.accounts = kept
    }

    public var isEmpty: Bool { accounts.values.allSatisfy(\.isEmpty) }

    /// The stage you set for a pull request, with this account.
    public func mark(of ref: ItemRef, for account: String) -> StageMark? {
        entry(of: ref, for: account)?.mark
    }

    /// The stage you set for a pull request, with this account, and when a list last had it.
    public func entry(of ref: ItemRef, for account: String) -> Entry? {
        accounts[account.lowercased()]?[ref]
    }

    /// How many this account keeps.
    public func count(for account: String) -> Int {
        accounts[account.lowercased()]?.count ?? 0
    }

    /// Sets yours, in place of the one it had: false, keeping nothing, when the account has the most already and this is a
    /// new one.
    /// - Parameter now: when a list last had it: now, or when it did while it was kept elsewhere.
    public mutating func set(_ mark: StageMark, of ref: ItemRef, for account: String, at now: Date) -> Bool {
        guard ref.kind.isPullRequest, mark.isYours, mark.stage.isSettable else { return false }
        let account = account.lowercased()
        var entries = accounts[account] ?? [:]
        guard entries[ref] != nil || entries.count < Self.mostPerAccount else { return false }
        entries[ref] = Entry(mark: mark, listedAt: now)
        accounts[account] = entries
        return true
    }

    /// Forgets yours for a pull request: true when there was one.
    @discardableResult
    public mutating func clear(_ ref: ItemRef, for account: String) -> Bool {
        let account = account.lowercased()
        guard accounts[account]?.removeValue(forKey: ref) != nil else { return false }
        if accounts[account]?.isEmpty == true { accounts[account] = nil }
        return true
    }

    /// Notes that a list has these now, at most once a day for each: true when that changed what's kept.
    public mutating func listed(_ refs: Set<ItemRef>, for account: String, at now: Date) -> Bool {
        let account = account.lowercased()
        guard var entries = accounts[account] else { return false }
        var changed = false
        for ref in refs {
            guard let entry = entries[ref], now.timeIntervalSince(entry.listedAt) >= Self.listedEvery else { continue }
            entries[ref]?.listedAt = now
            changed = true
        }
        if changed { accounts[account] = entries }
        return changed
    }

    /// Forgets those of these kinds that no list has had for 30 days, with every account: true when it forgot any.
    /// - Parameter kinds: those whose sources have listed what they show, so that a list could have noted that it has them.
    public mutating func forgetUnlisted(now: Date, of kinds: Set<ItemRef.Kind>) -> Bool {
        forget { kinds.contains($0.key.kind) && $0.value.isUnlisted(at: now) }
    }

    /// Forgets the stages of the sources you turned off, with every account: true when it forgot any.
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) -> Bool {
        forget { kinds.contains($0.key.kind) }
    }

    private mutating func forget(where isForgotten: ((key: ItemRef, value: Entry)) -> Bool) -> Bool {
        var changed = false
        for (account, entries) in accounts {
            let kept = entries.filter { !isForgotten($0) }
            guard kept.count != entries.count else { continue }
            accounts[account] = kept.isEmpty ? nil : kept
            changed = true
        }
        return changed
    }

    // MARK: Kept

    private struct Saved: Codable {
        var account: String
        var pullRequest: ItemRef
        var stage: PullRequestStage
        var at: Date
        var votes: String?
        var commit: String?
        var listedAt: Date
    }

    /// One that can be read, or none, so that one BriefBar can't read, such as a stage of a later version's, drops alone.
    private struct Lossy: Decodable {
        var value: Saved?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Saved.self)
        }
    }

    /// What was saved, without what can't be read.
    public static func load(from defaults: some SettingsStorage) -> StageMarks {
        guard let data = defaults.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode([Lossy].self, from: data)
        else { return StageMarks() }
        var accounts: [String: [ItemRef: Entry]] = [:]
        for record in saved.compactMap(\.value) where accounts[record.account.lowercased()]?[record.pullRequest] == nil {
            let mark = StageMark(stage: record.stage, at: record.at, votes: record.votes, commit: record.commit)
            accounts[record.account.lowercased(), default: [:]][record.pullRequest] = Entry(mark: mark, listedAt: record.listedAt)
        }
        return StageMarks(accounts: accounts)
    }

    public func save(to defaults: some SettingsStorage) {
        guard !isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        var saved: [Saved] = []
        for account in accounts.keys.sorted() {
            for (ref, entry) in (accounts[account] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let mark = entry.mark
                saved.append(Saved(
                    account: account, pullRequest: ref, stage: mark.stage, at: mark.at, votes: mark.votes, commit: mark.commit,
                    listedAt: entry.listedAt
                ))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(saved) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Forget Stages…: every stage you set, with every account, whether Pull Request Order is on or not.
    public static func forgetAll(in defaults: some SettingsStorage) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// How far each of your pull requests got, as BriefBar worked its stage out itself (`StageRules.worked`), in BriefBar's
/// preferences, for each Azure DevOps account you sign in with, as the stages you set are (`StageMarks`): one key,
/// `order.reached`, which only the app writes, of references, stages, when each got there, whether that's where BriefBar
/// first kept it before it knew of a session writing it, and when a list last had it, and nothing else: so that BriefBar
/// never moves one back on its own, as a failed build, or a session that writes it again, would, but where it loses what
/// its stage stands for. Only Your review, Teammate's review, Approved and Can merge, Waits kept as Can merge;
/// one in progress keeps none. One goes once its pull request merges, closes or is a draft again, or no list has had it for
/// 30 days; turning a source off forgets its own, and Forget Stages… all of them. At most 500 for each account: past
/// that, a new one isn't kept, and BriefBar works its stage out from what its source shows alone.
public struct StagesReached: Equatable, Sendable {
    public static let defaultsKey = "order.reached"
    public static let mostPerAccount = StageMarks.mostPerAccount
    /// The stages it keeps.
    public static let kept: Set<PullRequestStage> = [.yourReview, .teammateReview, .approved, .canMerge]
    /// How long one BriefBar first kept before it knew of a session writing it may still be that session's
    /// (`StageReach.isFirst`): Azure DevOps can list a pull request before the Copilot app tells which session opened it,
    /// which it does within seconds.
    public static let firstSight: TimeInterval = 10 * 60

    public struct Entry: Equatable, Sendable {
        public var stage: PullRequestStage
        /// When it got there, as its stage said then; where BriefBar first kept it (`isFirst`), when it did, which
        /// `firstSight` counts from (`StageReach.since`).
        public var since: Date
        /// It's where BriefBar first kept it, before it knew of a session writing it, and nothing moved it since
        /// (`StageReach.isFirst`).
        public var isFirst: Bool
        /// When a list last had its pull request, as `listed` notes it.
        public var listedAt: Date

        public init(stage: PullRequestStage, since: Date, isFirst: Bool = false, listedAt: Date) {
            self.stage = stage
            self.since = since
            self.isFirst = isFirst
            self.listedAt = listedAt
        }

        /// Whether no list has had its pull request for 30 days, so it goes.
        public func isUnlisted(at now: Date) -> Bool {
            now.timeIntervalSince(listedAt) > StageMarks.unlistedFor
        }
    }

    /// Each account's, by its name lowercased, then by pull request.
    public private(set) var accounts: [String: [ItemRef: Entry]]

    public init(accounts: [String: [ItemRef: Entry]] = [:]) {
        var kept: [String: [ItemRef: Entry]] = [:]
        for (account, entries) in accounts {
            let reached = entries.filter { $0.key.kind.isPullRequest && Self.kept.contains($0.value.stage) }
            if !reached.isEmpty { kept[account.lowercased(), default: [:]].merge(reached) { first, _ in first } }
        }
        self.accounts = kept
    }

    public var isEmpty: Bool { accounts.values.allSatisfy(\.isEmpty) }

    /// How far a pull request got, with this account, and since when; nil for one that got no further than In progress, or
    /// that BriefBar keeps nothing of. Where BriefBar first kept it only for `firstSight`.
    public func reach(of ref: ItemRef, for account: String, at now: Date) -> StageReach? {
        accounts[account.lowercased()]?[ref].map { entry in
            StageReach(entry.stage, since: entry.since, isFirst: entry.isFirst && now.timeIntervalSince(entry.since) < Self.firstSight)
        }
    }

    /// How many this account keeps.
    public func count(for account: String) -> Int {
        accounts[account.lowercased()]?.count ?? 0
    }

    /// Keeps how far a pull request got now, in place of what it kept, or forgets it, for nil or a stage it doesn't keep:
    /// true when that changed what's kept. A new one isn't kept once the account keeps the most.
    /// - Parameters:
    ///   - now: when a list last had it; and when it got there, for one kept where BriefBar first saw it, or where
    ///     `since` doesn't say.
    ///   - since: when it got there, for a stage it didn't keep, as its stage says, such as when the session that wrote
    ///     it finished, which BriefBar may hear of later: so one a session writes again keeps how long it waited for
    ///     your review.
    ///   - knowsSessions: BriefBar knows of a session writing it, at work or done, not one whose end it can't tell, or
    ///     something moved it, as a stage set on it that ended: where it keeps it first isn't where it first saw it before it
    ///     knew of them, and where it kept it before stops being that.
    @discardableResult
    public mutating func set(
        _ stage: PullRequestStage?, of ref: ItemRef, for account: String, at now: Date, since: Date? = nil,
        knowsSessions: Bool = false
    ) -> Bool {
        let account = account.lowercased()
        var entries = accounts[account] ?? [:]
        guard let stage, Self.kept.contains(stage), ref.kind.isPullRequest else {
            guard entries.removeValue(forKey: ref) != nil else { return false }
            accounts[account] = entries.isEmpty ? nil : entries
            return true
        }
        let isNew = entries[ref] == nil
        if let entry = entries[ref] {
            guard entry.stage != stage else {
                guard knowsSessions, entry.isFirst else { return false }
                entries[ref]?.isFirst = false
                accounts[account] = entries
                return true
            }
        } else if entries.count >= Self.mostPerAccount {
            return false
        }
        let isFirst = isNew && !knowsSessions
        entries[ref] = Entry(stage: stage, since: isFirst ? now : since ?? now, isFirst: isFirst, listedAt: now)
        accounts[account] = entries
        return true
    }

    /// Notes that a list has these now, at most once a day for each, as `StageMarks.listed` does: true when that changed
    /// what's kept.
    public mutating func listed(_ refs: Set<ItemRef>, for account: String, at now: Date) -> Bool {
        let account = account.lowercased()
        guard var entries = accounts[account] else { return false }
        var changed = false
        for ref in refs {
            guard let entry = entries[ref], now.timeIntervalSince(entry.listedAt) >= StageMarks.listedEvery else { continue }
            entries[ref]?.listedAt = now
            changed = true
        }
        if changed { accounts[account] = entries }
        return changed
    }

    /// Forgets those of these kinds that no list has had for 30 days, with every account: true when it forgot any.
    /// - Parameter kinds: those whose sources have listed what they show, so that a list could have noted that it has them.
    public mutating func forgetUnlisted(now: Date, of kinds: Set<ItemRef.Kind>) -> Bool {
        forget { kinds.contains($0.key.kind) && $0.value.isUnlisted(at: now) }
    }

    /// Forgets those of the sources you turned off, with every account: true when it forgot any.
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) -> Bool {
        forget { kinds.contains($0.key.kind) }
    }

    private mutating func forget(where isForgotten: ((key: ItemRef, value: Entry)) -> Bool) -> Bool {
        var changed = false
        for (account, entries) in accounts {
            let kept = entries.filter { !isForgotten($0) }
            guard kept.count != entries.count else { continue }
            accounts[account] = kept.isEmpty ? nil : kept
            changed = true
        }
        return changed
    }

    // MARK: Kept

    private struct Saved: Codable {
        var account: String
        var pullRequest: ItemRef
        var stage: PullRequestStage
        var since: Date
        var isFirst: Bool
        var listedAt: Date
    }

    /// One that can be read, or none, so that one BriefBar can't read, such as a stage of a later version's, drops alone.
    private struct Lossy: Decodable {
        var value: Saved?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Saved.self)
        }
    }

    /// What was saved, without what can't be read.
    public static func load(from defaults: some SettingsStorage) -> StagesReached {
        guard let data = defaults.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode([Lossy].self, from: data)
        else { return StagesReached() }
        var accounts: [String: [ItemRef: Entry]] = [:]
        for record in saved.compactMap(\.value) where accounts[record.account.lowercased()]?[record.pullRequest] == nil {
            accounts[record.account.lowercased(), default: [:]][record.pullRequest] = Entry(
                stage: record.stage, since: record.since, isFirst: record.isFirst, listedAt: record.listedAt
            )
        }
        return StagesReached(accounts: accounts)
    }

    /// Saves each as its account, its pull request's reference, its stage, when it got there, whether that's where BriefBar
    /// first kept it, and when a list last had it; none removes the key.
    public func save(to defaults: some SettingsStorage) {
        guard !isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        var saved: [Saved] = []
        for account in accounts.keys.sorted() {
            for (ref, entry) in (accounts[account] ?? [:]).sorted(by: { $0.key < $1.key }) {
                saved.append(Saved(
                    account: account, pullRequest: ref, stage: entry.stage, since: entry.since, isFirst: entry.isFirst,
                    listedAt: entry.listedAt
                ))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(saved) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Forget Stages…: how far each pull request got, with every account, whether Pull Request Order is on or not.
    public static func forgetAll(in defaults: some SettingsStorage) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
