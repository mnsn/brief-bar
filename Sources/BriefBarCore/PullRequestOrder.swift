import Foundation

// The order pull requests that go together merge in: from what their sources show of them, such as a pull request that
// targets another's branch, or a GitHub stack, and from what Copilot sessions told BriefBar (`DeclaredOrders`). It says
// what can merge next and what waits on what, and when a session suggested reviewing one later and why. It never says a
// pull request is ready, and never changes where its source says it stands.

// MARK: - What the sources show

/// Where a pull request stands, as its source shows it now.
public enum PullRequestState: String, Codable, Sendable, CaseIterable {
    case open
    case draft
    case merged
    /// Closed without merging: abandoned in Azure DevOps, closed on GitHub.
    case closed

    public var isOpen: Bool { self == .open || self == .draft }
}

/// A GitHub stack, as one of its pull requests shows it: its pull requests by their place in it, from the bottom, with
/// where each stands, the ones that merged or closed included.
public struct GitHubStack: Equatable, Sendable, Codable {
    public struct Member: Equatable, Sendable, Codable {
        /// Its place in the stack, from 1 at the bottom.
        public var position: Int
        public var ref: ItemRef
        /// Nil when GitHub doesn't say.
        public var state: PullRequestState?

        public init(position: Int, ref: ItemRef, state: PullRequestState? = nil) {
            self.position = position
            self.ref = ref
            self.state = state
        }
    }

    /// `owner/name`, lowercased.
    public var repository: String
    public var number: Int
    /// The branch its bottom pull request merges into, when GitHub says.
    public var baseBranch: String?
    public var members: [Member]

    public init(repository: String, number: Int, baseBranch: String? = nil, members: [Member]) {
        self.repository = repository.lowercased()
        self.number = number
        self.baseBranch = baseBranch
        self.members = members
    }
}

/// A story a pull request is for, through one of its work items, as its source read them: references, the story's type
/// and its task's place in the backlog, never titles.
public struct OrderStory: Hashable, Sendable {
    /// The story: a work item on the backlog, such as a user story, a product backlog item, a requirement, an issue or a
    /// bug.
    public var ref: ItemRef
    /// Its type, such as "User Story", once BriefBar read it.
    public var type: String?
    /// The pull request's work item under it, a task; nil for a pull request linked to the story itself.
    public var task: ItemRef?
    /// That task's place in the backlog, lower first; nil when it isn't known, or for the story itself.
    public var rank: Double?

    public init(ref: ItemRef, type: String? = nil, task: ItemRef? = nil, rank: Double? = nil) {
        self.ref = ref
        self.type = type
        self.task = task
        self.rank = rank
    }
}

/// A pull request a source lists now, with what its order needs to know: never its title.
public struct OrderPullRequest: Equatable, Sendable {
    public var ref: ItemRef
    /// Its repository, as its source names it, lowercased: an Azure DevOps repository by its organization, project ID and
    /// repository ID; a GitHub repository by its owner and name. Two pull requests are in the same repository only when
    /// these are the same.
    public var repository: String
    public var sourceBranch: String
    public var targetBranch: String
    /// Whether its source branch is in another repository, as a fork's is; nil when its source doesn't say.
    public var isFork: Bool?
    /// Its repository's default branch, when its source says.
    public var defaultBranch: String?
    /// Who opened it, by its source's ID for them, when it says: only compared, never shown.
    public var author: String?
    public var state: PullRequestState
    /// What it means for you now, as its source's lists count it: for which group of pull requests shows first.
    public var attention: ItemState?
    public var createdAt: Date?
    /// The GitHub stack it's in.
    public var stack: GitHubStack?
    /// The stories it's for, through its work items, each once: none when none of its work items is a story or a story's
    /// task; nil until its source read them, or for a source that doesn't.
    public var stories: [OrderStory]?

    public init(
        ref: ItemRef, repository: String, sourceBranch: String, targetBranch: String, isFork: Bool? = nil,
        defaultBranch: String? = nil, author: String? = nil, state: PullRequestState = .open, attention: ItemState? = nil,
        createdAt: Date? = nil, stack: GitHubStack? = nil, stories: [OrderStory]? = nil
    ) {
        self.ref = ref
        self.repository = repository.lowercased()
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.isFork = isFork
        self.defaultBranch = defaultBranch
        self.author = author
        self.state = state
        self.attention = attention
        self.createdAt = createdAt
        self.stack = stack
        self.stories = stories
    }
}

/// A Copilot session, as the Copilot app records it: the sessions that started and coordinate it, and the pull requests it
/// opened or works on.
public struct OrderSession: Equatable, Sendable {
    public var ref: ItemRef
    public var parent: ItemRef?
    public var coordinator: ItemRef?
    public var pullRequests: [ItemRef]

    public init(ref: ItemRef, parent: ItemRef? = nil, coordinator: ItemRef? = nil, pullRequests: [ItemRef] = []) {
        self.ref = ref
        self.parent = parent
        self.coordinator = coordinator
        self.pullRequests = pullRequests
    }
}

/// What a source shows of a pull request now, for `OrderEvidence` to keep what merged or closed.
public struct OrderObservation: Equatable, Sendable {
    public var ref: ItemRef
    public var state: PullRequestState
    public var witness: OrderEvidence.Witness

    public init(ref: ItemRef, state: PullRequestState, witness: OrderEvidence.Witness) {
        self.ref = ref
        self.state = state
        self.witness = witness
    }
}

/// What the sources that are on show now, for the order: their pull requests, and Copilot's sessions.
public struct OrderFacts: Equatable, Sendable {
    public private(set) var pullRequests: [ItemRef: OrderPullRequest]
    public private(set) var sessions: [ItemRef: OrderSession]
    /// The kinds of pull request whose source is on: one of another kind can't be seen because its source is off.
    public var sourcesOn: Set<ItemRef.Kind>
    /// Whether a source reads the stories its pull requests are for: Azure DevOps, with Show Links on. Without it, there
    /// are no stories' missions, and their names wait.
    public var readsStories: Bool

    /// - Parameters:
    ///   - pullRequests: the first of each wins.
    ///   - sessions: the first of each wins.
    public init(
        pullRequests: [OrderPullRequest] = [], sessions: [OrderSession] = [],
        sourcesOn: Set<ItemRef.Kind> = [.pullRequest, .gitHubPullRequest], readsStories: Bool = false
    ) {
        var byRef: [ItemRef: OrderPullRequest] = [:]
        for pullRequest in pullRequests where pullRequest.ref.kind.isPullRequest && byRef[pullRequest.ref] == nil {
            byRef[pullRequest.ref] = pullRequest
        }
        var sessionsByRef: [ItemRef: OrderSession] = [:]
        for session in sessions where session.ref.kind == .session && sessionsByRef[session.ref] == nil {
            sessionsByRef[session.ref] = session
        }
        self.pullRequests = byRef
        self.sessions = sessionsByRef
        self.sourcesOn = sourcesOn
        self.readsStories = readsStories
    }

    /// Where each pull request of a GitHub stack stands, as the stack shows it, though no list has it, such as one that
    /// merged.
    var stackStates: [ItemRef: PullRequestState] {
        var states: [ItemRef: PullRequestState] = [:]
        for pullRequest in pullRequests.values.sorted(by: { $0.ref < $1.ref }) {
            for member in pullRequest.stack?.members ?? [] where member.ref.kind.isPullRequest && states[member.ref] == nil {
                if let state = member.state { states[member.ref] = state }
            }
        }
        return states
    }

    /// What the sources show now of each pull request, for the evidence to keep: each one's own state, then the states of
    /// a GitHub stack's pull requests that no list has, as the stack shows them.
    public var observations: [OrderObservation] {
        var observations = pullRequests.values.sorted { $0.ref < $1.ref }.map {
            OrderObservation(ref: $0.ref, state: $0.state, witness: .list)
        }
        for (ref, state) in stackStates.sorted(by: { $0.key < $1.key }) where pullRequests[ref] == nil {
            observations.append(OrderObservation(ref: ref, state: state, witness: .gitHubStack))
        }
        return observations
    }
}

/// What BriefBar knows of a pull request in an order: where its source shows it stands, or what BriefBar saw become of it,
/// or nothing.
public enum OrderStatus: Equatable, Sendable {
    case open
    case draft
    case merged
    case closed
    /// BriefBar can't see it now, and never saw it merge or close: it may have, or not.
    case unknown(Unseen)

