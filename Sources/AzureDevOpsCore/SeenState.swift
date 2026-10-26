import Foundation

/// What you've already seen, and what you've taken off Needs You. Azure DevOps has no read/unread state for pull
/// requests, so BriefBar keeps its own: activity up to the baseline, or up to when you last opened a pull request from
/// BriefBar (or marked it seen), counts as seen. Comments you've seen still need you while they wait on you, until you
/// remove the pull request from Needs You, or send them to Copilot.
public struct SeenState: Sendable, Codable, Equatable {
    /// Activity before this was there before BriefBar first ran.
    public var baseline: Date
    /// Pull request (`PRKey.description`) → when you last looked at it.
    public var seenAt: [String: Date]
    /// Pull request → when you last removed it from Needs You, or sent its comments to Copilot: comments up to then
    /// that still wait on you don't need you anymore. Never later than when you last looked at it.
    public var dismissedAt: [String: Date]
    /// Whose this is (`AccessToken.account`), once known: each account you sign in with has its own.
    public var account: String?

    /// On the first run, only the last few days count as new, so years of old threads don't all need you.
    public static let firstRunLookback: TimeInterval = 3 * 86_400

    public init(baseline: Date, seenAt: [String: Date] = [:], dismissedAt: [String: Date] = [:], account: String? = nil) {
        self.baseline = baseline
        self.seenAt = seenAt
        self.dismissedAt = dismissedAt
        self.account = account
    }

    enum CodingKeys: String, CodingKey {
        case baseline, seenAt, dismissedAt, account
    }

    /// What builds from before you could remove a pull request from Needs You saved has no `dismissedAt`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try container.decode(Date.self, forKey: .baseline)
        seenAt = try container.decode([String: Date].self, forKey: .seenAt)
        dismissedAt = try container.decodeIfPresent([String: Date].self, forKey: .dismissedAt) ?? [:]
        account = try container.decodeIfPresent(String.self, forKey: .account)
    }

    public static func firstRun(now: Date = Date(), account: String? = nil) -> SeenState {
        SeenState(baseline: now.addingTimeInterval(-firstRunLookback), account: account)
    }

    public func cutoff(for key: PRKey) -> Date {
        max(baseline, seenAt[key.description] ?? .distantPast)
    }

    /// Comments up to this that still wait on you don't need you anymore.
    public func dismissedCutoff(for key: PRKey) -> Date {
        max(baseline, dismissedAt[key.description] ?? .distantPast)
    }

    public mutating func markSeen<S: Sequence>(_ keys: S, at date: Date) where S.Element == PRKey {
        for key in keys {
            seenAt[key.description] = max(date, seenAt[key.description] ?? .distantPast)
        }
    }

    /// Removes pull requests from Needs You up to `date`, which sees them too: what waited on you there doesn't
    /// anymore, and what comes after needs you again.
    public mutating func dismiss<S: Sequence>(_ keys: S, at date: Date) where S.Element == PRKey {
        let keys = Array(keys)
        for key in keys {
            dismissedAt[key.description] = max(date, dismissedAt[key.description] ?? .distantPast)
        }
        markSeen(keys, at: date)
    }

    /// Forgets pull requests that are no longer listed and were last seen long ago.
    public mutating func prune(keeping keys: Set<PRKey>, olderThan date: Date) {
        let kept = Set(keys.map(\.description))
        seenAt = seenAt.filter { kept.contains($0.key) || $0.value > date }
        dismissedAt = dismissedAt.filter { kept.contains($0.key) || $0.value > date }
    }
}

/// What you've seen, for each account you've signed in to the Azure CLI with. Two accounts can see the same pull
/// request, and what one has seen of it says nothing about what the other has.
public struct SeenBook: Sendable, Equatable {
    /// The state of the account signed in now, or last.
    public var current: SeenState
    /// The other accounts' states, by account.
    public var others: [String: SeenState]

