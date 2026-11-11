import Foundation

/// Where a pull request is in its flow, as a column of a kanban board says it: how far it got, and whose turn it is. With
/// Pull Request Order on, for Azure DevOps' pull requests. BriefBar works it out from what its sources show, and how far
/// each of yours got (`StageRules`, `StagesReached`); you, or a session, can set one of the first three when you know
/// better (`StageMark`), and the latest change wins. Approved, Can merge, Waits and Merged come only from what BriefBar
/// sees. What goes wrong on one doesn't move it: its words and its card say it (`StageFlag`).
public enum PullRequestStage: String, Codable, Sendable, CaseIterable {
    /// Its work isn't done: it's a draft, or its code is being written, or you or a session sent it back.
    case inProgress
    /// You review it next.
    case yourReview
    /// Others review it next.
    case teammateReview
    /// Yours: the reviewers it requires approved, as Azure DevOps counts them, but it can't complete yet.
    case approved
    /// Azure DevOps says it's ready to complete, and BriefBar saw everything its order puts before it merge.
    case canMerge
    /// Azure DevOps says it's ready to complete, but its order puts it after one BriefBar hasn't seen merge.
    case waits
    /// BriefBar saw it merge.
    case merged

    /// What you, or a session, can set: the rest come only from what BriefBar sees, so nobody can claim a pull request is
    /// approved, can merge, or merged, before Azure DevOps shows it.
    public static let settable: [PullRequestStage] = [.inProgress, .yourReview, .teammateReview]

    public var isSettable: Bool { Self.settable.contains(self) }

