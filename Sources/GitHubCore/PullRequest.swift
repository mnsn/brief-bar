import BriefBarCore
import Foundation

/// An open pull request on GitHub, with what decides where it goes.
public struct GitHubPullRequest: Sendable, Codable, Equatable, Identifiable {
    public enum ReviewDecision: String, Sendable, Codable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case reviewRequired = "REVIEW_REQUIRED"
    }

    /// The latest commit's checks, all together.
    public enum Checks: String, Sendable, Codable {
        case passing, failing, running

        /// GitHub's `StatusState`: SUCCESS, FAILURE, ERROR, PENDING or EXPECTED.
        public init?(rollup: String?) {
            switch rollup {
            case "SUCCESS": self = .passing
            case "FAILURE", "ERROR": self = .failing
            case "PENDING", "EXPECTED": self = .running
            default: return nil
            }
        }
    }

    /// A reviewer's latest review that approves or requests changes.
    public struct Review: Sendable, Codable, Equatable {
        public enum State: String, Sendable, Codable {
            case approved = "APPROVED"
            case changesRequested = "CHANGES_REQUESTED"
        }

        public var reviewer: String?
        public var state: State

        public init(reviewer: String?, state: State) {
            self.reviewer = reviewer
            self.state = state
        }
    }

    /// GitHub's node ID, the same wherever the pull request is found.
    public var id: String
    public var number: Int
    public var title: String
    public var url: URL
    /// owner/name.
    public var repository: String
    /// Nil for a deleted account.
    public var author: String?
    public var isDraft: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Nil when the repository doesn't require reviews.
    public var reviewDecision: ReviewDecision?
    public var hasConflicts: Bool
    /// Nil when nothing checks the latest commit.
    public var checks: Checks?
    public var reviews: [Review]

    public init(
        id: String, number: Int, title: String, url: URL, repository: String, author: String?, isDraft: Bool = false,
        createdAt: Date, updatedAt: Date, reviewDecision: ReviewDecision? = nil, hasConflicts: Bool = false,
        checks: Checks? = nil, reviews: [Review] = []
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repository = repository
        self.author = author
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reviewDecision = reviewDecision
        self.hasConflicts = hasConflicts
        self.checks = checks
        self.reviews = reviews
    }

    /// From what the query read. Values BriefBar doesn't know count as unknown.
    public init(_ api: APIPullRequest) {
        self.init(
            id: api.id, number: api.number, title: api.title, url: api.url, repository: api.repository.nameWithOwner,
            author: api.author?.login, isDraft: api.isDraft, createdAt: api.createdAt, updatedAt: api.updatedAt,
            reviewDecision: api.reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            hasConflicts: api.mergeable == "CONFLICTING",
            checks: Checks(rollup: api.commits?.nodes.last?.commit.statusCheckRollup?.state),
            reviews: (api.latestOpinionatedReviews?.nodes ?? []).compactMap { review in
                Review.State(rawValue: review.state).map { Review(reviewer: review.author?.login, state: $0) }
            }
        )
    }

    /// owner/name#number.
    public var reference: String { "\(repository)#\(number)" }

    func reviewers(_ state: Review.State) -> [String] {
        var seen = Set<String>()
        return reviews.filter { $0.state == state }.compactMap(\.reviewer).filter { seen.insert($0).inserted }
    }
}

/// Why you see a pull request: GitHub asked for your review, or it's yours.
public enum GitHubPRRole: String, Sendable, Codable {
    case reviewer, author
}

/// Where a pull request goes in the list, in the list's order.
public enum GitHubPRGroup: String, Sendable, Codable, CaseIterable, Comparable {
    /// Someone asked you, by name, to review it.
    case toReview
    /// Yours, and a reviewer asked for changes.
    case changesRequested
    /// Yours, and its checks fail or it has merge conflicts.
    case failing
    /// Yours, and approved.
    case ready
    /// Yours, and waiting on others: for reviews, for checks to finish, or still a draft.
    case waiting

    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: GitHubPRGroup, rhs: GitHubPRGroup) -> Bool { lhs.rank < rhs.rank }

    /// The state it counts in, the same for every source. Waiting isn't counted.
    public var state: ItemState? {
        switch self {
        case .toReview, .changesRequested: return .needsYou
        case .failing: return .failing
        case .ready: return .done
        case .waiting: return nil
        }
    }
}

