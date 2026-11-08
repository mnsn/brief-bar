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
        /// Its last turn finished, whether or not it went idle since.
        case finished
        /// It stopped before it was done: it was interrupted, failed or stopped responding; or BriefBar can't tell how it
        /// ended. It says nothing of the pull request.
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
    /// It reads the pull request to review it, and writes nothing, such as Copilot's pre-review of someone else's: it keeps
    /// it yours to review while it runs, never puts it in progress, and its end ends nothing you set.
    public var isReview: Bool

    public init(ref: ItemRef, activity: Activity, since: Date?, name: String? = nil, isReview: Bool = false) {
        self.ref = ref
        self.activity = activity
        self.since = since
        self.name = name
        self.isReview = isReview
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
        /// Someone sent it to you in a chat: you're neither its author nor a reviewer. What you set on it stays in memory,
        /// as what you've seen of it does.
        case sentToYou
        /// You watch it: you're neither its author nor a reviewer.
        case watching
    }

    public var role: Role
    public var state: PullRequestState
    /// Yours: what fails, such as "Build failed" or "Merge conflicts"; nil while nothing does.
    public var failure: String?
    /// Yours: who wants changes, such as "Priya wants changes"; nil while nobody does.
    public var changesWanted: String?
    /// Someone else's that waits for your review: who asked, such as "Sam asked you" or "Priya sent it in Teams", or what
    /// brought it back to you since your vote, "New commits by Sam".
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
    /// The votes a set Teammate's review ends with, as they change: on yours, the votes others cast, as a digest of the
    /// votes alone, never who cast them, so asking someone else to review it changes nothing; on someone else's, your own
    /// vote, so voting in Azure DevOps after Finished My Review ends it, and co-reviewers' votes don't.
    public var votes: String
    /// Its latest commit, when its source says: a set In progress ends as it changes.
    public var commit: String?
    /// The Copilot work on it that its source knows of, such as a task BriefBar sent.
    public var sessions: [StageSession]
    /// Since when it stands as its source shows it, for a stage that says nothing else of its time.
    public var since: Date?
    /// Whether one of its source's lists has it now. One it still reads that no list has, such as one sent to you in a chat
    /// once you answered it, has no stage to show, but what was set on it still ends as it moves on.
    public var isListed: Bool
    /// Someone else's: who opened it, by their first name, such as "Priya", as its row names them: they ask for its reviews.
    public var author: String?

    public init(
        role: Role, state: PullRequestState = .open, failure: String? = nil, changesWanted: String? = nil, asksYou: String? = nil,
        isReady: Bool = false, autoComplete: Bool = false, leftAfterReviews: String? = nil, waitingFor: String? = nil,
        othersVoted: Bool = false, youWantChanges: String? = nil, votes: String = "", commit: String? = nil,
        sessions: [StageSession] = [], since: Date? = nil, isListed: Bool = true, author: String? = nil
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
        self.isListed = isListed
        self.author = author
    }

    public var isYours: Bool { role == .author }

    /// The votes others cast, as a set Teammate's review keeps them: how many of each vote, in order, never who cast them.
    public static func digest(votes: [Int]) -> String {
        votes.sorted().map(String.init).joined(separator: ",")
    }
}