    public enum Unseen: Equatable, Sendable {
        /// Its source is on but doesn't list it: it isn't yours or one you review, or it closed a while ago.
        case notListed
        /// Its source is off in BriefBar.
        case sourceOff
    }

    init(_ state: PullRequestState) {
        switch state {
        case .open: self = .open
        case .draft: self = .draft
        case .merged: self = .merged
        case .closed: self = .closed
        }
    }

    public var isOpen: Bool { self == .open || self == .draft }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// Merged or closed.
    public var hasEnded: Bool { self == .merged || self == .closed }
}

extension ItemRef {
    /// How an order names a pull request: !4101 for Azure DevOps, #212 for GitHub; with where it is when that isn't where
    /// `subject` is, "!4101 in fabrikam", "octo/storefront#212".
    public func orderLabel(near subject: ItemRef? = nil) -> String {
        guard let subject, subject.kind != kind || subject.scope != scope else { return shortOrderLabel }
        return fullOrderLabel
    }

    /// !4101, #212.
    public var shortOrderLabel: String {
        switch kind {
        case .pullRequest: return "!\(id)"
        case .gitHubPullRequest: return "#\(id)"
        case .workItem, .session: return id
        }
    }

    /// "!4101 in contoso", "octo/storefront#212".
    public var fullOrderLabel: String {
        switch kind {
        case .pullRequest: return "!\(id) in \(scope)"
        case .gitHubPullRequest: return "\(scope)#\(id)"
        case .workItem, .session: return id
        }
    }
}

// MARK: - What goes before what

/// Why one pull request merges after another.
public enum OrderOrigin: Hashable, Sendable {
    /// A session's order says so, at this revision of it.
    case declared(revision: Int)
    /// It targets the other's branch.
    case branch
    /// They're next to each other in a GitHub stack: its number, and the later one's place in it, of how many.
    case gitHubStack(number: Int, position: Int, size: Int)

    /// Which says the most, for the one a row names first: a session's order, then GitHub's stack, then a branch.
    var rank: Int {
        switch self {
        case .declared: return 0
        case .gitHubStack: return 1
        case .branch: return 2
        }
    }

    static func ordered(_ origins: some Sequence<OrderOrigin>) -> [OrderOrigin] {
        origins.sorted { ($0.rank, $0.sortKey) < ($1.rank, $1.sortKey) }
    }

    private var sortKey: Int {
        switch self {
        case .declared(let revision): return revision
        case .gitHubStack(let number, _, _): return number
        case .branch: return 0
        }
    }
}

/// One pull request that merges before another.
public struct OrderEdge: Hashable, Sendable {
    public var before: ItemRef
    public var after: ItemRef

    public init(_ before: ItemRef, _ after: ItemRef) {
        self.before = before
        self.after = after
    }
}

/// The order BriefBar sees in the pull requests themselves, without a session telling it: a pull request that targets
/// another's branch, in the same repository, merges after it; so does one higher in a GitHub stack.
public enum OrderInference {
    /// More open pull requests than this into one branch make it a branch people share, such as an integration branch,
    /// not one layer of a stack.
    public static let mostTargeting = 3

    /// Every pull request that merges before another, with why.
    public static func edges(_ facts: OrderFacts) -> [OrderEdge: Set<OrderOrigin>] {
        var edges: [OrderEdge: Set<OrderOrigin>] = [:]
        for (edge, origin) in branchEdges(facts) + stackEdges(facts) where edge.before != edge.after {
            edges[edge, default: []].insert(origin)
        }
        return edges
    }

    /// A branch as edges compare it: `users/robin/fix` from `refs/heads/users/robin/fix`, lowercased.
    static func branchKey(_ name: String) -> String {
        BranchHint.name(name).lowercased()
    }

    /// B targets A's source branch, in A's repository. Only when that branch is a stack's: not the repository's default
    /// branch or one everybody works on, not one that more than `mostTargeting` open pull requests merge into, and not one
    /// that another open pull request comes from too. A pull request from a fork stacks nothing, and one that its source
    /// doesn't say is from a fork or not stacks only its own author's.
    static func branchEdges(_ facts: OrderFacts) -> [(OrderEdge, OrderOrigin)] {
        var found: [(OrderEdge, OrderOrigin)] = []
        let byRepository = Dictionary(grouping: facts.pullRequests.values, by: \.repository)
        for repository in byRepository.keys.sorted() {
            let pullRequests = (byRepository[repository] ?? []).sorted { $0.ref < $1.ref }
            let defaults = Set(pullRequests.compactMap { $0.defaultBranch.map(branchKey) })
            var targeting: [String: Int] = [:]
            var openFrom: [String: [ItemRef]] = [:]
            for pullRequest in pullRequests where pullRequest.state.isOpen {
                targeting[branchKey(pullRequest.targetBranch), default: 0] += 1
                openFrom[branchKey(pullRequest.sourceBranch), default: []].append(pullRequest.ref)
            }
            for before in pullRequests where before.isFork != true {
                let branch = branchKey(before.sourceBranch)
                guard !branch.isEmpty, !BranchLinks.shared.contains(branch), !defaults.contains(branch),
                      branch != branchKey(before.targetBranch), targeting[branch, default: 0] <= mostTargeting
                else { continue }
                let from = openFrom[branch] ?? []
                guard from.isEmpty || from == [before.ref] else { continue }
                for after in pullRequests where after.ref != before.ref && branchKey(after.targetBranch) == branch {
                    if before.isFork == nil {
                        guard let author = before.author, author == after.author else { continue }
                    }
                    found.append((OrderEdge(before.ref, after.ref), .branch))
                }
            }
        }
        return found
    }

    /// Each pull request of a GitHub stack merges after the one below it.
    static func stackEdges(_ facts: OrderFacts) -> [(OrderEdge, OrderOrigin)] {
        var stacks: [String: GitHubStack] = [:]
        for pullRequest in facts.pullRequests.values.sorted(by: { $0.ref < $1.ref }) {
            guard let stack = pullRequest.stack else { continue }
            let key = "\(stack.repository)#\(stack.number)"
            if stacks[key] == nil { stacks[key] = stack }
        }
        var found: [(OrderEdge, OrderOrigin)] = []
        for key in stacks.keys.sorted() {
            guard let stack = stacks[key] else { continue }
            var seen: Set<ItemRef> = []
            let members = stack.members.filter { $0.ref.kind.isPullRequest && seen.insert($0.ref).inserted }
                .sorted { $0.position < $1.position }
            for (lower, upper) in zip(members, members.dropFirst()) {
                found.append((
                    OrderEdge(lower.ref, upper.ref),
                    .gitHubStack(number: stack.number, position: upper.position, size: members.count)
                ))
            }
        }
        return found
    }
}

/// What an order's pull requests' edges say about each other.
enum OrderGraph {
    /// The groups of `nodes` that go before each other, so none of them can go first, each in the order of `nodes`.
    /// - Parameter before: what goes before each one.
    static func cycles(_ nodes: [ItemRef], before: [ItemRef: [ItemRef]]) -> [[ItemRef]] {
        let members = Set(nodes)
        func reach(from start: ItemRef) -> Set<ItemRef> {
            var reached: Set<ItemRef> = []
            var pending = before[start, default: []].filter { members.contains($0) && $0 != start }
            while let ref = pending.popLast() {
                guard reached.insert(ref).inserted else { continue }
                pending += before[ref, default: []].filter { members.contains($0) && $0 != ref }
            }
            return reached
        }
        let reaches = Dictionary(nodes.map { ($0, reach(from: $0)) }, uniquingKeysWith: { first, _ in first })
        var grouped: Set<ItemRef> = []
        var cycles: [[ItemRef]] = []
        for ref in nodes where !grouped.contains(ref) && reaches[ref]?.contains(ref) == true {
            let cycle = nodes.filter { other in reaches[ref]?.contains(other) == true && reaches[other]?.contains(ref) == true }
            grouped.formUnion(cycle)
            cycles.append(cycle)
        }
        return cycles
    }