public enum GitHubPRReason: String, Sendable, Codable {
    case reviewRequested, changesRequested, checksFailed, conflicts, approved, checksRunning, draft, waitingForReview
}

/// A pull request as the list shows it.
public struct GitHubPRSnapshot: Sendable, Codable, Equatable, Identifiable {
    public var pullRequest: GitHubPullRequest
    public var role: GitHubPRRole
    public var group: GitHubPRGroup
    public var reason: GitHubPRReason
    /// What it's waiting for, in a few words: "Checks failing".
    public var headline: String
    /// Who: "By priya", "Approved by sam".
    public var detail: String?

    public var id: String { pullRequest.id }
    /// When it last changed.
    public var since: Date { pullRequest.updatedAt }

    public init(
        pullRequest: GitHubPullRequest, role: GitHubPRRole, group: GitHubPRGroup, reason: GitHubPRReason,
        headline: String, detail: String? = nil
    ) {
        self.pullRequest = pullRequest
        self.role = role
        self.group = group
        self.reason = reason
        self.headline = headline
        self.detail = detail
    }

    /// A brief's line in BriefBar's own words.
    public var briefSentence: String {
        let title = "“\(pullRequest.title)”"
        switch reason {
        case .reviewRequested:
            return pullRequest.author.map { "\($0) asks for your review on \(title)." } ?? "Your review is requested on \(title)."
        case .changesRequested:
            let reviewers = pullRequest.reviewers(.changesRequested)
            return reviewers.isEmpty
                ? "Changes are requested on \(title)." : "\(GitHubClassifier.names(reviewers)) requested changes on \(title)."
        case .checksFailed: return "Checks are failing on \(title)."
        case .conflicts: return "\(title) has merge conflicts."
        case .approved: return "\(title) is approved."
        case .checksRunning: return "Checks are running on \(title)."
        case .draft: return "\(title) is a draft."
        case .waitingForReview: return "\(title) is waiting for review."
        }
    }
}

/// Decides where each pull request goes. Something wrong with your own comes first, then what a reviewer asks of
/// you, then whether it's waiting or ready.
public enum GitHubClassifier {
    public static func classify(_ pullRequest: GitHubPullRequest, role: GitHubPRRole) -> GitHubPRSnapshot {
        func snapshot(_ group: GitHubPRGroup, _ reason: GitHubPRReason, _ headline: String, _ detail: String? = nil) -> GitHubPRSnapshot {
            GitHubPRSnapshot(pullRequest: pullRequest, role: role, group: group, reason: reason, headline: headline, detail: detail)
        }

        if role == .reviewer {
            return snapshot(.toReview, .reviewRequested, "Review requested", pullRequest.author.map { "By \($0)" })
        }
        if pullRequest.isDraft {
            return snapshot(.waiting, .draft, "Draft")
        }
        if pullRequest.checks == .failing {
            return snapshot(.failing, .checksFailed, pullRequest.hasConflicts ? "Checks failing · merge conflicts" : "Checks failing")
        }
        if pullRequest.hasConflicts {
            return snapshot(.failing, .conflicts, "Merge conflicts")
        }
        let changesRequestedBy = pullRequest.reviewers(.changesRequested)
        if pullRequest.reviewDecision == .changesRequested || (pullRequest.reviewDecision == nil && !changesRequestedBy.isEmpty) {
            return snapshot(
                .changesRequested, .changesRequested, "Changes requested",
                changesRequestedBy.isEmpty ? nil : "By \(names(changesRequestedBy))"
            )
        }
        if pullRequest.checks == .running {
            return snapshot(.waiting, .checksRunning, "Checks running")
        }
        let approvedBy = pullRequest.reviewers(.approved)
        if pullRequest.reviewDecision == .approved || (pullRequest.reviewDecision == nil && !approvedBy.isEmpty) {
            return snapshot(.ready, .approved, "Approved", approvedBy.isEmpty ? nil : "By \(names(approvedBy))")
        }
        return snapshot(.waiting, .waitingForReview, "Waiting for review")
    }

