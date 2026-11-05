import Foundation

/// Where a pull request is in its flow, as a column of a kanban board says it: whose turn it is, and what to do about it.
/// With Pull Request Order on, for Azure DevOps' pull requests. BriefBar works it out from what its sources show
/// (`StageRules`); you, or a session, can set one of the first three when you know better (`StageMark`), and the latest
/// change wins. Can merge, Waits and Merged come only from what BriefBar sees.
public enum PullRequestStage: String, Codable, Sendable, CaseIterable {
    /// Its work isn't done: its code is being written or fixed, or its builds or what else Azure DevOps requires aren't.
    case inProgress
    /// You review it next.
    case yourReview
    /// Others review it next.
    case teammateReview
    /// Azure DevOps says it's ready to complete, and BriefBar saw everything its order puts before it merge.
    case canMerge
    /// Azure DevOps says it's ready to complete, but its order puts it after one BriefBar hasn't seen merge.
    case waits
    /// BriefBar saw it merge.
    case merged

    /// What you, or a session, can set: the rest come only from what BriefBar sees, so nobody can claim a pull request can
    /// merge, or merged, before Azure DevOps shows it.
    public static let settable: [PullRequestStage] = [.inProgress, .yourReview, .teammateReview]

    public var isSettable: Bool { Self.settable.contains(self) }

    /// "Teammate's review".
    public var title: String {
        switch self {
        case .inProgress: "In progress"
        case .yourReview: "Your review"
        case .teammateReview: "Teammate's review"
        case .canMerge: "Can merge"
        case .waits: "Waits for another PR"
        case .merged: "Merged"
        }
    }

    /// As a menu item or an action names it: "Teammate's Review".
    public var menuTitle: String {
        switch self {
        case .inProgress: "In Progress"
        case .yourReview: "Your Review"
        case .teammateReview: "Teammate's Review"
        case .canMerge: "Can Merge"
        case .waits: "Waits for Another PR"
        case .merged: "Merged"
        }
    }

    public var symbol: String {
        switch self {
        case .inProgress: "hammer.fill"
        case .yourReview: "eye.fill"
        case .teammateReview: "person.2.fill"
        case .canMerge: "checkmark.circle.fill"
        case .waits: "hourglass"
        case .merged: "arrow.triangle.merge"
        }
    }

    /// Its step of a pull request's flow, as its details' track draws it: Waits stands where Can merge does, and Merged
    /// fills them all.
    public var step: Int {
        switch self {
        case .inProgress: 0
        case .yourReview: 1
        case .teammateReview: 2
        case .canMerge, .waits: 3
        case .merged: 4
        }
    }

    /// The next stage you can set after it, and the one before: ⌘→ and ⌘← on a card or a row.
    public var nextSettable: PullRequestStage? { neighbor(1) }
    public var previousSettable: PullRequestStage? { neighbor(-1) }

    private func neighbor(_ offset: Int) -> PullRequestStage? {
        guard let index = Self.settable.firstIndex(of: self) else { return nil }
        let other = index + offset
        return Self.settable.indices.contains(other) ? Self.settable[other] : nil
    }
}

// MARK: - What it's worked out from

/// A Copilot session on a pull request, as a stage needs it: whether it works on it now, waits for you, or is done with it,
/// and since when. Its name comes from what the sources say of it, unless it has its own.
public struct StageSession: Equatable, Sendable {
    public enum Activity: Equatable, Sendable {
        /// It writes or fixes the pull request's code now.
        case working
        /// It waits for your answer, a plan's approval or a permission.
        case waitsForYou
        /// It's done with it: it finished, or went idle since.
        case finished
        /// It stopped before it was done: it was interrupted, or failed.
        case stopped

        /// Working, or waiting for you: it isn't done with the pull request.
        public var isBusy: Bool { self == .working || self == .waitsForYou }
    }

    public var ref: ItemRef
    public var activity: Activity
    /// When it started what it does now, or when it ended.
    public var since: Date?
    /// What to call it, when it isn't one the sources name, such as "Copilot" for a task BriefBar sent.
    public var name: String?

    public init(ref: ItemRef, activity: Activity, since: Date?, name: String? = nil) {
        self.ref = ref
        self.activity = activity
        self.since = since
        self.name = name
    }
}