/// A stage you or a session set, when, and of what it was set over only what would end it (`StageRules.mark`): the votes
/// then, for Teammate's review, and the pull request's commit, where new commits end it (`StageRules.stands`).
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

    /// What the missions say of a pull request: the first that holds it, else free. One stacked on another, which targets
    /// its branch or follows it in a GitHub stack, waits for it until BriefBar sees it merge, whatever its order says, and
    /// whether an order names that one, this order or another: completing it before would merge it into that one's
    /// branch. Once that one merged, one still targeting its branch holds until it's retargeted. One that two orders put
    /// before and after another holds, until you check them.
    /// - Parameter names: what names the other order where two go round; never for agents, who get no mission's name.
    public static func of(_ ref: ItemRef, in missions: [OrderMission], names: OrderNames = .none) -> StageOrder {
        let statuses = statuses(in: missions)
        return missions.lazy.compactMap { hold(ref, in: $0, statuses: statuses, names: names) }.first ?? .free
    }

    /// The missions that hold a pull request, the one `of(_:in:)` reads first: where its order puts it after one that
    /// hasn't merged, needs checking, or goes round with another order, or where it's stacked on one that hasn't merged.
    /// Set as Next to Merge in another of its missions leaves it where it is.
    public static func holders(of ref: ItemRef, in missions: [OrderMission]) -> [MissionKey] {
        let statuses = statuses(in: missions)
        return missions.filter { hold(ref, in: $0, statuses: statuses) != nil }.map(\.key)
    }

    /// What one of the missions says of a pull request, as `of(_:in:)` reads each in turn: nil where it doesn't hold it.
    public static func hold(
        _ ref: ItemRef, in mission: OrderMission, among missions: [OrderMission], names: OrderNames = .none
    ) -> StageOrder? {
        hold(ref, in: mission, statuses: statuses(in: missions), names: names)
    }

    private static func statuses(in missions: [OrderMission]) -> [ItemRef: OrderStatus] {
        var statuses: [ItemRef: OrderStatus] = [:]
        for mission in missions {
            for other in mission.steps + mission.attached where statuses[other.ref] == nil {
                statuses[other.ref] = other.status
            }
        }
        return statuses
    }

    /// What one mission says of merging a pull request: nil where it doesn't hold it.
    private static func hold(
        _ ref: ItemRef, in mission: OrderMission, statuses: [ItemRef: OrderStatus], names: OrderNames = .none
    ) -> StageOrder? {
        if let step = mission.steps.first(where: { $0.ref == ref }) {
            // Two orders put it and another in opposite orders, directly or through others' lines: neither can merge
            // first, whatever else it waits for.
            if !step.standing.needsChecking, let round = step.ordersGoRound {
                return .holds(OrderText.note(round, of: ref, names: names))
            }
            switch step.standing {
            case .waiting(let open, let unknown):
                return .waits(open + unknown, words: OrderText.capsule(step) ?? "After \(OrderText.list(open + unknown, near: ref))")
            case .unresolved(let unknown):
                return .waits(unknown, words: OrderText.capsule(step) ?? "After \(OrderText.list(unknown, near: ref))")
            case .prerequisiteClosed, .retarget, .inCycle:
                return .holds(OrderText.standing(step) ?? "Check the order")
            default:
                break
            }
            // Stacked on one its order doesn't put before it, one of its own or one it doesn't name: the order
            // decides where it shows, but not where it merges.
            var below: [ItemRef] = []
            for note in step.notes {
                switch note {
                case .orderDisagrees(let other, let origin) where origin.isStacked: below.append(other)
                case .showsAgainst(let other): below.append(other)
                default: break
                }
            }
            var seen: Set<ItemRef> = []
            below = below.filter { statuses[$0] != .merged && seen.insert($0).inserted }
            return below.isEmpty ? nil : stacked(on: below, ref)
        }
        if mission.attached.contains(where: { $0.ref == ref }) {
            // What it's stacked on, wherever that is, the order's pull requests, another mission's or one in none, as Set
            // as Next to Merge reads it.
            let below = mission.stackedBases(of: ref).filter { statuses[$0] != .merged }
            if !below.isEmpty { return stacked(on: below, ref) }
        }
        return nil
    }

    private static func stacked(on below: [ItemRef], _ ref: ItemRef) -> StageOrder {
        .waits(below, words: "After \(OrderText.list(below, near: ref)) · stacked")
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
    /// On yours, a failed build or merge, where a session or a stage you set decides its stage rather than the failure: its
    /// words still say it, after their reason: "‘Cart’ asks you · build failed".
    public var alsoFailing: String?
    /// Where why it's in its stage names a mission, as the order where two go round does: the same naming none, "Another
    /// order puts !4102 after it: check the order", as agents read it. Whether it reads the same goes by that
    /// (`readTheSame`).
    public var unnamedWhy: StageWhy?

    public init(
        stage: PullRequestStage, why: StageWhy, since: Date? = nil, mark: StageMark? = nil, replaced: StageMark? = nil,
        isOnBoard: Bool = true, alsoFailing: String? = nil
    ) {
        self.stage = stage
        self.why = why
        self.since = since
        self.mark = mark
        self.replaced = replaced
        self.isOnBoard = isOnBoard
        self.alsoFailing = alsoFailing
    }

    /// Whether you set what it shows.
    public var isSetByYou: Bool { mark?.isYours == true }

    /// Whether two readings of a pull request, or none, say the same, whatever names the missions they name: a rename, or
    /// Apple Intelligence's name, changes only their words, not its stage.
    public static func readTheSame(_ a: StageReading?, _ b: StageReading?) -> Bool {
        a?.unnamed == b?.unnamed
    }

    /// As it reads naming no mission.
    private var unnamed: StageReading {
        var reading = self
        reading.why = unnamedWhy ?? why
        reading.unnamedWhy = nil
        return reading
    }
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
    /// Someone else's that a review, such as Copilot's pre-review, reads now: "Copilot is pre-reviewing it".
    case preReviewing(StageSession)
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

    /// Whether its reading's `since` is when what it says happened, a session's turn, its end or a merge, so it's worth
    /// saying: "‘Cart’ finished · 10m". Otherwise it's only when its pull request last changed.
    public var saysWhen: Bool {
        switch self {
        case .merged, .working, .asksYou, .finished, .preReviewing: true
        default: false
        }
    }
}