    public init(current: SeenState, others: [String: SeenState] = [:]) {
        self.current = current
        self.others = others
    }

    /// The state for `account`, without switching to it.
    public func state(for account: String?, now: Date = Date()) -> SeenState {
        guard let account, let currentAccount = current.account, currentAccount != account else { return current }
        return others[account] ?? .firstRun(now: now, account: account)
    }

    /// Switches to `account`'s state, keeping the current one for when its account signs in again. A state from
    /// before accounts were told apart becomes this account's. Returns whether it was another account's.
    @discardableResult
    public mutating func signIn(_ account: String, now: Date = Date()) -> Bool {
        guard current.account != account else { return false }
        guard let previous = current.account else {
            current.account = account
            return false
        }
        others[previous] = current
        current = others.removeValue(forKey: account) ?? .firstRun(now: now, account: account)
        return true
    }
}

/// Decides which pull requests' details (two requests each) to fetch on a refresh. The list endpoint has
/// no "last updated" field, and comments don't change anything in it, so details are swept on a
/// schedule, besides being fetched whenever the list shows a change.
public enum RefreshPlanner {
    public struct Options: Sendable, Equatable {
        /// For pull requests with a build or check in progress.
        public var busyInterval: TimeInterval
        public var activeInterval: TimeInterval
        /// For drafts and pull requests without recent activity.
        public var quietInterval: TimeInterval
        /// At most this many known pull requests are refreshed per refresh; new ones always are.
        public var budget: Int

        public init(busyInterval: TimeInterval = 60, activeInterval: TimeInterval = 180, quietInterval: TimeInterval = 900, budget: Int = 8) {
            self.busyInterval = busyInterval
            self.activeInterval = activeInterval
            self.quietInterval = quietInterval
            self.budget = budget
        }
    }

    public struct Entry: Sendable, Equatable {
        public var fetchedAt: Date
        public var fingerprint: String
        public var isBusy: Bool
        public var isQuiet: Bool

        public init(fetchedAt: Date, fingerprint: String, isBusy: Bool = false, isQuiet: Bool = false) {
            self.fetchedAt = fetchedAt
            self.fingerprint = fingerprint
            self.isBusy = isBusy
            self.isQuiet = isQuiet
        }
    }

    public struct Candidate: Sendable, Equatable {
        public var key: PRKey
        public var fingerprint: String

        public init(key: PRKey, fingerprint: String) {
            self.key = key
            self.fingerprint = fingerprint
        }
    }

    /// Pull requests without details always, then, up to `limit` (nil for no limit), changed ones and the
    /// ones whose details are oldest past their interval.
    public static func plan(_ candidates: [Candidate], cache: [PRKey: Entry], now: Date, options: Options, limit: Int?) -> [PRKey] {
        var ranked: [(priority: Int, fetchedAt: Date, key: PRKey)] = []
        for candidate in candidates {
            guard let entry = cache[candidate.key] else {
                ranked.append((0, .distantPast, candidate.key))
                continue
            }
            if entry.fingerprint != candidate.fingerprint {
                ranked.append((1, entry.fetchedAt, candidate.key))
                continue
            }
            let age = now.timeIntervalSince(entry.fetchedAt)
            if entry.isBusy, age >= options.busyInterval {
                ranked.append((2, entry.fetchedAt, candidate.key))
            } else if entry.isQuiet ? age >= options.quietInterval : age >= options.activeInterval {
                ranked.append((3, entry.fetchedAt, candidate.key))
            }
        }
        ranked.sort { ($0.priority, $0.fetchedAt, $0.key) < ($1.priority, $1.fetchedAt, $1.key) }
        let missing = ranked.filter { $0.priority == 0 }.map(\.key)
        let due = ranked.filter { $0.priority > 0 }.map(\.key)
        return missing + (limit.map { Array(due.prefix($0)) } ?? due)
    }
}