/// What a source tells of one of its pull requests, for its stage: what BriefBar reads of it already, as facts and its own
/// words, never its title. Whose it is, where it stands in its source, and the Copilot work on it that the source knows of.
public struct StageFacts: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        /// You opened it.
        case author
        /// You're asked to review it.
        case reviewer
        /// Someone sent it to you in a chat: you're neither its author nor a reviewer.
        case sentToYou
    }

    public var role: Role
    public var state: PullRequestState
    /// Yours: what fails, such as "Build failed" or "Merge conflicts"; nil while nothing does.
    public var failure: String?
    /// Yours: who wants changes, such as "Priya wants changes"; nil while nobody does.
    public var changesWanted: String?
    /// Someone else's that waits for your review: who asked, such as "Sam asked you" or "Priya sent it in Teams".
    public var asksYou: String?
    /// Yours: its source says it's ready to complete, as its Ready to Complete group does.
    public var isReady: Bool
    /// It completes by itself once it's ready.
    public var autoComplete: Bool
    /// Yours, its reviews done, but not ready: What's Left's first item, such as "Build running" or "Resolve 2 comments".
    public var leftAfterReviews: String?
    /// Yours: who it waits for, such as "Waiting on Priya" or "1 of 2 approvals"; nil while nobody but you is asked to
    /// review it, people or teams.
    public var waitingFor: String?
    /// Yours: someone but you voted on it.
    public var othersVoted: Bool
    /// Someone else's that you asked for changes, or rejected: "Waiting for Sam's changes".
    public var youWantChanges: String?
    /// The others' votes, as a digest of the votes alone, never who cast them: a set Teammate's review ends as it changes.
    public var votes: String
    /// Its latest commit, when its source says: a set In progress ends as it changes.
    public var commit: String?
    /// The Copilot work on it that its source knows of, such as a task BriefBar sent.
    public var sessions: [StageSession]
    /// Since when it stands as its source shows it, for a stage that says nothing else of its time.
    public var since: Date?

    public init(
        role: Role, state: PullRequestState = .open, failure: String? = nil, changesWanted: String? = nil, asksYou: String? = nil,
        isReady: Bool = false, autoComplete: Bool = false, leftAfterReviews: String? = nil, waitingFor: String? = nil,
        othersVoted: Bool = false, youWantChanges: String? = nil, votes: String = "", commit: String? = nil,
        sessions: [StageSession] = [], since: Date? = nil
    ) {
        self.role = role
        self.state = state
        self.failure = failure
        self.changesWanted = changesWanted
        self.asksYou = asksYou
        self.isReady = isReady
        self.autoComplete = autoComplete
        self.leftAfterReviews = leftAfterReviews
        self.waitingFor = waitingFor
        self.othersVoted = othersVoted
        self.youWantChanges = youWantChanges
        self.votes = votes
        self.commit = commit
        self.sessions = sessions
        self.since = since
    }

    public var isYours: Bool { role == .author }

    /// The votes others cast, as a set Teammate's review keeps them: how many of each vote, in order, never who cast them.
    public static func digest(votes: [Int]) -> String {
        votes.sorted().map(String.init).joined(separator: ",")
    }
}

/// A stage you or a session set, when, and what it was set over: the others' votes and the pull request's commit then,
/// which some stages end with (`StageRules.stands`).
public struct StageMark: Equatable, Sendable {
    public var stage: PullRequestStage
    public var at: Date
    /// The session that set it; nil for you.
    public var by: ItemRef?
    public var votes: String?
    public var commit: String?

    public init(stage: PullRequestStage, at: Date, by: ItemRef? = nil, votes: String? = nil, commit: String? = nil) {
        self.stage = stage
        self.at = at
        self.by = by
        self.votes = votes
        self.commit = commit
    }

    public var isYours: Bool { by == nil }
}

/// What a pull request's order says of merging it, for Can merge and Waits.
public enum StageOrder: Equatable, Sendable {
    /// Nothing holds it: it's in no order, or BriefBar saw everything its order puts before it merge.
    case free
    /// It waits for these to merge, or for BriefBar to see whether they did, in its capsule's words: "After !4102 · stacked".
    case waits([ItemRef], words: String)
    /// Its order needs checking first, as this says: one before it closed, it still targets a merged branch, or a circle.
    case holds(String)