/// How BriefBar works a pull request's stage out: the first rule that applies (plan §2.2), from what its source shows, the
/// Copilot sessions on it, what you or a session set, and its order.
public enum StageRules {
    /// - Parameters:
    ///   - sessions: every Copilot session on it, its source's and the Copilot app's, each once.
    ///   - marks: what you and sessions set, in any order: the latest decides, while it stands (`stands`).
    /// - Returns: nil for one that isn't on your board, such as someone else's you approved, or one closed without merging.
    ///   On yours, a failed build or merge is said too, after the reason of a session or a stage you set that decides it.
    public static func reading(facts: StageFacts, sessions: [StageSession], marks: [StageMark], order: StageOrder) -> StageReading? {
        guard var reading = decided(facts: facts, sessions: sessions, marks: marks, order: order) else { return nil }
        if facts.isYours, facts.state.isOpen, let failure = facts.failure, reading.why != .failing(failure) {
            reading.alsoFailing = failure
        }
        return reading
    }

    /// The first rule that applies.
    private static func decided(facts: StageFacts, sessions: [StageSession], marks: [StageMark], order: StageOrder) -> StageReading? {
        if facts.state == .merged { return StageReading(stage: .merged, why: .merged, since: facts.since) }
        guard facts.state.isOpen else { return nil }
        let (mark, replaced) = standingMark(marks, facts: facts, sessions: sessions)

        // A session at work on it now, since after what was set. On yours, one writing it puts it in progress: one that
        // waits for you first, else the latest to start. Never on someone else's: there, only a review, such as Copilot's
        // pre-review, shows, keeping it yours to review while it runs. One whose start BriefBar doesn't know leaves what was
        // set as it is.
        let busy = sessions.filter { session in
            session.activity.isBusy && mark.map { (session.since ?? .distantPast) > $0.at } ?? true
        }
        if facts.isYours {
            let writing = busy.filter { !$0.isReview }
            if let session = writing.first(where: { $0.activity == .waitsForYou }) ?? latest(writing) {
                let why: StageWhy = session.activity == .waitsForYou ? .asksYou(session) : .working(session)
                return StageReading(stage: .inProgress, why: why, since: session.since)
            }
        } else if let review = latest(busy.filter(\.isReview)) {
            return StageReading(stage: .yourReview, why: .preReviewing(review), since: review.since)
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
        if !facts.othersVoted, let session = latest(sessions.filter { $0.activity == .finished && !$0.isReview }) {
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

    /// A stage you set now, keeping of what it was set over only what `stands` reads to end it: the commit, for In
    /// progress, and for Teammate's review on someone else's; the votes, for Teammate's review alone, on yours how many of
    /// each others cast, on someone else's your own vote. Your review keeps neither.
    public static func mark(_ stage: PullRequestStage, at date: Date, facts: StageFacts) -> StageMark {
        let keepsCommit = stage == .inProgress || (stage == .teammateReview && !facts.isYours)
        return StageMark(stage: stage, at: date, votes: stage == .teammateReview ? facts.votes : nil, commit: keepsCommit ? facts.commit : nil)
    }

    /// Whether a stage set still stands, as the pull request moved on since (plan §2.4). A later change replaces it, which
    /// `standingMark` sees to, and merging or closing it ends it, which comes first anyway. A set In progress ends when a
    /// session writing it finishes, or new commits come, after it was set: a review's end ends nothing. A set Teammate's
    /// review ends when its votes change (`StageFacts.votes`): on yours, the votes others cast; on someone else's that you
    /// finished reviewing, your own vote, and new commits. A set Your review stands until it's changed: BriefBar can't tell
    /// you reviewed it.
    public static func stands(_ mark: StageMark, facts: StageFacts, sessions: [StageSession]) -> Bool {
        let newCommits = mark.commit != nil && facts.commit != nil && mark.commit != facts.commit
        switch mark.stage {
        case .inProgress:
            return !newCommits
                && !sessions.contains { !$0.isReview && $0.activity == .finished && ($0.since ?? .distantPast) > mark.at }
        case .teammateReview:
            if let votes = mark.votes, votes != facts.votes { return false }
            return facts.isYours || !newCommits
        case .yourReview:
            return true
        case .canMerge, .waits, .merged:
            return false
        }
    }

    /// The one that started latest; of those that started together, the earliest reference, whatever order they come in.
    static func latest(_ sessions: [StageSession]) -> StageSession? {
        sessions.max { a, b in
            let (first, second) = (a.since ?? .distantPast, b.since ?? .distantPast)
            return first != second ? first < second : a.ref > b.ref
        }
    }
}

/// What you can do to a pull request's stage, as VoiceOver offers it on its row or its card, in its rotor.
public enum StageAction: Hashable, Sendable {
    case finishedReview
    case move(PullRequestStage)
    case putYoursBack
    case letBriefBarDecide
    /// Your last change, which was to this pull request.
    case undo

    /// "Move to Teammate's Review".
    public var title: String {
        switch self {
        case .finishedReview: "Finished My Review"
        case .move(let stage): "Move to \(stage.menuTitle)"
        case .putYoursBack: "Put Yours Back"
        case .letBriefBarDecide: "Let BriefBar Decide"
        case .undo: "Undo"
        }
    }

    /// What's offered for a pull request with this stage, or none, and Undo last while your last change was to it: even
    /// once it has no stage left to show, so what you did can always be undone where you did it.
    /// - Parameter isYours: you opened it: someone else's asks for its own reviews.
    public static func offered(for reading: StageReading?, canUndo: Bool, isYours: Bool = true) -> [StageAction] {
        (reading.map { offered(for: $0, isYours: isYours) } ?? []) + (canUndo ? [.undo] : [])
    }

    /// What's offered for a pull request in this stage: Finished My Review in Your review; each stage you can set but the
    /// one it's in, where someone else's that you finished reviewing is in Teammate's review, and but Teammate's review on
    /// someone else's, whose author asks for its reviews: Finished My Review takes it off your board instead; Put Yours Back
    /// once a session's change replaced yours; Let BriefBar Decide for one you set. Nothing once it merged.
    /// - Parameter isYours: you opened it.
    public static func offered(for reading: StageReading, isYours: Bool = true) -> [StageAction] {
        guard reading.stage != .merged else { return [] }
        var actions: [StageAction] = []
        if reading.stage == .yourReview { actions.append(.finishedReview) }
        actions += PullRequestStage.settable.filter { $0 != reading.stage && (isYours || $0 != .teammateReview) }
            .map(StageAction.move)
        if reading.replaced != nil { actions.append(.putYoursBack) }
        if reading.isSetByYou { actions.append(.letBriefBarDecide) }
        return actions
    }
}

/// Where Undo is, after you change a stage, as VoiceOver tells it.
public enum StageUndoPlace: Sendable {
    /// In the pull request's stage's menu, on its row or card.
    case stageMenu
    /// On the Board: a card that leaves it leaves its Undo at the top of its lane.
    case lane
}

// MARK: - Words

/// What a stage says, in BriefBar's words, for the pull requests' rows, their details and VoiceOver: sessions by their
/// names, pull requests by their numbers.
public enum StageText {
    /// Why it's in its stage: "‘Cart’ finished", "Find a reviewer", "After !4102"; with a failed build or merge after it
    /// where something else decides its stage: "‘Cart’ asks you · build failed".
    /// - Parameters:
    ///   - name: what the sources call a session, when they say.
    ///   - separator: before the failure: ", " for VoiceOver, which reads it as a pause.
    public static func why(_ reading: StageReading, name: (ItemRef) -> String?, then separator: String = " · ") -> String {
        let words = reason(reading, name: name)
        guard let failing = reading.alsoFailing, let first = failing.first else { return words }
        return words + separator + first.lowercased() + failing.dropFirst()
    }

    private static func reason(_ reading: StageReading, name: (ItemRef) -> String?) -> String {
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
        case .preReviewing(let session): return "\(called(session, name: name)) is pre-reviewing it"
        case .draft: return "Draft"
        case .ready(let autoComplete): return autoComplete ? "Completing automatically" : "Complete it"
        case .waitsFor(_, let words): return words
        case .findReviewer: return "Find a reviewer"
        case .finishedReview: return "You finished your review: vote in Azure DevOps when you're ready"
        }
    }

    /// Who set it, and how long ago, when someone did: "You set it 2h ago", "‘Cart’ set it 5m ago, after you".
    public static func who(_ reading: StageReading, now: Date, name: (ItemRef) -> String?) -> String? {
        guard let mark = reading.mark else { return nil }
        var words = setter(mark, name: name) + " set it " + agoWords(mark.at, now: now)
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

    /// What VoiceOver hears once you changed it: where it is now, and where Undo is. "!4093 is in Teammate's review now.
    /// Undo is in its stage's menu." With no stage left, such as someone else's that asks nothing of you once BriefBar
    /// decides, it's off your board.
    /// - Parameter undo: where you changed it: on the Board, a card that left the board leaves its Undo at the top of its lane.
    public static func changed(_ ref: ItemRef, to reading: StageReading?, undo: StageUndoPlace = .stageMenu) -> String {
        let isOnBoard = reading?.isOnBoard ?? false
        let place = reading.map { $0.isOnBoard ? "is in \($0.stage.title) now" : "is off your board now" } ?? "is off your board now"
        let undoPlace = undo == .lane && !isOnBoard ? "at the top of its lane" : "in its stage's menu"
        return "\(ref.shortOrderLabel) \(place). Undo is \(undoPlace)."
    }

    /// Why someone else's pull request can't be set to Teammate's review: "It's Priya's: they ask for its reviews".
    /// - Parameter author: who opened it, by their first name, when known.
    public static func whyNotTeammateReview(author: String?) -> String {
        (author.map { "It's \($0)'s" } ?? "It's someone else's") + ": they ask for its reviews"
    }

    /// What Finished My Review does to someone else's pull request, under it in its stage's menu.
    public static let finishedOthersReview = "It leaves your board; your vote stays yours to cast in Azure DevOps"

    /// What VoiceOver hears once you undid it: "Undone: !4093 is in Your review again".
    public static func undone(_ ref: ItemRef, to reading: StageReading?) -> String {
        guard let reading else { return "Undone" }
        let place = reading.isOnBoard ? "is in \(reading.stage.title) again" : "is off your board again"
        return "Undone: \(ref.shortOrderLabel) \(place)"
    }

    /// How many of a mission's pull requests are in each stage, in the stages' order, for its progress bar: "1 in progress ·
    /// 2 for your review · 1 waits · 1 merged"; nil with none.
    public static func counts(_ stages: [PullRequestStage]) -> String? {
        let parts = PullRequestStage.allCases.compactMap { stage -> String? in
            let count = stages.filter { $0 == stage }.count
            guard count > 0 else { return nil }
            return switch stage {
            case .inProgress: "\(count) in progress"
            case .yourReview: "\(count) for your review"
            case .teammateReview: "\(count) for a teammate's review"
            case .canMerge: "\(count) can merge"
            case .waits: count == 1 ? "1 waits for another PR" : "\(count) wait for other PRs"
            case .merged: "\(count) merged"
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