    /// `nodes` in an order where each comes after what goes before it, choosing, of those that can go next, the one
    /// `isEarlier` puts first; then those that go before each other, and what comes after them, as `isEarlier` puts them.
    static func ordered(
        _ nodes: [ItemRef], before: [ItemRef: [ItemRef]], isEarlier: (ItemRef, ItemRef) -> Bool
    ) -> (order: [ItemRef], cycles: [[ItemRef]]) {
        let members = Set(nodes)
        var waitingFor: [ItemRef: Int] = [:]
        var afterIt: [ItemRef: [ItemRef]] = [:]
        for ref in nodes {
            let earlier = Set(before[ref, default: []].filter { members.contains($0) && $0 != ref })
            waitingFor[ref] = earlier.count
            for other in earlier { afterIt[other, default: []].append(ref) }
        }
        var ready = nodes.filter { waitingFor[$0] == 0 }
        var order: [ItemRef] = []
        var placed: Set<ItemRef> = []
        while !ready.isEmpty {
            ready.sort(by: isEarlier)
            let ref = ready.removeFirst()
            order.append(ref)
            placed.insert(ref)
            for later in afterIt[ref, default: []] {
                waitingFor[later, default: 0] -= 1
                if waitingFor[later] == 0 { ready.append(later) }
            }
        }
        let left = nodes.filter { !placed.contains($0) }.sorted(by: isEarlier)
        return (order + left, cycles(left, before: before))
    }
}

// MARK: - Missions

/// Which group of pull requests a mission is, so that Focus finds it again: a session's order, by the ID BriefBar gave it;
/// a GitHub stack; a chain of branches, by its earliest pull request; the pull requests opened under a session; or a
/// story's pull requests, by the story's work item.
public enum MissionKey: Hashable, Sendable, CustomStringConvertible {
    case plan(UUID)
    /// `owner/name`, lowercased, and the stack's number.
    case stack(repository: String, number: Int)
    case chain(ItemRef)
    case family(ItemRef)
    /// A story's work item.
    case story(ItemRef)

    /// `plan/<id>`, `stack/octo/storefront/41`, `chain/pullRequest/contoso/4101`, `family/session//<id>`,
    /// `story/workItem/contoso/5101`: what the preferences keep.
    public var description: String {
        switch self {
        case .plan(let id): return "plan/\(id.uuidString.lowercased())"
        case .stack(let repository, let number): return "stack/\(repository)/\(number)"
        case .chain(let ref): return "chain/\(ref.description)"
        case .family(let ref): return "family/\(ref.description)"
        case .story(let ref): return "story/\(ref.description)"
        }
    }

    /// The key a description names, checked as when it was made: nil for anything else.
    public init?(_ description: String) {
        guard let slash = description.firstIndex(of: "/") else { return nil }
        let rest = String(description[description.index(after: slash)...])
        switch description[..<slash] {
        case "plan":
            guard let id = UUID(uuidString: rest) else { return nil }
            self = .plan(id)
        case "stack":
            guard let last = rest.lastIndex(of: "/") else { return nil }
            let repository = String(rest[..<last])
            guard ItemRef.isRepository(repository), repository == repository.lowercased(),
                  let number = ItemRef.number(String(rest[rest.index(after: last)...]))
            else { return nil }
            self = .stack(repository: repository, number: number)
        case "chain":
            guard let ref = ItemRef(rest), ref.kind.isPullRequest else { return nil }
            self = .chain(ref)
        case "family":
            guard let ref = ItemRef(rest), ref.kind == .session else { return nil }
            self = .family(ref)
        case "story":
            guard let ref = ItemRef(rest), ref.kind == .workItem else { return nil }
            self = .story(ref)
        default:
            return nil
        }
    }

    /// The kinds of thing whose source makes the mission it names, but for a session's order, which BriefBar keeps: a
    /// GitHub stack's pull requests, a chain's, the sessions a family's pull requests were opened under, and a story's
    /// work items.
    public var kinds: Set<ItemRef.Kind> {
        switch self {
        case .plan: return []
        case .stack: return [.gitHubPullRequest]
        case .chain(let ref), .family(let ref), .story(let ref): return [ref.kind]
        }
    }
}

/// A pull request that goes before one in its order, with why, and what BriefBar knows of it.
public struct OrderPrerequisite: Equatable, Sendable {
    public var ref: ItemRef
    /// Why, what says the most first.
    public var origins: [OrderOrigin]
    public var status: OrderStatus

    public init(ref: ItemRef, origins: [OrderOrigin], status: OrderStatus) {
        self.ref = ref
        self.origins = origins
        self.status = status
    }
}

/// Where a pull request stands in its order: about merging only, beside where its source says it stands, which it never
/// changes or repeats.
public enum OrderStanding: Equatable, Sendable {
    case merged
    case closed
    /// BriefBar can't see it now.
    case notVisible(OrderStatus.Unseen)
    /// Everything before it merged, or nothing goes before it, and something goes after it.
    case next
    /// Its order puts nothing before or after it.
    case anyTime
    /// Some of what goes before it is still open; BriefBar can't see whether the unknown ones merged.
    case waiting(open: [ItemRef], unknown: [ItemRef])
    /// What goes before it and hasn't merged is all what BriefBar can't see.
    case unresolved([ItemRef])
    /// One that goes before it was closed without merging.
    case prerequisiteClosed(ItemRef)
    /// One that goes before it merged, and it still targets that one's branch: to the branch that one merged into, when
    /// BriefBar knows it.
    case retarget(after: ItemRef, to: String?)
    /// It and these go before each other, so none of them can go first.
    case inCycle(with: [ItemRef])
    /// Not in the order: stacked on, or under, its pull requests.
    case notInOrder
    /// In a group whose order nobody told BriefBar.
    case unordered

    /// The mark beside its row, for where it stands.
    public var marker: OrderMarker {
        switch self {
        case .merged: return .merged
        case .closed: return .closed
        case .notVisible: return .unseen
        case .next: return .next
        case .anyTime: return .anyTime
        case .waiting, .unresolved: return .waiting
        case .prerequisiteClosed, .retarget, .inCycle: return .check
        case .notInOrder, .unordered: return .none
        }
    }

    /// Its order needs checking: one before it closed without merging, it still targets the branch of one that merged, or
    /// it and others go before each other.
    public var needsChecking: Bool {
        marker == .check
    }

    /// It waits for others to merge first, or for BriefBar to see whether they did: completing it now would be out of
    /// order, whatever its source says of it.
    public var waitsForOthers: Bool {
        switch self {
        case .waiting, .unresolved: return true
        default: return false
        }
    }
}

/// The mark beside a pull request's row in a mission, in a narrow column on its left.
public enum OrderMarker: Equatable, Sendable {
    /// Filled: next to merge.
    case next
    /// Outlined: it waits for others to merge, or for BriefBar to see whether they did.
    case waiting
    /// Dotted: any time.
    case anyTime
    /// ✓: merged. Merged ones fold into one line.
    case merged
    /// Closed without merging. It folds with the merged ones.
    case closed
    /// An orange !: check the order.
    case check
    /// BriefBar can't see it.
    case unseen
    /// None: not in the order, or in a group with no order.
    case none
}

/// What more a step says, as facts, never as a promise.
public enum OrderNote: Equatable, Sendable {
    /// Its changes show against this one's branch, which may still change.
    case showsAgainst(ItemRef)
    /// BriefBar sees this one go before it, which its order doesn't say: the order decides.
    case orderDisagrees(ItemRef, OrderOrigin)
    /// It's in these other orders too.
    case alsoIn([UUID])
    /// Stacked with one of the order's pull requests: it comes after that one, or before it.
    case stackedWith(ItemRef, comesAfter: Bool, OrderOrigin)
    /// Its work items are for this story too, whose mission it isn't in.
    case alsoFor(MissionStory)
}

/// A pull request in a mission.
public struct OrderStep: Equatable, Sendable {
    public var ref: ItemRef
    /// Its place in the order, from 1; nil for one that merges any time, or in a group with no order.
    public var number: Int?
    public var status: OrderStatus
    public var standing: OrderStanding
    /// What goes before it.
    public var prerequisites: [OrderPrerequisite]
    /// What it comes right after: what goes before it, without what goes before those, merged or not. These are the lines
    /// into its node in List's gutter, and its arrows in the Map.
    public var directPrerequisites: [ItemRef]
    /// When its session suggested reviewing it: advice, never a promise; nil when no session said.
    public var review: ReviewTiming?
    public var notes: [OrderNote]
    /// The session that opened it, or works on it, the first BriefBar knows of: its lane in the Map. Nil when none is known.
    public var session: ItemRef?