    /// What the missions say of a pull request: the first that holds it, else free.
    public static func of(_ ref: ItemRef, in missions: [OrderMission]) -> StageOrder {
        for mission in missions {
            if let step = mission.steps.first(where: { $0.ref == ref }) {
                switch step.standing {
                case .waiting(let open, let unknown):
                    return .waits(open + unknown, words: OrderText.capsule(step) ?? "After \(OrderText.list(open + unknown, near: ref))")
                case .unresolved(let unknown):
                    return .waits(unknown, words: OrderText.capsule(step) ?? "After \(OrderText.list(unknown, near: ref))")
                case .prerequisiteClosed, .retarget, .inCycle:
                    return .holds(OrderText.standing(step) ?? "Check the order")
                default:
                    continue
                }
            }
            if let step = mission.attached.first(where: { $0.ref == ref }) {
                var statuses: [ItemRef: OrderStatus] = [:]
                for other in mission.steps + mission.attached { statuses[other.ref] = other.status }
                let below = step.notes.compactMap { note -> ItemRef? in
                    guard case .stackedWith(let other, true, _) = note, statuses[other] != .merged else { return nil }
                    return other
                }
                if !below.isEmpty { return .waits(below, words: "After \(OrderText.list(below, near: ref)) · stacked") }
            }
        }
        return .free
    }
}

// MARK: - What it works out

/// A pull request's stage, why, and who set it.
public struct StageReading: Equatable, Sendable {
    public var stage: PullRequestStage
    public var why: StageWhy
    /// Since when it's been in it, as far as BriefBar knows.
    public var since: Date?
    /// What you or a session set, when that's what it shows: it says who.
    public var mark: StageMark?
    /// Yours, which a session's later change replaced: Put Yours Back makes it the latest again.
    public var replaced: StageMark?
    /// Whether it's on your board: not someone else's that you finished reviewing, until something new needs you there.
    public var isOnBoard: Bool

    public init(
        stage: PullRequestStage, why: StageWhy, since: Date? = nil, mark: StageMark? = nil, replaced: StageMark? = nil,
        isOnBoard: Bool = true
    ) {
        self.stage = stage
        self.why = why
        self.since = since
        self.mark = mark
        self.replaced = replaced
        self.isOnBoard = isOnBoard
    }

    /// Whether you set what it shows.
    public var isSetByYou: Bool { mark?.isYours == true }
}

/// Why a pull request is in its stage, as its row says it.
public enum StageWhy: Equatable, Sendable {
    case merged
    /// "‘Retry backoff’ is writing it".
    case working(StageSession)
    /// "‘Cart’ asks you".
    case asksYou(StageSession)
    /// You or a session set it, which its mark says.
    case set
    /// "Build failed".
    case failing(String)
    /// "Priya wants changes".
    case changesWanted(String)
    /// "Sam asked you".
    case asked(String)
    /// "‘Cart’ finished".
    case finished(StageSession)
    case draft
    /// "Complete it", "Completing automatically".
    case ready(autoComplete: Bool)
    /// "After !4102 · stacked".
    case waitsFor([ItemRef], words: String)
    /// Its order needs checking: "!4102 was closed without merging: check the order".
    case orderHolds(String)
    /// What's Left's first item: "Build running".
    case left(String)
    case findReviewer
    /// "Waiting on Priya", "1 of 2 approvals".
    case waitingFor(String)
    /// "Waiting for Sam's changes".
    case authorChanges(String)
    /// Someone else's that you finished reviewing.
    case finishedReview
}