    /// Each pull request once, yours first when it's both, in the list's order.
    public static func snapshots(reviewing: [GitHubPullRequest], authored: [GitHubPullRequest]) -> [GitHubPRSnapshot] {
        var seen = Set<String>()
        var snapshots: [GitHubPRSnapshot] = []
        for (pullRequest, role) in authored.map({ ($0, GitHubPRRole.author) }) + reviewing.map({ ($0, GitHubPRRole.reviewer) })
        where seen.insert(pullRequest.id).inserted {
            snapshots.append(classify(pullRequest, role: role))
        }
        return sorted(snapshots)
    }

    /// By group, then the most recently changed first.
    public static func sorted(_ snapshots: [GitHubPRSnapshot]) -> [GitHubPRSnapshot] {
        snapshots.sorted { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            if lhs.since != rhs.since { return lhs.since > rhs.since }
            return lhs.id < rhs.id
        }
    }

    /// "priya", "priya and sam", "priya, sam and 2 others".
    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) others"
        }
    }
}

public struct GitHubGroupCounts: Sendable, Equatable, Codable {
    public var toReview = 0
    public var changesRequested = 0
    public var failing = 0
    public var ready = 0
    public var waiting = 0

    public init() {}

    public init(_ snapshots: [GitHubPRSnapshot]) {
        for snapshot in snapshots { self[snapshot.group] += 1 }
    }

    public subscript(group: GitHubPRGroup) -> Int {
        get {
            switch group {
            case .toReview: return toReview
            case .changesRequested: return changesRequested
            case .failing: return failing
            case .ready: return ready
            case .waiting: return waiting
            }
        }
        set {
            switch group {
            case .toReview: toReview = newValue
            case .changesRequested: changesRequested = newValue
            case .failing: failing = newValue
            case .ready: ready = newValue
            case .waiting: waiting = newValue
            }
        }
    }

    public var total: Int { GitHubPRGroup.allCases.map { self[$0] }.reduce(0, +) }

    /// The pull requests that need you: to review, or with changes requested.
    public var needsYou: Int { states.needsYou }

    /// The pull requests the menu bar counts, by state, for an item that adds them up across sources.
    public var states: StateCounts {
        StateCounts(GitHubPRGroup.allCases, count: { self[$0] }, state: \.state)
    }
}

/// Why the list may be missing or out of date.
public enum GitHubProblem: Sendable, Equatable {
    case cliNotFound
    case signedOut(String)
    case authFailed(String)
    case offline
    case throttled(until: Date)
    /// Nothing could be read; the list shown is the last one that could.
    case unreachable(String)

    public var message: String {
        switch self {
        case .cliNotFound: return "BriefBar signs in with the GitHub CLI, which isn't installed."
        case .signedOut: return "Sign in to the GitHub CLI to see your pull requests."
        case .authFailed(let message): return "Couldn't get a token from the GitHub CLI: \(message)"
        case .offline: return "You're offline. The list may be out of date."
        case .throttled(let until):
            return "GitHub asked BriefBar to slow down, until \(until.formatted(date: .omitted, time: .shortened))."
        case .unreachable(let message): return "\(message) The list may be out of date."
        }
    }

    /// Fixed by signing in (or installing the GitHub CLI first).
    public var needsSignIn: Bool {
        switch self {
        case .cliNotFound, .signedOut: return true
        default: return false
        }
    }

    public static func from(_ error: Error, now: Date = Date()) -> GitHubProblem {
        var unwrapped: any Error = error
        if let authError = error as? GitHubAuthError { unwrapped = GitHubError.auth(authError) }
        guard let gitHubError = unwrapped as? GitHubError else { return .unreachable(unwrapped.localizedDescription) }
        switch gitHubError {
        case .auth(.cliNotFound): return .cliNotFound
        case .auth(.signedOut(let message)): return .signedOut(message)
        case .auth(.failed(let message)): return .authFailed(message)
        case .unauthorized: return .signedOut(gitHubError.description)
        case .offline: return .offline
        case .throttled(let seconds): return .throttled(until: now.addingTimeInterval(seconds))
        default: return .unreachable(gitHubError.description)
        }
    }
}