    public init(
        ref: ItemRef, number: Int? = nil, status: OrderStatus, standing: OrderStanding, prerequisites: [OrderPrerequisite] = [],
        directPrerequisites: [ItemRef] = [], review: ReviewTiming? = nil, notes: [OrderNote] = [], session: ItemRef? = nil
    ) {
        self.ref = ref
        self.number = number
        self.status = status
        self.standing = standing
        self.prerequisites = prerequisites
        self.directPrerequisites = directPrerequisites
        self.review = review
        self.notes = notes
        self.session = session
    }

    /// Whether it comes right after that one, with nothing between them.
    public func comesRightAfter(_ other: ItemRef) -> Bool {
        directPrerequisites.contains(other)
    }

    /// Whether it's stacked on that one: it targets that one's branch, or comes right after it in a GitHub stack.
    public func isStacked(on other: ItemRef) -> Bool {
        prerequisites.first { $0.ref == other }?.origins.contains { origin in
            if case .declared = origin { return false }
            return true
        } ?? false
    }
}

/// The story a mission is for: a story's mission's own, or the one all of another mission's pull requests are for. Its
/// work item, and its type once BriefBar read it: never its title.
public struct MissionStory: Hashable, Sendable {
    public var ref: ItemRef
    /// Such as "User Story"; nil until it's read, or when it can't be.
    public var type: String?

    public init(ref: ItemRef, type: String? = nil) {
        self.ref = ref
        self.type = type
    }
}

/// Pull requests that go together, in their order: a session's order, a stack BriefBar sees, the pull requests opened
/// under a session, or a story's pull requests, whose order nobody told BriefBar.
public struct OrderMission: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A session's order: who said it was theirs, for information only, and when it last changed.
        case declared(id: UUID, revision: Int, declaredBy: ItemRef?, updatedAt: Date)
        /// A stack BriefBar sees: a GitHub stack, or pull requests that target each other's branches.
        case stack
        /// Pull requests opened under this session, whose order nobody told BriefBar.
        case family(session: ItemRef)
        /// The pull requests of a story's tasks, or of the story itself, in its tasks' backlog order: BriefBar can't see
        /// which merges first, but for those stacked on each other.
        case story(ItemRef)
    }

    public var key: MissionKey
    public var kind: Kind
    /// In their order: those with a place first, then those that merge any time.
    public var steps: [OrderStep]
    /// Pull requests its order doesn't name that are stacked with its own.
    public var attached: [OrderStep]
    /// Its pull requests that go before each other, so none of them can go first.
    public var cycles: [[ItemRef]]
    public var isFocused: Bool
    /// Every pull request in it merged or closed.
    public var isFinished: Bool
    /// A session's order that hasn't finished and that hasn't changed for `DeclaredOrders.staleAfter`: it stays until you
    /// forget it.
    public var isStale: Bool
    /// What the pull requests in it that are still open mean for you, the most pressing.
    public var attention: ItemState?
    /// When it last changed: a session's order when it last told BriefBar, else when its newest pull request was opened.
    public var date: Date?
    /// The sessions it goes with, for its header's menu: the one that told its order, or that its pull requests were
    /// opened under, first; then those that opened them or work on them, each once.
    public var sessions: [ItemRef]
    /// The story it's for: a story's mission's own; for another mission, the one story all its pull requests are for, when
    /// they are.
    public var story: MissionStory? = nil
    /// A session's order's: the pull requests for its story it doesn't name, nor stacks with its own, apart, in the story's
    /// task order, with no order known.
    public var sameStory: [OrderStep] = []

    public var id: MissionKey { key }

    /// How many of its pull requests merged, of `pullRequestCount`: "1 of 5 merged".
    public var mergedCount: Int {
        steps.filter { $0.status == .merged }.count
    }

    /// Its pull requests, those it doesn't name but are stacked with its own, or for its story, aside.
    public var pullRequestCount: Int {
        steps.count
    }

    /// Whether a pull request is in it, stacked with its own, or for its story apart from it.
    public func contains(_ ref: ItemRef) -> Bool {
        steps.contains { $0.ref == ref } || attached.contains { $0.ref == ref } || sameStory.contains { $0.ref == ref }
    }

    /// Whether it's a group with no known order.
    public var isFamily: Bool {
        if case .family = kind { return true }
        return false
    }

    /// Whether it's a story's pull requests.
    public var isStory: Bool {
        if case .story = kind { return true }
        return false
    }

    /// Whether it claims an order: a session's or a stack's. A story's and a session's pull requests' don't, but for those
    /// stacked on each other among a story's, and have no progress bar.
    public var hasOrder: Bool {
        !isFamily && !isStory
    }
}

// MARK: - The board

/// The missions to show, from what the sources show now, the orders sessions told BriefBar, and what BriefBar saw become
/// of their pull requests.
public enum OrderBoard {
    /// Each session's order is a mission of its own, however many a session told, even when they share pull requests.
    /// The pull requests no order names group by what BriefBar sees: those stacked with only one order's pull requests
    /// show with it, apart from what it names; then, with what they're stacked with, by the story their work items are
    /// for: apart in the one order whose own pull requests are for that story too, or else as that story's mission, two
    /// or more; others stacked together are a stack of their own; the rest group by the session they were opened under,
    /// two or more, with no order. A pull request alone isn't shown, nor a story's.
    /// - Parameter focus: the mission you keep on top.
    public static func missions(
        facts: OrderFacts, orders: DeclaredOrders, evidence: OrderEvidence, focus: MissionKey? = nil, now: Date = Date()
    ) -> [OrderMission] {
        let board = Board(facts: facts, evidence: evidence)
        var plansByRef: [ItemRef: [UUID]] = [:]
        for plan in orders.plans {
            for ref in plan.refs { plansByRef[ref, default: []].append(plan.id) }
        }
        var attached: [UUID: [ItemRef]] = [:]
        var stacks: [[ItemRef]] = []
        var alone: [ItemRef] = []
        var byStory: [ItemRef: [[ItemRef]]] = [:]
        for component in board.components(of: board.known.subtracting(plansByRef.keys)) {
            var touched: Set<UUID> = []
            for ref in component {
                for neighbor in board.neighbors(of: ref) { touched.formUnion(plansByRef[neighbor] ?? []) }
            }
            if touched.count == 1, let plan = touched.first {
                attached[plan, default: []] += component
            } else if let story = board.story(of: component) {
                byStory[story, default: []].append(component)
            } else if component.count > 1 {
                stacks.append(component)
            } else {
                alone += component
            }
        }
        var plansByStory: [ItemRef: Set<UUID>] = [:]
        for plan in orders.plans {
            for ref in plan.refs {
                for story in board.stories(of: ref) { plansByStory[story.ref, default: []].insert(plan.id) }
            }
        }
        var sameStory: [UUID: [(story: ItemRef, component: [ItemRef])]] = [:]
        var stories: [(story: ItemRef, components: [[ItemRef]])] = []
        for story in byStory.keys.sorted() {
            let components = byStory[story] ?? []
            if let plans = plansByStory[story], plans.count == 1, let plan = plans.first {
                sameStory[plan, default: []] += components.map { (story, $0) }
            } else if components.joined().count > 1 {
                stories.append((story, components))
            } else {
                // A story with one pull request is no mission: it goes as it would without its story.
                alone += components.joined()
            }
        }
        var missions = orders.plans.map {
            board.mission(for: $0, orders: orders, attached: attached[$0.id] ?? [], sameStory: sameStory[$0.id] ?? [], now: now)
        }
        missions += stories.map { board.storyMission($0.story, components: $0.components) }
        missions += stacks.map(board.stackMission)
        missions += board.familyMissions(alone)
        for index in missions.indices {
            missions[index].isFocused = missions[index].key == focus
        }
        return missions.sorted(by: showsFirst)
    }