/// How BriefBar works a pull request's stage out: the first rule that applies (plan §2.2), from what its source shows, the
/// Copilot sessions on it, what you or a session set, and its order.
public enum StageRules {
    /// - Parameters:
    ///   - sessions: every Copilot session on it, its source's and the Copilot app's, each once.
    ///   - marks: what you and sessions set, in any order: the latest decides, while it stands (`stands`).
    /// - Returns: nil for one that isn't on your board, such as someone else's you approved, or one closed without merging.
    public static func reading(facts: StageFacts, sessions: [StageSession], marks: [StageMark], order: StageOrder) -> StageReading? {
        if facts.state == .merged { return StageReading(stage: .merged, why: .merged, since: facts.since) }
        guard facts.state.isOpen else { return nil }
        let (mark, replaced) = standingMark(marks, facts: facts, sessions: sessions)

        // A session at work on it now, since after what was set: one that waits for you first, else the latest to start. One
        // whose start BriefBar doesn't know leaves what was set as it is.
        let busy = sessions.filter { session in
            session.activity.isBusy && mark.map { (session.since ?? .distantPast) > $0.at } ?? true
        }
        if let session = busy.first(where: { $0.activity == .waitsForYou }) ?? latest(busy) {
            let why: StageWhy = session.activity == .waitsForYou ? .asksYou(session) : .working(session)
            return StageReading(stage: .inProgress, why: why, since: session.since)
        }

        if let mark {
            switch mark.stage {
            case .teammateReview where !facts.isYours:
                return StageReading(stage: .teammateReview, why: .finishedReview, since: mark.at, mark: mark, replaced: replaced, isOnBoard: false)
            case .teammateReview:
                let why: StageWhy = facts.waitingFor.map(StageWhy.waitingFor) ?? .findReviewer
                return StageReading(stage: .teammateReview, why: why, since: mark.at, mark: mark, replaced: replaced)
            default:
                return StageReading(stage: mark.stage, why: .set, since: mark.at, mark: mark, replaced: replaced)
            }
        }

        let since = facts.since
        guard facts.isYours else {
            if let asked = facts.asksYou, facts.state != .draft {
                return StageReading(stage: .yourReview, why: .asked(asked), since: since)
            }
            if let changes = facts.youWantChanges {
                return StageReading(stage: .inProgress, why: .authorChanges(changes), since: since)
            }
            return nil
        }
        if let failure = facts.failure { return StageReading(stage: .inProgress, why: .failing(failure), since: since) }
        if let changes = facts.changesWanted { return StageReading(stage: .inProgress, why: .changesWanted(changes), since: since) }
        if !facts.othersVoted, let session = latest(sessions.filter { $0.activity == .finished }) {
            return StageReading(stage: .yourReview, why: .finished(session), since: session.since)
        }
        if facts.state == .draft { return StageReading(stage: .inProgress, why: .draft, since: since) }
        if facts.isReady {
            switch order {
            case .free: return StageReading(stage: .canMerge, why: .ready(autoComplete: facts.autoComplete), since: since)
            case .waits(let refs, let words): return StageReading(stage: .waits, why: .waitsFor(refs, words: words), since: since)
            case .holds(let words): return StageReading(stage: .waits, why: .orderHolds(words), since: since)
            }
        }
        if let left = facts.leftAfterReviews { return StageReading(stage: .inProgress, why: .left(left), since: since) }
        return StageReading(stage: .teammateReview, why: facts.waitingFor.map(StageWhy.waitingFor) ?? .findReviewer, since: since)
    }

    /// The latest of what was set, while it stands, and yours when a session's later change replaced it with another stage.
    /// Once the latest ends, none of them counts: BriefBar works the stage out again.
    static func standingMark(_ marks: [StageMark], facts: StageFacts, sessions: [StageSession]) -> (StageMark?, StageMark?) {
        guard let latest = marks.max(by: { $0.at < $1.at }), stands(latest, facts: facts, sessions: sessions) else { return (nil, nil) }
        guard !latest.isYours, let yours = marks.filter(\.isYours).max(by: { $0.at < $1.at }), yours.stage != latest.stage
        else { return (latest, nil) }
        return (latest, yours)
    }

    /// Whether a stage set still stands, as the pull request moved on since (plan §2.4). A later change replaces it, which
    /// `standingMark` sees to, and merging or closing it ends it, which comes first anyway. A set In progress ends when a
    /// session working on it finishes, or new commits come, after it was set; a set Teammate's review, when others' votes
    /// change, and, on someone else's that you finished reviewing, when new commits come. A set Your review stands until
    /// it's changed: BriefBar can't tell you reviewed it.
    public static func stands(_ mark: StageMark, facts: StageFacts, sessions: [StageSession]) -> Bool {
        let newCommits = mark.commit != nil && facts.commit != nil && mark.commit != facts.commit
        switch mark.stage {
        case .inProgress:
            return !newCommits && !sessions.contains { $0.activity == .finished && ($0.since ?? .distantPast) > mark.at }
        case .teammateReview:
            if let votes = mark.votes, votes != facts.votes { return false }
            return facts.isYours || !newCommits
        case .yourReview:
            return true
        case .canMerge, .waits, .merged:
            return false
        }
    }

    private static func latest(_ sessions: [StageSession]) -> StageSession? {
        sessions.max { ($0.since ?? .distantPast, $1.ref) < ($1.since ?? .distantPast, $0.ref) }
    }
}

// MARK: - Words