    /// "Teammate's review".
    public var title: String {
        switch self {
        case .inProgress: "In progress"
        case .yourReview: "Your review"
        case .teammateReview: "Teammate's review"
        case .approved: "Approved"
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
        case .approved: "Approved"
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
        case .approved: "checkmark.seal.fill"
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
        case .approved: 3
        case .canMerge, .waits: 4
        case .merged: 5
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
    /// Yours: whether the reviewers it requires approved, as Azure DevOps counts them, whatever else is left: every review
    /// What's Left has of it done, approvals, the reviewers it requires and any other reviewer policy, with one at least;
    /// nil while BriefBar can't tell, as before its details are read, while they were read before its latest push or vote,
    /// or where its project doesn't let you read its policies.
    public var isApproved: Bool?
    /// Yours: who approved it but you, by their first names, as a team by its name: "Maria", "Maria and Priya"; nil while
    /// nobody did.
    public var approvedBy: String?
    /// Yours, approved, but not ready: What's Left's first item that isn't what fails or changes someone wants, which say
    /// themselves (`StageFlag`), such as "Build running" or "Resolve 2 comments"; nil while nothing else is left.
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
    /// When its source read what it says of it, when it says: a stage set since, such as by a session that read it again
    /// itself, isn't ended by its votes or its commit until its source reads it again (`StageRules.stands`).
    public var readAt: Date?

    public init(
        role: Role, state: PullRequestState = .open, failure: String? = nil, changesWanted: String? = nil, asksYou: String? = nil,
        isReady: Bool = false, autoComplete: Bool = false, isApproved: Bool? = false, approvedBy: String? = nil,
        leftAfterReviews: String? = nil, waitingFor: String? = nil, othersVoted: Bool = false, youWantChanges: String? = nil,
        votes: String = "", commit: String? = nil, sessions: [StageSession] = [], since: Date? = nil, isListed: Bool = true,
        author: String? = nil, readAt: Date? = nil
    ) {
        self.role = role
        self.state = state
        self.failure = failure
        self.changesWanted = changesWanted
        self.asksYou = asksYou
        self.isReady = isReady
        self.autoComplete = autoComplete
        self.isApproved = isApproved
        self.approvedBy = approvedBy
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
        self.readAt = readAt
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

    /// Whether this is a session's Your review that followed one of yours, as `--mcp` keeps one where yours was the latest
    /// stage set: without votes, so it lasts as yours does, while yours is there (`follows`, `StageRules.counted`).
    public var followsYours: Bool { !isYours && stage == .yourReview && votes == nil }

    /// Whether this is a session's Your review that followed this one of yours: set after it, keeping no votes.
    public func follows(_ yours: StageMark) -> Bool {
        followsYours && yours.isYours && yours.stage == .yourReview && at > yours.at
    }

    /// Whether this is a Your review of yours that outlasts what sessions set after it: only In progress, as a session
    /// works on it, and Your reviews that follow it (`follows`). It lasts until you change it, so it shows again once
    /// those end; any other stage a session set after it replaced it (`StageRules.counted`).
    public func outlasts(_ theirs: [StageMark]) -> Bool {
        isYours && stage == .yourReview
            && theirs.allSatisfy { $0.at <= at || $0.stage == .inProgress || $0.follows(self) }
    }
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
    /// Yours, which a session's later change replaced: Put Yours Back makes it the latest again, while that change
    /// lasts. Once it ends, yours goes too, unless it outlasts it (`replacedOutlasts`).
    public var replaced: StageMark?
    /// Whether yours, which `replaced` holds, outlasts what replaced it: a Your review of yours under sessions' In
    /// progress alone shows again once that ends (`StageMark.outlasts`).
    public var replacedOutlasts: Bool
    /// Yours, which a session's later Your review followed, as `--mcp` keeps one where yours was the latest stage set, as
    /// a session that pushed says its work is ready: without votes, so it lasts as yours does. It shows the session's, and
    /// Let BriefBar Decide forgets both.
    public var followed: StageMark?
    /// Whether it's on your board: not someone else's that you finished reviewing, until something new needs you there.
    public var isOnBoard: Bool
    /// On yours, what else goes on with it than why it's in its stage, which doesn't move it: marks on its card, and its
    /// words after why, in this order: a session that asks you, one that writes it, what fails, changes someone wants;
    /// each only where why doesn't say it already: "Waiting on Sam · build failed", "‘Cart’ finished · Priya wants
    /// changes". The session that set its In progress writes it too, which its words say already (`saidFlags`).
    public var flags: [StageFlag]
    /// Where why it's in its stage names a mission, as the order where two go round does: the same naming none, "Another
    /// order puts !4102 after it: check the order", as agents read it. Whether it reads the same goes by that
    /// (`readTheSame`).
    public var unnamedWhy: StageWhy?

    public init(
        stage: PullRequestStage, why: StageWhy, since: Date? = nil, mark: StageMark? = nil, replaced: StageMark? = nil,
        replacedOutlasts: Bool = false, followed: StageMark? = nil, isOnBoard: Bool = true, flags: [StageFlag] = []
    ) {
        self.stage = stage
        self.why = why
        self.since = since
        self.mark = mark
        self.replaced = replaced
        self.replacedOutlasts = replacedOutlasts
        self.followed = followed
        self.isOnBoard = isOnBoard
        self.flags = flags
    }

    /// What fails on it, where why doesn't say it: its failing flag's words, "Build failed".
    public var alsoFailing: String? {
        flags.lazy.compactMap { flag -> String? in
            if case .failing(let words) = flag { return words }
            return nil
        }.first
    }

    /// Its flags as its words and its card say them: all but the session that set its In progress writing it, which
    /// "‘Cart’ is on it" says already.
    public var saidFlags: [StageFlag] {
        guard why == .set, stage == .inProgress, let setter = mark?.by else { return flags }
        return flags.filter { flag in
            if case .working(let session) = flag { return session.ref != setter }
            return true
        }
    }

    /// The session that writes it now, as why it's in its stage or its flags say.
    public var writer: StageSession? {
        if case .working(let session) = why { return session }
        return flags.lazy.compactMap { flag -> StageSession? in
            if case .working(let session) = flag { return session }
            return nil
        }.first
    }

    /// Whether you set what it shows.
    public var isSetByYou: Bool { mark?.isYours == true }

    /// Whether Let BriefBar Decide applies: to what you set, while it shows, or a session's Your review that followed it
    /// shows in its place (`followed`).
    public var canLetBriefBarDecide: Bool { isSetByYou || followed != nil }

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
    /// Yours, approved, with nothing else left but what its flags say: who approved it, "Maria approved it".
    case approvedBy(String)
    /// Yours, back to your review where it got before, which the session that finished writing it no longer says, as it
    /// writes it again: "Waiting for your review".
    case awaitsYourReview
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

/// What else goes on with one of your pull requests than why it's in its stage, which doesn't move it, wherever it is: a
/// mark on its card, and its words after why. What needs you of them, Fix next offers, from every column
/// (`StageReading.fixRank`).
public enum StageFlag: Equatable, Sendable {
    /// "‘Cart’ asks you": a session on it waits for your answer, a plan's approval or a permission.
    case asksYou(StageSession)
    /// "‘Cart’ is writing it": a session writes or fixes its code now.
    case working(StageSession)
    /// "Build failed", "Merge conflicts": a required build or check failed or expired, or its merge can't be made.
    case failing(String)
    /// "Priya wants changes", "Sam rejected it".
    case changesWanted(String)
}

/// How far one of your pull requests got, as BriefBar keeps it (`StagesReached`), and since when.
public struct StageReach: Equatable, Sendable {
    public var stage: PullRequestStage
    /// When it got there, as BriefBar saw it.
    public var since: Date?
    /// It's where BriefBar first saw it, minutes ago at most (`StagesReached.firstSight`), before it knew of a session
    /// writing it, and nothing moved it since: a session already at work on it then, or done, may be the one that opened
    /// it, which BriefBar didn't know of yet.
    public var isFirst: Bool

    public init(_ stage: PullRequestStage, since: Date? = nil, isFirst: Bool = false) {
        self.stage = stage
        self.since = since
        self.isFirst = isFirst
    }
}

/// How BriefBar works a pull request's stage out: the first rule that applies (plan §2.2), from what its source shows, the
/// Copilot sessions on it, what you or a session set, its order, and, for yours, how far it got (`StagesReached`).
/// BriefBar never moves one of yours back on its own, but where it loses what its stage stands for: its approval, back to
/// Teammate's review, or Azure DevOps' readiness while it's still approved, back to Approved. What goes wrong on it doesn't
/// move it: a session that asks you or writes it, what fails, and changes someone wants are its flags (`StageFlag`).
public enum StageRules {
    /// - Parameters:
    ///   - sessions: every Copilot session on it, its source's and the Copilot app's, each once.
    ///   - marks: what you and sessions set, in any order: the latest decides, while it stands (`stands`).
    ///   - setters: what the sessions that set them do now, as the sources list them, on it or not (`stands`).
    ///   - reached: how far it got, for yours, as BriefBar kept it (`reached(kept:ended:)`): nil for one that got no further
    ///     than In progress, or that BriefBar hasn't seen before.
    /// - Returns: nil for one that isn't on your board, such as someone else's you approved, or one closed without merging.
    ///   On yours, its flags too.
    public static func reading(
        facts: StageFacts, sessions: [StageSession], marks: [StageMark], order: StageOrder, setters: [ItemRef: StageSession] = [:],
        reached: StageReach? = nil
    ) -> StageReading? {
        guard var reading = decided(
            facts: facts, sessions: sessions, marks: marks, order: order, setters: setters, reached: reached
        ) else { return nil }
        if facts.isYours, facts.state.isOpen {
            reading.flags = flags(facts: facts, sessions: sessions, for: reading, setters: setters)
        }
        return reading
    }

    /// The first rule that applies.
    private static func decided(
        facts: StageFacts, sessions: [StageSession], marks: [StageMark], order: StageOrder, setters: [ItemRef: StageSession],
        reached: StageReach?
    ) -> StageReading? {
        if facts.state == .merged { return StageReading(stage: .merged, why: .merged, since: facts.since) }
        guard facts.state.isOpen else { return nil }
        let (mark, replaced, followed) = standingMark(marks, facts: facts, sessions: sessions, setters: setters)

        // On someone else's, a review at work on it now, since after what was set, such as Copilot's pre-review, keeps it
        // yours to review while it runs. One whose start BriefBar doesn't know leaves what was set as it is. On yours, a
        // session at work moves nothing that was set: it's a flag.
        if !facts.isYours, let review = latest(sessions.filter { session in
            session.isReview && session.activity.isBusy && mark.map { (session.since ?? .distantPast) > $0.at } ?? true
        }) {
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
                return StageReading(
                    stage: mark.stage, why: .set, since: mark.at, mark: mark, replaced: replaced,
                    replacedOutlasts: replaced?.outlasts(marks.filter { !$0.isYours }) == true, followed: followed
                )
            }
        }

        guard facts.isYours else {
            if let asked = facts.asksYou, facts.state != .draft {
                return StageReading(stage: .yourReview, why: .asked(asked), since: facts.since)
            }
            if let changes = facts.youWantChanges {
                return StageReading(stage: .inProgress, why: .authorChanges(changes), since: facts.since)
            }
            return nil
        }
        return worked(facts: facts, sessions: sessions, reached: reached, order: order)
    }

    /// Where BriefBar puts one of your open pull requests itself, whatever you or a session set: as far as what its source
    /// shows takes it, and never back from how far it got (`reached`), but where it lost what that stage stands for. A
    /// draft is in progress, unless a session finished writing it and nobody else approved it, as for one that isn't; one
    /// that's ready to complete can merge, or waits, by its order; one approved is Approved; one that isn't, after it got
    /// to Teammate's review or further, as when a push reset its votes, waits for teammates again. Before that: in
    /// progress while the session that opened it writes it, nobody else having voted on it yet; yours to review once a
    /// session finished writing it, or once it got there before, as when a session writes it again, until someone else
    /// approves it; else your teammates'. One BriefBar first saw in Teammate's review minutes ago, before it knew of any
    /// session writing it, as when Azure DevOps listed it before the Copilot app said which session opened it, is that
    /// session's, as one BriefBar saw nowhere yet, where the session's turn began, or ended, by then. Where BriefBar can't tell whether it's
    /// approved, as while its details are read again after a push or a vote, it stays in Approved or Can merge where it was.
    public static func worked(
        facts: StageFacts, sessions: [StageSession], reached reach: StageReach?, order: StageOrder
    ) -> StageReading {
        let reached = reach?.stage
        let since = facts.since
        let writing = sessions.filter { !$0.isReview }
        let finished = latest(writing.filter { $0.activity == .finished })
        let othersApproved = facts.approvedBy != nil
        if facts.state == .draft {
            if !othersApproved, let finished { return StageReading(stage: .yourReview, why: .finished(finished), since: finished.since) }
            return StageReading(stage: .inProgress, why: .draft, since: since)
        }
        if facts.isReady || (facts.isApproved == nil && reached == .canMerge) {
            switch order {
            case .free: return StageReading(stage: .canMerge, why: .ready(autoComplete: facts.autoComplete), since: since)
            case .waits(let refs, let words): return StageReading(stage: .waits, why: .waitsFor(refs, words: words), since: since)
            case .holds(let words): return StageReading(stage: .waits, why: .orderHolds(words), since: since)
            }
        }
        if facts.isApproved ?? (reached == .approved) {
            return StageReading(stage: .approved, why: approvedWhy(facts), since: since)
        }
        // Seen in Teammate's review before BriefBar knew of this session, which was at work, or done, by then.
        let unknownThen = { (session: StageSession) in
            reach.map { $0.stage == .teammateReview && $0.isFirst && isAtOrBefore(session.since, $0.since) } ?? false
        }
        let busy = writing.filter(\.activity.isBusy)
        if !facts.othersVoted, let session = busy.first(where: { $0.activity == .waitsForYou }) ?? latest(busy),
           reached == nil || unknownThen(session) {
            let why: StageWhy = session.activity == .waitsForYou ? .asksYou(session) : .working(session)
            return StageReading(stage: .inProgress, why: why, since: session.since)
        }
        let teammates = StageReading(
            stage: .teammateReview, why: facts.waitingFor.map(StageWhy.waitingFor) ?? .findReviewer, since: since
        )
        switch reached {
        case nil, .yourReview?:
            if !othersApproved {
                if let finished { return StageReading(stage: .yourReview, why: .finished(finished), since: finished.since) }
                if reached == .yourReview {
                    return StageReading(stage: .yourReview, why: .awaitsYourReview, since: reach?.since ?? since)
                }
            }
        case .teammateReview?:
            if !othersApproved, let finished, unknownThen(finished) {
                return StageReading(stage: .yourReview, why: .finished(finished), since: finished.since)
            }
        default:
            break
        }
        return teammates
    }

    /// Whether one date is the other or before it, both known.
    private static func isAtOrBefore(_ date: Date?, _ other: Date?) -> Bool {
        guard let date, let other else { return false }
        return date <= other
    }

    /// Why one of yours is approved: what's left that its flags don't say, else who approved it, else what fails or who
    /// wants changes, else that it isn't ready yet.
    private static func approvedWhy(_ facts: StageFacts) -> StageWhy {
        if let left = facts.leftAfterReviews { return .left(left) }
        if let names = facts.approvedBy { return .approvedBy(names) }
        if let failure = facts.failure { return .failing(failure) }
        if let changes = facts.changesWanted { return .changesWanted(changes) }
        return .left(StageText.notReadyYet)
    }

    /// How far one of your pull requests got, as BriefBar works its stage out itself (`worked`), for it to keep: nil for
    /// In progress, which BriefBar keeps nothing of, and for one that merged or closed; Waits as Can merge, which its order
    /// tells apart.
    public static func reached(_ worked: StageReading) -> PullRequestStage? {
        switch worked.stage {
        case .inProgress, .merged: nil
        case .waits: .canMerge
        case .yourReview, .teammateReview, .approved, .canMerge: worked.stage
        }
    }

    /// How far it got, for what BriefBar works out once what you or a session set no longer stands, as the pull request
    /// moved on: from the stage that was set, which moved it there, whatever BriefBar had worked out meanwhile; nil for In
    /// progress.
    public static func reached(set stage: PullRequestStage) -> PullRequestStage? {
        switch stage {
        case .yourReview, .teammateReview: stage
        default: nil
        }
    }

    /// How far one of yours got, for working its stage out now (`reading`): as BriefBar kept it (`StagesReached`); but as
    /// what you or a session set ends, from that (`counted`'s ended, `reached(set:)`), as it moved it there then.
    public static func reached(kept: StageReach?, ended: StageMark?) -> StageReach? {
        guard let ended else { return kept }
        return reached(set: ended.stage).map { StageReach($0, since: ended.at) }
    }

    /// One of yours' flags, beside its reading: the sessions that write it or ask you, but a review, which writes nothing;
    /// what fails; and changes someone wants: each once, and not what why says already. Of the sessions that write it,
    /// one besides the session whose In progress shows, which its words name already (`saidFlags`). That session writes
    /// it whether or not BriefBar sees it on it otherwise, as `stands` has it: what it does now comes from `setters`.
    static func flags(
        facts: StageFacts, sessions: [StageSession], for reading: StageReading, setters: [ItemRef: StageSession] = [:]
    ) -> [StageFlag] {
        let setter = reading.why == .set && reading.stage == .inProgress ? reading.mark?.by : nil
        let unseen = setter.flatMap { setter in sessions.contains { $0.ref == setter } ? nil : setters[setter] }
        let busy = (sessions + [unseen].compactMap { $0 }).filter { !$0.isReview && $0.activity.isBusy }
        var flags: [StageFlag] = []
        if let asking = busy.first(where: { $0.activity == .waitsForYou }), reading.why != .asksYou(asking) {
            flags.append(.asksYou(asking))
        }
        let writing = busy.filter { $0.activity == .working }
        if let working = latest(writing.filter { $0.ref != setter }) ?? latest(writing), reading.why != .working(working) {
            flags.append(.working(working))
        }
        if let failure = facts.failure, reading.why != .failing(failure) { flags.append(.failing(failure)) }
        if let changes = facts.changesWanted, reading.why != .changesWanted(changes) { flags.append(.changesWanted(changes)) }
        return flags
    }

    /// The latest of what was set, while it stands; yours when a session's later change replaced it with another stage;
    /// and yours when a session's later Your review followed it (`StageReading.followed`, `StageMark.follows`): one that
    /// keeps no votes, as `--mcp` keeps it only where yours was the latest stage set. A session's own report, with its
    /// votes, which came after another stage replaced yours, follows nothing. Once the latest ends, none of them counts:
    /// BriefBar works the stage out again.
    static func standingMark(
        _ marks: [StageMark], facts: StageFacts, sessions: [StageSession], setters: [ItemRef: StageSession] = [:]
    ) -> (mark: StageMark?, replaced: StageMark?, followed: StageMark?) {
        guard let latest = marks.max(by: { $0.at < $1.at }), stands(latest, facts: facts, sessions: sessions, setters: setters)
        else { return (nil, nil, nil) }
        guard !latest.isYours, let yours = marks.filter(\.isYours).max(by: { $0.at < $1.at }) else { return (latest, nil, nil) }
        if yours.stage != latest.stage { return (latest, yours, nil) }
        return (latest, nil, latest.follows(yours) ? yours : nil)
    }

    /// What you and the sessions set on a pull request that counts now (`reading`'s marks): yours while it stands, and
    /// the sessions', while the latest of them all stands and the pull request is open. Once the latest ends, or it merged
    /// or closed, none counts, and `latestEnded` says so, for what keeps them to end them all, so that an older one never
    /// comes back; but a Your review of yours that only sessions' In progress came after, which outlasts it, stays,
    /// with the sessions' Your reviews that follow it (`StageMark.outlasts`). A session's Your review that followed one
    /// of yours counts only while that one of yours is there (`StageMark.follows`): once yours is gone, as with Undo,
    /// also as you took it away while `--mcp` kept it, it lasts no more on its own.
    /// - Parameters:
    ///   - theirs: what the sessions the sources list set on it (`SessionStages.marks`).
    ///   - setters: what those sessions do now, on it or not (`stands`).
    /// - Returns: with `ended`, the latest, once it ended and nothing of yours outlasts it: what moved it last, for how far
    ///   it got (`reached(kept:ended:)`).
    public static func counted(
        yours: StageMark?, theirs: [StageMark], facts: StageFacts, sessions: [StageSession], setters: [ItemRef: StageSession] = [:]
    ) -> (yours: StageMark?, theirs: [StageMark], latestEnded: Bool, ended: StageMark?) {
        let theirs = theirs.filter { !$0.followsYours || yours.map($0.follows) == true }
        let latest = ([yours].compactMap { $0 } + theirs).max { $0.at < $1.at }
        let latestEnded = !facts.state.isOpen || latest.map { !stands($0, facts: facts, sessions: sessions, setters: setters) } == true
        let lasts = facts.state.isOpen && yours?.outlasts(theirs) == true
        let mine = yours.flatMap {
            (latestEnded && !lasts) || !stands($0, facts: facts, sessions: sessions, setters: setters) ? nil : $0
        }
        guard latestEnded else { return (mine, theirs, false, nil) }
        return (mine, mine.map { yours in theirs.filter { $0.follows(yours) } } ?? [], true, mine == nil ? latest : nil)
    }

    /// A stage you or a session set now, keeping of what it was set over only what `stands` reads to end it: the
    /// commit, for In progress, and for Teammate's review on someone else's; the votes, on yours how many of each
    /// others cast, on someone else's your own vote, for Teammate's review, and for Your review a session set. Your
    /// own Your review keeps neither.
    /// - Parameter session: the session that set it, nil for you.
    public static func mark(
        _ stage: PullRequestStage, at date: Date, facts: StageFacts, by session: ItemRef? = nil
    ) -> StageMark {
        let keepsCommit = stage == .inProgress || (stage == .teammateReview && !facts.isYours)
        let keepsVotes = stage == .teammateReview || (stage == .yourReview && session != nil)
        let votes = keepsVotes ? facts.votes : nil
        return StageMark(stage: stage, at: date, by: session, votes: votes, commit: keepsCommit ? facts.commit : nil)
    }

    /// Whether a stage set still stands, as the pull request moved on since (plan §2.4). A later change replaces it,
    /// which `standingMark` sees to, and merging or closing it ends it, which comes first anyway. A set In progress
    /// ends when a session writing it finishes, or new commits come, after it was set: a review's end ends nothing. A
    /// set Teammate's review ends when its votes change (`StageFacts.votes`): on yours, the votes others cast; on
    /// someone else's that you finished reviewing, your own vote, and new commits. A Your review you set stands until
    /// it's changed: BriefBar can't tell you reviewed it. One a session set ends as its votes change, as Teammate's
    /// review does: it said its work was ready for you, as ‘Cart’ finished does, so that one a teammate approved moves on
    /// to Approved, Can merge or Waits; once it ends, BriefBar goes on from Your review (`reached(set:)`), so that one
    /// someone only wants changes on stays there, marked. Votes and commits count only
    /// as its source read them after it was set, when it says when it read them (`StageFacts.readAt`): a session that
    /// read the pull request itself, just now, may have seen what its source hasn't yet. A session's own In progress
    /// ends as that session finishes too, whether or not BriefBar sees it on the pull request otherwise: it was writing
    /// it.
    /// - Parameter setters: what the sessions that set stages do now, as the sources list them, by their references.
    public static func stands(
        _ mark: StageMark, facts: StageFacts, sessions: [StageSession], setters: [ItemRef: StageSession] = [:]
    ) -> Bool {
        let readSince = facts.readAt.map { $0 >= mark.at } ?? true
        let newCommits = readSince && mark.commit != nil && facts.commit != nil && mark.commit != facts.commit
        switch mark.stage {
        case .inProgress:
            let writing = sessions + [mark.by.flatMap { setters[$0] }].compactMap { $0 }
            return !newCommits
                && !writing.contains { !$0.isReview && $0.activity == .finished && ($0.since ?? .distantPast) > mark.at }
        case .teammateReview:
            if readSince, let votes = mark.votes, votes != facts.votes { return false }
            return facts.isYours || !newCommits
        case .yourReview:
            if !mark.isYours, readSince, let votes = mark.votes, votes != facts.votes { return false }
            return true
        case .approved, .canMerge, .waits, .merged:
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
    /// once a session's change replaced yours; Let BriefBar Decide for one you set, also where a session's Your review that
    /// followed it shows in its place. Nothing once it merged.
    /// - Parameter isYours: you opened it.
    public static func offered(for reading: StageReading, isYours: Bool = true) -> [StageAction] {
        guard reading.stage != .merged else { return [] }
        var actions: [StageAction] = []
        if reading.stage == .yourReview { actions.append(.finishedReview) }
        actions += PullRequestStage.settable.filter { $0 != reading.stage && (isYours || $0 != .teammateReview) }
            .map(StageAction.move)
        if reading.replaced != nil { actions.append(.putYoursBack) }
        if reading.canLetBriefBarDecide { actions.append(.letBriefBarDecide) }
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
    /// Why it's in its stage: "‘Cart’ finished", "Find a reviewer", "After !4102"; with its flags after it, on yours:
    /// "Waiting on Sam · build failed", "‘Cart’ finished · ‘Cart’ asks you · Priya wants changes".
    /// - Parameters:
    ///   - name: what the sources call a session, when they say.
    ///   - separator: before each flag: ", " for VoiceOver, which reads it as a pause.
    public static func why(_ reading: StageReading, name: (ItemRef) -> String?, then separator: String = " · ") -> String {
        reason(reading, name: name) + flags(reading, name: name, then: separator)
    }

    /// Its flags, after why it's in its stage: " · ‘Cart’ is writing it · build failed"; nothing without any.
    public static func flags(_ reading: StageReading, name: (ItemRef) -> String?, then separator: String = " · ") -> String {
        reading.saidFlags.map { separator + words($0, name: name) }.joined()
    }

    /// A flag, as it follows why: "‘Cart’ asks you", "build failed", "Priya wants changes", "changes requested".
    public static func words(_ flag: StageFlag, name: (ItemRef) -> String?) -> String {
        switch flag {
        case .asksYou(let session): return "\(called(session, name: name)) asks you"
        case .working(let session): return "\(called(session, name: name)) is writing it"
        case .failing(let words): return lowercasingFirst(words)
        // Who wants changes keeps their name's capital.
        case .changesWanted(let words): return words.hasPrefix("Changes ") ? lowercasingFirst(words) : words
        }
    }

    /// A flag on its own, as a card's mark says it: "‘Cart’ asks you", "Build failed", "Priya wants changes".
    public static func mark(_ flag: StageFlag, name: (ItemRef) -> String?) -> String {
        switch flag {
        case .asksYou, .working: words(flag, name: name)
        case .failing(let words), .changesWanted(let words): words
        }
    }

    private static func lowercasingFirst(_ words: String) -> String {
        guard let first = words.first else { return words }
        return first.lowercased() + words.dropFirst()
    }

    /// What Fix next says of one that needs you: what needs you first, as its flags or why say it, then, for one in
    /// another column than In progress, where it is: "Build failed · in Approved", "‘Cart’ asks you · in Your review";
    /// else why it's in its stage, as `why` says it, "‘Cart’ asks you".
    public static func fixWords(_ reading: StageReading, name: (ItemRef) -> String?, then separator: String = " · ") -> String {
        func needs(_ rank: Int, _ flag: StageFlag) -> Bool {
            switch (rank, flag) {
            case (0, .asksYou), (1, .failing), (2, .changesWanted): true
            default: false
            }
        }
        guard reading.stage != .inProgress, let rank = reading.fixRank else { return why(reading, name: name, then: separator) }
        let saysIt: Bool = switch (rank, reading.why) {
        case (0, .asksYou), (1, .failing), (2, .changesWanted): true
        default: false
        }
        let first = saysIt ? reason(reading, name: name) : reading.flags.first { needs(rank, $0) }.map { mark($0, name: name) }
        guard let first else { return why(reading, name: name, then: separator) }
        return first + separator + "in " + reading.stage.columnTitle
    }

    /// What an approved pull request says when nothing tells what's left of it, nor who approved it.
    public static let notReadyYet = "Not ready to complete yet"

    /// Why it's in its stage alone, without its flags, as a card says it above its marks: "Maria approved it".
    public static func reason(_ reading: StageReading, name: (ItemRef) -> String?) -> String {
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
        case .approvedBy(let names): return "\(names) approved it"
        case .awaitsYourReview: return "Waiting for your review"
        case .finished(let session): return "\(called(session, name: name)) finished"
        case .preReviewing(let session): return "\(called(session, name: name)) is pre-reviewing it"
        case .draft: return "Draft"
        case .ready(let autoComplete): return autoComplete ? "Completing automatically" : "Complete it"
        case .waitsFor(_, let words): return words
        case .findReviewer: return "Find a reviewer"
        case .finishedReview: return "You finished your review: vote in Azure DevOps when you're ready"
        }
    }

    /// Who set it, and how long ago, when someone did: "You set it 2h ago", "‘Cart’ set it 5m ago, after you"; only when,
    /// where why it's in its stage names the session already (`namesWhoSetIt`): "set 5m ago", after "‘Cart’ says it's
    /// ready".
    public static func who(_ reading: StageReading, now: Date, name: (ItemRef) -> String?) -> String? {
        guard let mark = reading.mark else { return nil }
        var words = (namesWhoSetIt(reading) ? "set " : setter(mark, name: name) + " set it ") + agoWords(mark.at, now: now)
        if reading.replaced != nil { words += ", after you" }
        return words
    }

    /// The same, as VoiceOver says it: "set by you 2 hours ago", "worked out by BriefBar"; "set 5 minutes ago" where why
    /// it's in its stage names the session.
    public static func spokenWho(_ reading: StageReading, now: Date, name: (ItemRef) -> String?) -> String {
        guard let mark = reading.mark else { return "worked out by BriefBar" }
        let who = namesWhoSetIt(reading) ? "set" : mark.by.map { "set by \(quoted($0, name: name))" } ?? "set by you"
        return who + " " + Elapsed.spoken(since: mark.at, now: now) + " ago" + (reading.replaced != nil ? ", after you" : "")
    }

    /// For its tooltip, and its menu's first line: "Your review: ‘Cart’ finished. Worked out by BriefBar.", "Your review:
    /// ‘Cart’ says it's ready. Set 5m ago.", and "…, after you." where a session's replaced yours.
    public static func sentence(_ reading: StageReading, now: Date, name: (ItemRef) -> String?) -> String {
        let who = reading.mark.map { mark in
            (namesWhoSetIt(reading) ? "Set " : setter(mark, name: name) + " set it ") + agoWords(mark.at, now: now)
                + (reading.replaced != nil ? ", after you" : "")
        } ?? "Worked out by BriefBar"
        return "\(reading.stage.title): \(why(reading, name: name)). \(who)."
    }

    /// Whether why it's in its stage names the session that set it, as `reason` words a session's Your review and In
    /// progress: "‘Cart’ says it's ready", "‘Cart’ is on it". Who set it then says only when, so the session isn't named
    /// twice.
    public static func namesWhoSetIt(_ reading: StageReading) -> Bool {
        reading.why == .set && reading.mark?.by != nil && (reading.stage == .yourReview || reading.stage == .inProgress)
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
            case .approved: "\(count) approved"
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

    /// When Approved comes, for its step of the track that can't be clicked.
    public static let approvedHelp = "Once the reviewers it requires approve, as Azure DevOps counts them"

    /// Why Approved, Can merge and Waits can't be chosen, in the stage's menu.
    public static func whyNotSettable(_ stage: PullRequestStage) -> String? {
        switch stage {
        case .approved: "Azure DevOps decides: once the reviewers it requires approve"
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

    /// "just now", "5m ago".
    public static func agoWords(_ date: Date, now: Date) -> String {
        let short = Elapsed.short(since: date, now: now)
        return short == "now" ? "just now" : short + " ago"
    }
}