    /// The one you focus on first, then those still going, then those with an order; the most pressing for you first, then
    /// the latest.
    static func showsFirst(_ lhs: OrderMission, _ rhs: OrderMission) -> Bool {
        if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
        if lhs.isFinished != rhs.isFinished { return !lhs.isFinished }
        if lhs.hasOrder != rhs.hasOrder { return lhs.hasOrder }
        let urgency = { (mission: OrderMission) in
            mission.attention.flatMap { ItemState.allCases.firstIndex(of: $0) } ?? ItemState.allCases.count
        }
        if urgency(lhs) != urgency(rhs) { return urgency(lhs) < urgency(rhs) }
        if lhs.date != rhs.date { return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast) }
        return lhs.key.description < rhs.key.description
    }

    /// Where something kept by a mission's key goes once that mission is gone, as the missions change: the mission all its
    /// pull requests that are still open went to, when that's their story's, or, for a chain whose earliest pull request
    /// left, the chain or story they're in now. Nil while it's still there, or when its open pull requests went different
    /// ways, or none is open: what's kept waits, as it would. A session's order never moves: it's kept by its ID.
    /// - Parameters:
    ///   - old: the missions as they were.
    ///   - new: the missions now.
    public static func successor(of key: MissionKey, from old: [OrderMission], to new: [OrderMission]) -> MissionKey? {
        if case .plan = key { return nil }
        guard !new.contains(where: { $0.key == key }), let was = old.first(where: { $0.key == key }) else { return nil }
        let open = (was.steps + was.attached + was.sameStory).filter(\.status.isOpen).map(\.ref)
        guard let first = open.first,
              let now = new.first(where: { mission in mission.steps.contains { $0.ref == first } }),
              open.allSatisfy({ ref in now.steps.contains { $0.ref == ref } })
        else { return nil }
        switch (key, now.key) {
        case (_, .story): return now.key
        case (.chain, .chain): return now.key
        default: return nil
        }
    }
}

/// What the missions are made of: the sources' pull requests, what BriefBar saw become of them, and the order it sees.
private struct Board {
    struct StackPlace: Equatable {
        var stack: String
        var position: Int
    }

    let facts: OrderFacts
    let evidence: OrderEvidence
    let inferred: [OrderEdge: Set<OrderOrigin>]
    let stackStates: [ItemRef: PullRequestState]
    let stackPlaces: [ItemRef: StackPlace]
    /// What BriefBar sees go before each pull request, and after it.
    let before: [ItemRef: Set<ItemRef>]
    let after: [ItemRef: Set<ItemRef>]
    /// The sessions that opened each pull request, or work on it, in reference order.
    let openers: [ItemRef: [ItemRef]]

    init(facts: OrderFacts, evidence: OrderEvidence) {
        self.facts = facts
        self.evidence = evidence
        inferred = OrderInference.edges(facts)
        stackStates = facts.stackStates
        var places: [ItemRef: StackPlace] = [:]
        for pullRequest in facts.pullRequests.values.sorted(by: { $0.ref < $1.ref }) {
            guard let stack = pullRequest.stack else { continue }
            for member in stack.members where places[member.ref] == nil {
                places[member.ref] = StackPlace(stack: "\(stack.repository)#\(stack.number)", position: member.position)
            }
        }
        stackPlaces = places
        var openers: [ItemRef: [ItemRef]] = [:]
        for session in facts.sessions.values.sorted(by: { $0.ref < $1.ref }) {
            for ref in session.pullRequests where openers[ref]?.contains(session.ref) != true {
                openers[ref, default: []].append(session.ref)
            }
        }
        self.openers = openers
        var before: [ItemRef: Set<ItemRef>] = [:]
        var after: [ItemRef: Set<ItemRef>] = [:]
        for edge in inferred.keys {
            before[edge.after, default: []].insert(edge.before)
            after[edge.before, default: []].insert(edge.after)
        }
        self.before = before
        self.after = after
    }

    /// Every pull request the sources show, those only a GitHub stack shows included.
    var known: Set<ItemRef> {
        Set(facts.pullRequests.keys).union(stackStates.keys)
    }

    func neighbors(of ref: ItemRef) -> Set<ItemRef> {
        before[ref, default: []].union(after[ref, default: []])
    }

    /// What BriefBar knows of a pull request: where its source, or its GitHub stack, shows it stands now; else what
    /// BriefBar saw become of it; else nothing. One that's gone from a list hasn't merged or closed for all that.
    func status(_ ref: ItemRef) -> OrderStatus {
        if let pullRequest = facts.pullRequests[ref] { return OrderStatus(pullRequest.state) }
        if let state = stackStates[ref] { return OrderStatus(state) }
        if let record = evidence.records[ref] { return record.outcome == .merged ? .merged : .closed }
        return .unknown(facts.sourcesOn.contains(ref.kind) ? .notListed : .sourceOff)
    }

    /// Why BriefBar sees one go before the other, what says the most first.
    func origins(_ earlier: ItemRef, _ later: ItemRef) -> [OrderOrigin] {
        OrderOrigin.ordered(inferred[OrderEdge(earlier, later)] ?? [])
    }

    /// The groups of these that BriefBar sees stacked together, each in reference order, the groups by their first.
    func components(of refs: Set<ItemRef>) -> [[ItemRef]] {
        var seen: Set<ItemRef> = []
        var components: [[ItemRef]] = []
        for start in refs.sorted() where seen.insert(start).inserted {
            var component: [ItemRef] = []
            var pending = [start]
            while let ref = pending.popLast() {
                component.append(ref)
                for neighbor in neighbors(of: ref).sorted() where refs.contains(neighbor) && seen.insert(neighbor).inserted {
                    pending.append(neighbor)
                }
            }
            components.append(component.sorted())
        }
        return components
    }

    /// Lower in the same GitHub stack first, else the one opened first, else by reference.
    func isEarlier(_ lhs: ItemRef, _ rhs: ItemRef) -> Bool {
        if let left = stackPlaces[lhs], let right = stackPlaces[rhs], left.stack == right.stack, left.position != right.position {
            return left.position < right.position
        }
        switch (facts.pullRequests[lhs]?.createdAt, facts.pullRequests[rhs]?.createdAt) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs < rhs
        }
    }

    /// Where a pull request stands in its order, from what goes before it there: only a merge BriefBar saw counts, and of
    /// what it waits for, only the nearest is named, "after !4103" rather than "after !4102 and !4103" when !4103 comes
    /// after !4102.
    /// - Parameters:
    ///   - declared: in a session's order, where one with nothing before or after it merges any time.
    ///   - earlier: everything that goes before each pull request in the order, directly or through others.
    func standing(
        of ref: ItemRef, prerequisites: [ItemRef], hasDependents: Bool, declared: Bool, cycle: [ItemRef]?,
        earlier: [ItemRef: Set<ItemRef>]
    ) -> OrderStanding {
        switch status(ref) {
        case .merged: return .merged
        case .closed: return .closed
        case .unknown(let unseen): return .notVisible(unseen)
        case .open, .draft: break
        }
        if let cycle { return .inCycle(with: cycle.filter { $0 != ref }) }
        if let closed = prerequisites.first(where: { status($0) == .closed }) { return .prerequisiteClosed(closed) }
        if let merged = prerequisites.first(where: { status($0) == .merged && stillTargets(ref, branchOf: $0) }) {
            return .retarget(after: merged, to: mergedInto(merged, below: ref))
        }
        let unmerged = Self.nearest(prerequisites.filter { status($0).isOpen || status($0).isUnknown }, earlier: earlier)
        let open = unmerged.filter { status($0).isOpen }
        let unknown = unmerged.filter { status($0).isUnknown }
        if !open.isEmpty { return .waiting(open: open, unknown: unknown) }
        if !unknown.isEmpty { return .unresolved(unknown) }
        return declared && prerequisites.isEmpty && !hasDependents ? .anyTime : .next
    }

    /// Whether it still targets the branch of one that merged, in that one's repository.
    func stillTargets(_ ref: ItemRef, branchOf merged: ItemRef) -> Bool {
        guard let pullRequest = facts.pullRequests[ref], let below = facts.pullRequests[merged],
              pullRequest.repository == below.repository
        else { return false }
        let branch = OrderInference.branchKey(below.sourceBranch)
        return !branch.isEmpty && OrderInference.branchKey(pullRequest.targetBranch) == branch
    }

    /// The branch one that merged went into, to retarget the one above it to: as its source shows it, or else its GitHub
    /// stack's base. Never a guess, such as main.
    func mergedInto(_ merged: ItemRef, below ref: ItemRef) -> String? {
        if let target = facts.pullRequests[merged].map({ BranchHint.name($0.targetBranch) }), !target.isEmpty { return target }
        let base = (facts.pullRequests[merged]?.stack ?? facts.pullRequests[ref]?.stack)?.baseBranch.map(BranchHint.name)
        return base?.isEmpty == false ? base : nil
    }

    /// That its changes show against the branch of an open pull request BriefBar sees it target.
    func showsAgainst(_ ref: ItemRef) -> [OrderNote] {
        before[ref, default: []].sorted()
            .filter { inferred[OrderEdge($0, ref)]?.contains(.branch) == true && status($0).isOpen }
            .map(OrderNote.showsAgainst)
    }

    /// When a session suggested reviewing a pull request, without what it said to wait for that has merged or closed since.
    func review(_ timing: ReviewTiming?) -> ReviewTiming? {
        guard case .after(let refs, let reason) = timing else { return timing }
        let left = refs.filter { !status($0).hasEnded }
        return left.isEmpty ? nil : .after(left, reason)
    }

    /// What the open pull requests among these mean for you, the most pressing.
    func attention(_ refs: [ItemRef]) -> ItemState? {
        let states = refs.filter { status($0).isOpen }.compactMap { facts.pullRequests[$0]?.attention }
        return ItemState.allCases.first { states.contains($0) }
    }

    func newest(_ refs: [ItemRef]) -> Date? {
        refs.compactMap { facts.pullRequests[$0]?.createdAt }.max()
    }

    func cycleMembers(_ cycles: [[ItemRef]]) -> [ItemRef: [ItemRef]] {
        var members: [ItemRef: [ItemRef]] = [:]
        for cycle in cycles {
            for ref in cycle { members[ref] = cycle }
        }
        return members
    }

    /// Everything that goes before each pull request in an order, directly or through others.
    /// - Parameter prerequisites: what goes right before each.
    static func ancestry(_ prerequisites: [ItemRef: [ItemRef]]) -> [ItemRef: Set<ItemRef>] {
        var all: [ItemRef: Set<ItemRef>] = [:]
        for start in prerequisites.keys {
            var reached: Set<ItemRef> = []
            var pending = prerequisites[start, default: []]
            while let ref = pending.popLast() {
                guard reached.insert(ref).inserted else { continue }
                pending += prerequisites[ref, default: []]
            }
            all[start] = reached
        }
        return all
    }

    /// Of these, in their order, the ones none of the others comes after: the nearest.
    static func nearest(_ refs: [ItemRef], earlier: [ItemRef: Set<ItemRef>]) -> [ItemRef] {
        refs.filter { ref in !refs.contains { other in other != ref && earlier[other]?.contains(ref) == true } }
    }

    /// The sessions a mission goes with: `first`, then those that opened its pull requests or work on them, each once.
    func sessions(of refs: [ItemRef], first: ItemRef?) -> [ItemRef] {
        var sessions = first.map { [$0] } ?? []
        for ref in refs {
            for session in openers[ref] ?? [] where !sessions.contains(session) { sessions.append(session) }
        }
        return sessions
    }
}