/// What a stage says, in BriefBar's words, for the pull requests' rows, their details and VoiceOver: sessions by their
/// names, pull requests by their numbers.
public enum StageText {
    /// Why it's in its stage: "‘Cart’ finished", "Find a reviewer", "After !4102".
    /// - Parameter name: what the sources call a session, when they say.
    public static func why(_ reading: StageReading, name: (ItemRef) -> String?) -> String {
        switch reading.why {
        case .merged: return "Merged"
        case .working(let session): return "\(called(session, name: name)) is writing it"
        case .asksYou(let session): return "\(called(session, name: name)) asks you"
        case .set:
            let by = reading.mark?.by
            switch reading.stage {
            case .yourReview: return by.map { "\(quoted($0, name: name)) says it's ready" } ?? "Waiting for your review"
            case .inProgress: return by.map { "\(quoted($0, name: name)) is on it" } ?? "You sent it back"
            default: return reading.stage.title
            }
        case .failing(let words), .changesWanted(let words), .asked(let words), .left(let words), .waitingFor(let words),
             .authorChanges(let words), .orderHolds(let words):
            return words
        case .finished(let session): return "\(called(session, name: name)) finished"
        case .draft: return "Draft"
        case .ready(let autoComplete): return autoComplete ? "Completing automatically" : "Complete it"
        case .waitsFor(_, let words): return words
        case .findReviewer: return "Find a reviewer"
        case .finishedReview: return "You finished your review: vote in Azure DevOps when you're ready"
        }
    }

    /// Who set it, and how long ago, when someone did: "You set it · 2h", "‘Cart’ set it · 5m, after you".
    public static func who(_ reading: StageReading, now: Date, name: (ItemRef) -> String?) -> String? {
        guard let mark = reading.mark else { return nil }
        var words = setter(mark, name: name) + " set it · " + Elapsed.short(since: mark.at, now: now)
        if reading.replaced != nil { words += ", after you" }
        return words
    }

    /// The same, as VoiceOver says it: "set by you 2 hours ago", "set by BriefBar".
    public static func spokenWho(_ reading: StageReading, now: Date, name: (ItemRef) -> String?) -> String {
        guard let mark = reading.mark else { return "worked out by BriefBar" }
        let who = mark.by.map { "set by \(quoted($0, name: name))" } ?? "set by you"
        return who + " " + Elapsed.spoken(since: mark.at, now: now) + " ago" + (reading.replaced != nil ? ", after you" : "")
    }

    /// For its tooltip, and its menu's first line: "Your review: ‘Cart’ finished. Worked out by BriefBar."
    public static func sentence(_ reading: StageReading, now: Date, name: (ItemRef) -> String?) -> String {
        let who = reading.mark.map { setter($0, name: name) + " set it " + agoWords($0.at, now: now) } ?? "Worked out by BriefBar"
        return "\(reading.stage.title): \(why(reading, name: name)). \(who)."
    }

    /// "You set it 2h ago" for Put Yours Back: "Put Yours Back: Teammate's review, 2h ago".
    public static func putBack(_ mark: StageMark, now: Date) -> String {
        "Put Yours Back: \(mark.stage.title), \(agoWords(mark.at, now: now))"
    }

    /// What became of it, for the Undo line and VoiceOver: "Moved !4093 to Teammate's review".
    public static func moved(_ ref: ItemRef, to stage: PullRequestStage?) -> String {
        stage.map { "Moved \(ref.shortOrderLabel) to \($0.title)" } ?? "Let BriefBar decide \(ref.shortOrderLabel)'s stage"
    }

    /// When Can merge comes, for its step of the track that can't be clicked.
    public static let canMergeHelp =
        "Once Azure DevOps says it's ready to complete, and BriefBar saw what its order puts before it merge"

    /// Why Can merge and Waits can't be chosen, in the stage's menu.
    public static func whyNotSettable(_ stage: PullRequestStage) -> String? {
        switch stage {
        case .canMerge: "Azure DevOps decides: once it's approved and its checks pass"
        case .waits: "Its order decides"
        case .merged: "It merges in Azure DevOps"
        default: nil
        }
    }

    static func setter(_ mark: StageMark, name: (ItemRef) -> String?) -> String {
        mark.by.map { quoted($0, name: name) } ?? "You"
    }

    static func called(_ session: StageSession, name: (ItemRef) -> String?) -> String {
        if let own = session.name { return own }
        return quoted(session.ref, name: name)
    }

    static func quoted(_ session: ItemRef, name: (ItemRef) -> String?) -> String {
        name(session).map { "‘\($0)’" } ?? "A Copilot session"
    }

    static func agoWords(_ date: Date, now: Date) -> String {
        let short = Elapsed.short(since: date, now: now)
        return short == "now" ? "just now" : short + " ago"
    }
}