// MARK: Stories

extension Board {
    /// The stories a pull request is for, as its source read them, each once, with its first task in the backlog.
    func stories(of ref: ItemRef) -> [OrderStory] {
        var stories: [OrderStory] = []
        for story in facts.pullRequests[ref]?.stories ?? [] where story.ref.kind == .workItem {
            if let index = stories.firstIndex(where: { $0.ref == story.ref }) {
                if Self.earlier(story.rank, stories[index].rank) == true { stories[index].rank = story.rank }
                if stories[index].type == nil { stories[index].type = story.type }
            } else {
                stories.append(story)
            }
        }
        return stories
    }

    /// A story, with its type when any pull request's source read it.
    func missionStory(_ story: ItemRef) -> MissionStory {
        let type = facts.pullRequests.values.sorted { $0.ref < $1.ref }.lazy
            .compactMap { $0.stories?.first { $0.ref == story && $0.type != nil }?.type }.first
        return MissionStory(ref: story, type: type)
    }

    /// The story pull requests stacked together go with: the one most of them are for, then the one whose task comes
    /// first in the backlog, then the one with the lowest ID. Nil when none of them is for a story.
    func story(of component: [ItemRef]) -> ItemRef? {
        var counts: [ItemRef: Int] = [:]
        var ranks: [ItemRef: Double] = [:]
        for ref in component {
            for story in stories(of: ref) {
                counts[story.ref, default: 0] += 1
                if let rank = story.rank { ranks[story.ref] = min(ranks[story.ref] ?? rank, rank) }
            }
        }
        return counts.keys.min { lhs, rhs in
            if counts[lhs] != counts[rhs] { return counts[lhs, default: 0] > counts[rhs, default: 0] }
            return Self.earlier(ranks[lhs], ranks[rhs]) ?? (lhs < rhs)
        }
    }

    /// The one story all these pull requests are for, of those the sources show: for a mission that isn't a story's. Nil
    /// when the sources show none of them, or they aren't all for one story.
    func commonStory(of refs: [ItemRef]) -> MissionStory? {
        let shown = refs.filter { facts.pullRequests[$0] != nil }
        guard let first = shown.first else { return nil }
        var common = Set(stories(of: first).map(\.ref))
        for ref in shown.dropFirst() { common.formIntersection(stories(of: ref).map(\.ref)) }
        guard common.count == 1, let story = common.first else { return nil }
        return missionStory(story)
    }

    /// Whether one of a story's pull requests comes before another in its tasks' order: by its task's place in the
    /// backlog, then when it was opened, then by reference, what isn't known last. A total order, for rows whose order
    /// isn't known only: `isEarlier` stays as it is.
    func comesFirst(in story: ItemRef) -> (ItemRef, ItemRef) -> Bool {
        { lhs, rhs in
            let rank = { (ref: ItemRef) in self.stories(of: ref).first { $0.ref == story }?.rank }
            if let earlier = Self.earlier(rank(lhs), rank(rhs)) { return earlier }
            if let earlier = Self.earlier(self.facts.pullRequests[lhs]?.createdAt, self.facts.pullRequests[rhs]?.createdAt) {
                return earlier
            }
            return lhs < rhs
        }
    }

    /// Whether `lhs` comes before `rhs`, what's missing last: nil when they're the same.
    static func earlier<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return nil
        }
    }

    /// That a pull request's work items are for other stories than the one whose mission, or part of one, it's in.
    func alsoFor(_ ref: ItemRef, besides story: ItemRef) -> [OrderNote] {
        stories(of: ref).filter { $0.ref != story }.sorted { $0.ref < $1.ref }
            .map { .alsoFor(MissionStory(ref: $0.ref, type: $0.type ?? missionStory($0.ref).type)) }
    }
}

// MARK: Building missions

extension Board {
    /// A session's order: its pull requests in the order it gave, those it puts nothing before or after last, numberless;
    /// with the pull requests it doesn't name that are stacked with its own, apart; and those for one of its own's story,
    /// apart too, in that story's task order.
    /// - Parameter sameStory: the story each group of them is for, and the group, stacked together or alone.
    func mission(
        for plan: OrderPlan, orders: DeclaredOrders, attached: [ItemRef], sameStory: [(story: ItemRef, component: [ItemRef])] = [],
        now: Date
    ) -> OrderMission {
        let refs = plan.refs
        let place = Dictionary(refs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var prerequisites: [ItemRef: [ItemRef]] = [:]
        var dependents: Set<ItemRef> = []
        for entry in plan.entries {
            prerequisites[entry.ref] = entry.after
            dependents.formUnion(entry.after)
        }
        let (order, cycles) = OrderGraph.ordered(refs, before: prerequisites) { place[$0, default: 0] < place[$1, default: 0] }
        let inCycle = cycleMembers(cycles)
        let anyTime = Set(refs.filter { prerequisites[$0, default: []].isEmpty && !dependents.contains($0) })
        let earlier = Self.ancestry(prerequisites)
        var steps: [OrderStep] = []
        for ref in order where !anyTime.contains(ref) {
            guard let entry = plan.entry(for: ref) else { continue }
            steps.append(step(
                entry, of: plan, orders: orders, number: steps.count + 1, hasDependents: dependents.contains(ref), cycle: inCycle[ref],
                earlier: earlier
            ))
        }
        for entry in plan.entries where anyTime.contains(entry.ref) {
            steps.append(step(entry, of: plan, orders: orders, number: nil, hasDependents: false, cycle: nil, earlier: earlier))
        }
        let group = Set(refs).union(attached)
        let sameStorySteps = self.sameStorySteps(sameStory)
        let isFinished = !steps.isEmpty && steps.allSatisfy { $0.status.hasEnded }
        return OrderMission(
            key: .plan(plan.id),
            kind: .declared(id: plan.id, revision: plan.revision, declaredBy: plan.declaredBy, updatedAt: plan.updatedAt),
            steps: steps, attached: attached.sorted(by: isEarlier).map { attachedStep($0, among: group) }, cycles: cycles,
            isFocused: false, isFinished: isFinished,
            isStale: !isFinished && now.timeIntervalSince(plan.updatedAt) > DeclaredOrders.staleAfter,
            attention: attention(refs), date: plan.updatedAt,
            sessions: sessions(of: steps.map(\.ref) + attached + sameStorySteps.map(\.ref), first: plan.declaredBy),
            story: commonStory(of: refs), sameStory: sameStorySteps
        )
    }

    /// The pull requests for an order's story it doesn't name, apart: each group in the order of its story's tasks, by its
    /// first there; one alone with no order known, those stacked together in their order, each saying how.
    func sameStorySteps(_ groups: [(story: ItemRef, component: [ItemRef])]) -> [OrderStep] {
        let sorted = groups.map { group in
            (story: group.story, component: group.component, first: group.component.min(by: comesFirst(in: group.story)) ?? group.component[0])
        }.sorted { lhs, rhs in
            lhs.story != rhs.story ? lhs.story < rhs.story : comesFirst(in: lhs.story)(lhs.first, rhs.first)
        }
        return sorted.flatMap { group -> [OrderStep] in
            let story = group.story
            guard group.component.count > 1 else {
                let ref = group.first
                return [OrderStep(
                    ref: ref, status: status(ref), standing: .unordered, notes: alsoFor(ref, besides: story), session: openers[ref]?.first
                )]
            }
            let members = Set(group.component)
            return stackOrder(group.component).order.map { ref in
                var step = attachedStep(ref, among: members)
                step.notes += alsoFor(ref, besides: story)
                return step
            }
        }
    }

    /// One of a session's order's pull requests: what the order puts before it, with what BriefBar sees too; and where
    /// BriefBar sees one of the order's own go before it when the order doesn't say so, which the order decides.
    func step(
        _ entry: OrderPlan.Entry, of plan: OrderPlan, orders: DeclaredOrders, number: Int?, hasDependents: Bool, cycle: [ItemRef]?,
        earlier: [ItemRef: Set<ItemRef>]
    ) -> OrderStep {
        let ref = entry.ref
        let prerequisites = entry.after.map { earlier in
            OrderPrerequisite(ref: earlier, origins: [.declared(revision: plan.revision)] + origins(earlier, ref), status: status(earlier))
        }
        var notes = showsAgainst(ref)
        for earlier in before[ref, default: []].sorted() where plan.contains(earlier) && !plan.puts(earlier, before: ref) {
            if let origin = origins(earlier, ref).first { notes.append(.orderDisagrees(earlier, origin)) }
        }
        let others = orders.plans.filter { $0.id != plan.id && $0.contains(ref) }.map(\.id)
        if !others.isEmpty { notes.append(.alsoIn(others)) }
        return OrderStep(
            ref: ref, number: number, status: status(ref),
            standing: standing(
                of: ref, prerequisites: entry.after, hasDependents: hasDependents, declared: true, cycle: cycle, earlier: earlier
            ),
            prerequisites: prerequisites, directPrerequisites: Self.nearest(entry.after, earlier: earlier), review: review(entry.review),
            notes: notes, session: openers[ref]?.first
        )
    }

    /// A pull request the order doesn't name, with how it's stacked with the others.
    func attachedStep(_ ref: ItemRef, among group: Set<ItemRef>) -> OrderStep {
        var notes: [OrderNote] = []
        for earlier in before[ref, default: []].sorted() where group.contains(earlier) {
            if let origin = origins(earlier, ref).first { notes.append(.stackedWith(earlier, comesAfter: true, origin)) }
        }
        for later in after[ref, default: []].sorted() where group.contains(later) {
            if let origin = origins(ref, later).first { notes.append(.stackedWith(later, comesAfter: false, origin)) }
        }
        return OrderStep(ref: ref, status: status(ref), standing: .notInOrder, notes: notes, session: openers[ref]?.first)
    }

    /// What goes before each of these pull requests BriefBar sees stacked together, among them, and their order.
    func stackOrder(
        _ refs: [ItemRef]
    ) -> (order: [ItemRef], cycles: [[ItemRef]], prerequisites: [ItemRef: [ItemRef]], dependents: Set<ItemRef>) {
        let members = Set(refs)
        var prerequisites: [ItemRef: [ItemRef]] = [:]
        var dependents: Set<ItemRef> = []
        for ref in refs {
            let earlier = before[ref, default: []].filter(members.contains).sorted(by: isEarlier)
            prerequisites[ref] = earlier
            dependents.formUnion(earlier)
        }
        let (order, cycles) = OrderGraph.ordered(refs, before: prerequisites, isEarlier: isEarlier)
        return (order, cycles, prerequisites, dependents)
    }

    /// Pull requests BriefBar sees stacked together, in their order, each with a place, from `first`.
    func stackSteps(_ refs: [ItemRef], from first: Int = 1) -> (steps: [OrderStep], cycles: [[ItemRef]]) {
        let (order, cycles, prerequisites, dependents) = stackOrder(refs)
        let inCycle = cycleMembers(cycles)
        let ancestors = Self.ancestry(prerequisites)
        let steps = order.enumerated().map { index, ref in
            let earlier = prerequisites[ref, default: []]
            return OrderStep(
                ref: ref, number: first + index, status: status(ref),
                standing: standing(
                    of: ref, prerequisites: earlier, hasDependents: dependents.contains(ref), declared: false, cycle: inCycle[ref],
                    earlier: ancestors
                ),
                prerequisites: earlier.map { OrderPrerequisite(ref: $0, origins: origins($0, ref), status: status($0)) },
                directPrerequisites: Self.nearest(earlier, earlier: ancestors), notes: showsAgainst(ref), session: openers[ref]?.first
            )
        }
        return (steps, cycles)
    }

    /// Pull requests BriefBar sees stacked together that no order names, in their order, each with a place: a GitHub
    /// stack, by its number, or a chain of branches, by its earliest pull request.
    func stackMission(_ refs: [ItemRef]) -> OrderMission {
        let (steps, cycles) = stackSteps(refs)
        let stacks = refs.compactMap { facts.pullRequests[$0]?.stack }
        let key: MissionKey
        if let stack = stacks.min(by: { ($0.number, $0.repository) < ($1.number, $1.repository) }) {
            key = .stack(repository: stack.repository, number: stack.number)
        } else {
            key = .chain(refs.min(by: isEarlier) ?? refs[0])
        }
        return OrderMission(
            key: key, kind: .stack, steps: steps, attached: [], cycles: cycles, isFocused: false,
            isFinished: steps.allSatisfy { $0.status.hasEnded }, isStale: false, attention: attention(refs), date: newest(refs),
            sessions: sessions(of: steps.map(\.ref), first: nil), story: commonStory(of: refs)
        )
    }

    /// A story's pull requests that no order names, with what they're stacked with: those stacked together first, each
    /// group in its order and numbered, as a stack is, the groups in the story's task order; then the rest, with no order
    /// known, in that order too.
    func storyMission(_ story: ItemRef, components: [[ItemRef]]) -> OrderMission {
        let comesFirst = comesFirst(in: story)
        let stacked = components.filter { $0.count > 1 }
            .map { component in (component: component, first: component.min(by: comesFirst) ?? component[0]) }
            .sorted { comesFirst($0.first, $1.first) }
            .map(\.component)
        var steps: [OrderStep] = []
        var cycles: [[ItemRef]] = []
        for component in stacked {
            let stack = stackSteps(component, from: steps.count + 1)
            steps += stack.steps
            cycles += stack.cycles
        }
        let rest = components.filter { $0.count == 1 }.joined().sorted(by: comesFirst)
        steps += rest.map { OrderStep(ref: $0, status: status($0), standing: .unordered, session: openers[$0]?.first) }
        for index in steps.indices {
            steps[index].notes += alsoFor(steps[index].ref, besides: story)
        }
        let refs = steps.map(\.ref)
        return OrderMission(
            key: .story(story), kind: .story(story), steps: steps, attached: [], cycles: cycles, isFocused: false,
            isFinished: steps.allSatisfy { $0.status.hasEnded }, isStale: false, attention: attention(refs), date: newest(refs),
            sessions: sessions(of: refs, first: nil), story: missionStory(story)
        )
    }

    /// Open pull requests that no order names and that BriefBar sees stacked with none, grouped one level up from the
    /// session that opened each: under the session that coordinates it, or else the one that started it, or else that
    /// session itself. Never higher, since a session at the top may coordinate a project's work for months. Only two or
    /// more together, with no order.
    func familyMissions(_ refs: [ItemRef]) -> [OrderMission] {
        var groups: [ItemRef: [ItemRef]] = [:]
        for ref in refs {
            guard facts.pullRequests[ref]?.state.isOpen == true,
                  let opener = openers[ref]?.first.flatMap({ facts.sessions[$0] })
            else { continue }
            groups[opener.coordinator ?? opener.parent ?? opener.ref, default: []].append(ref)
        }
        return groups.keys.sorted().compactMap { session in
            guard let refs = groups[session]?.sorted(by: isEarlier), refs.count > 1 else { return nil }
            return OrderMission(
                key: .family(session), kind: .family(session: session),
                steps: refs.map { OrderStep(ref: $0, status: status($0), standing: .unordered, session: openers[$0]?.first) },
                attached: [], cycles: [], isFocused: false, isFinished: false, isStale: false, attention: attention(refs),
                date: newest(refs), sessions: sessions(of: refs, first: session), story: commonStory(of: refs)
            )
        }
    }
}

// MARK: - Words

/// What the order says, in BriefBar's words, for the Pull Requests pages and for agents: pull requests by their numbers,
/// never their titles. Where one stands in its order is about merging only, beside what its source says, which it never
/// repeats.
public enum OrderText {
    /// "!4101", "!4101 and !4102", "!4101, !4102 and !4103", each named as it reads beside `subject`.
    public static func list(_ refs: [ItemRef], near subject: ItemRef? = nil) -> String {
        join(refs.map { $0.orderLabel(near: subject) })
    }

    static func join(_ words: [String]) -> String {
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        default: return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }
    }

    /// Where a step stands in its order, "Merge after !4101"; nil when its notes say it all, or it has no order.
    public static func standing(_ step: OrderStep) -> String? {
        standing(step.standing, of: step.ref)
    }

    public static func standing(_ standing: OrderStanding, of ref: ItemRef) -> String? {
        switch standing {
        case .merged:
            return "Merged"
        case .closed:
            return "Closed without merging"
        case .notVisible(.notListed):
            return "BriefBar can't see it now"
        case .notVisible(.sourceOff):
            return "\(source(of: ref)) is off in BriefBar"
        case .next:
            return "Next to merge"
        case .anyTime:
            return "Any time"
        case .waiting(let open, let unknown):
            let after = "Merge after \(list(open + unknown, near: ref))"
            return unknown.isEmpty ? after : "\(after) · \(cantSee(unknown, near: ref))"
        case .unresolved(let unknown):
            return "Merge after \(list(unknown, near: ref)) · \(cantSee(unknown, near: ref))"
        case .prerequisiteClosed(let earlier):
            return "\(earlier.orderLabel(near: ref)) was closed without merging: check the order"
        case .retarget(let earlier, let branch):
            let label = earlier.orderLabel(near: ref)
            return "\(label) merged: retarget it to \(branch ?? "the branch \(label) merged into")"
        case .inCycle(let others):
            return "It and \(list(others, near: ref)) go before each other: check the order"
        case .notInOrder, .unordered:
            return nil
        }
    }

    /// The capsule on a pull request's row, beside its links: "Next to merge", "After !4103 · stacked", "Any time",
    /// "Check the order". It names only the nearest of what it waits for, and says "stacked" when it's stacked on the one
    /// it names. Nil in a group with no order. The full sentence (`standing`) goes in its tooltip.
    public static func capsule(_ step: OrderStep) -> String? {
        let ref = step.ref
        switch step.standing {
        case .next:
            return "Next to merge"
        case .anyTime:
            return "Any time"
        case .waiting(let open, let unknown):
            let named = open + unknown
            let stacked = named.count == 1 && step.isStacked(on: named[0])
            return "After \(list(named, near: ref))\(stacked ? " · stacked" : "")"
        case .unresolved(let unknown):
            return "After \(list(unknown, near: ref)) · can't see \(unknown.count == 1 ? "it" : "them")"
        case .prerequisiteClosed, .retarget, .inCycle:
            return "Check the order"
        case .merged:
            return "Merged"
        case .closed:
            return "Closed"
        case .notVisible(.notListed):
            return "Can't see it"
        case .notVisible(.sourceOff):
            return "\(source(of: ref)) is off"
        case .notInOrder:
            for note in step.notes {
                if case .stackedWith(let other, let comesAfter, _) = note, comesAfter {
                    return "Stacked on \(other.orderLabel(near: ref))"
                }
            }
            return "Not in this order"
        case .unordered:
            return nil
        }
    }

    /// "1 of 5 merged", for a mission's progress.
    public static func progress(_ mission: OrderMission) -> String {
        "\(mission.mergedCount) of \(mission.pullRequestCount) merged"
    }

    /// When a session suggested reviewing a pull request, and why, as advice, in a quiet line of its own: "Review after
    /// !4102: builds on its changes".
    /// - Parameter session: the name of the session whose order it is, when known.
    public static func review(_ timing: ReviewTiming, of ref: ItemRef, session: String? = nil) -> String {
        switch timing {
        case .now:
            return session.map { "‘\($0)’ says it can be reviewed now" } ?? "Its order says it can be reviewed now"
        case .after(let refs, let reason):
            let one = refs.count == 1
            let why = switch reason {
            case .buildsOnChanges: one ? "builds on its changes" : "builds on their changes"
            case .sameCode: "changes the same code"
            case .stackedDiff: one ? "includes its changes until it merges" : "includes their changes until they merge"
            case .needsDecision: one ? "depends on a decision in it" : "depends on decisions in them"
            }
            return "Review after \(list(refs, near: ref)): \(why)"
        }
    }

    /// A note, as a fact: "Its changes show against !4101's branch, which may still change".
    public static func note(_ note: OrderNote, of ref: ItemRef) -> String {
        switch note {
        case .showsAgainst(let earlier):
            return "Its changes show against \(earlier.orderLabel(near: ref))'s branch, which may still change"
        case .orderDisagrees(let earlier, let origin):
            let label = earlier.orderLabel(near: ref)
            if case .gitHubStack(let number, _, _) = origin {
                return "GitHub stack \(number) puts it after \(label); its order doesn't"
            }
            return "It targets \(label)'s branch; its order doesn't put it after \(label)"
        case .alsoIn(let plans):
            return plans.count == 1 ? "Also in another order" : "Also in \(plans.count) other orders"
        case .stackedWith(let other, let comesAfter, let origin):
            let label = other.orderLabel(near: ref)
            if case .gitHubStack(let number, _, _) = origin {
                return "\(comesAfter ? "After" : "Before") \(label) in GitHub stack \(number)"
            }
            return comesAfter ? "Targets \(label)'s branch" : "\(label) targets its branch"
        case .alsoFor(let story):
            return "Also for \(Self.story(story))"
        }
    }

    /// A story by its type and number, "User Story 5101", once BriefBar read its type; else "Work Item 5101".
    public static func story(_ story: MissionStory) -> String {
        let type = story.type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(type.isEmpty ? "Work Item" : type) \(story.ref.id)"
    }

    /// Why one merges after the other, for a tooltip: "Its order says so (revision 3)", "It targets !4101's branch",
    /// "GitHub stack 41, 3 of 4".
    public static func origin(_ origin: OrderOrigin, earlier: ItemRef, later: ItemRef) -> String {
        switch origin {
        case .declared(let revision): return "Its order says so (revision \(revision))"
        case .branch: return "It targets \(earlier.orderLabel(near: later))'s branch"
        case .gitHubStack(let number, let position, let size): return "GitHub stack \(number), \(position) of \(size)"
        }
    }

    /// "!4101 and !4102 go before each other: check the order".
    public static func cycle(_ refs: [ItemRef]) -> String {
        "\(list(refs, near: refs.first)) go before each other: check the order"
    }

    static func cantSee(_ refs: [ItemRef], near ref: ItemRef) -> String {
        "BriefBar can't see whether \(list(refs, near: ref)) merged"
    }

    static func source(of ref: ItemRef) -> String {
        ref.kind == .gitHubPullRequest ? "GitHub" : "Azure DevOps"
    }
}
