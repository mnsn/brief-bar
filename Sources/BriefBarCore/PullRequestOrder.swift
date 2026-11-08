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
    /// Its work items, all of them, whatever they are, for its mission's name; nil until its source read them, or for a
    /// source that doesn't.
    public var workItems: [ItemRef]?

    public init(
        ref: ItemRef, repository: String, sourceBranch: String, targetBranch: String, isFork: Bool? = nil,
        defaultBranch: String? = nil, author: String? = nil, state: PullRequestState = .open, attention: ItemState? = nil,
        createdAt: Date? = nil, stack: GitHubStack? = nil, stories: [OrderStory]? = nil, workItems: [ItemRef]? = nil
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
        self.workItems = workItems
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

    /// Whether a source reads stories but hasn't read yet what some of its pull requests' work items are for, as right after
    /// BriefBar starts or Show Links is turned on: until it has, which stories' missions there are can't be told.
    public var storiesArePending: Bool {
        readsStories && pullRequests.values.contains { $0.ref.kind == .pullRequest && $0.stories == nil }
    }

    /// Whether BriefBar can tell which stories' missions there are: a source reads stories, and has read them for each of
    /// its pull requests.
    public var seesStories: Bool {
        readsStories && !storiesArePending
    }

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
    /// You put it after the other, with Merge After (`OrderChanges`).
    case yours
    /// You set the other as next to merge, and it waited for nothing that hasn't merged.
    case yourNext
    /// A session's order says so, at this revision of it.
    case declared(revision: Int)
    /// It targets the other's branch.
    case branch
    /// They're next to each other in a GitHub stack: its number, and the later one's place in it, of how many.
    case gitHubStack(number: Int, position: Int, size: Int)

    /// A session's order says so.
    var isDeclared: Bool {
        if case .declared = self { return true }
        return false
    }

    /// It's stacked on the other: its branch or a GitHub stack says so, a fact that only retargeting changes. Merging one
    /// before the other would merge it into the other's branch.
    public var isStacked: Bool {
        switch self {
        case .branch, .gitHubStack: return true
        case .yours, .yourNext, .declared: return false
        }
    }

    /// Which says the most, for the one a row names first: you, then a session's order, then GitHub's stack, then a branch.
    var rank: Int {
        switch self {
        case .yours: return -2
        case .yourNext: return -1
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
        case .branch, .yours, .yourNext: return 0
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
/// story's pull requests, by the story's work item; or a mission of your own, by the ID BriefBar gave it as you made
/// it.
public enum MissionKey: Hashable, Sendable, CustomStringConvertible {
    case plan(UUID)
    /// `owner/name`, lowercased, and the stack's number.
    case stack(repository: String, number: Int)
    case chain(ItemRef)
    case family(ItemRef)
    /// A story's work item.
    case story(ItemRef)
    /// A mission of your own, made with Move to Mission ▸ New Mission (`OrderChanges`).
    case mine(UUID)

    /// One BriefBar works out, from what it sees: a stack, a chain, a session's pull requests or a story's. Not an order,
    /// nor one of yours.
    public var isWorkedOut: Bool {
        switch self {
        case .stack, .chain, .family, .story: true
        case .plan, .mine: false
        }
    }

    /// `plan/<id>`, `stack/octo/storefront/41`, `chain/pullRequest/contoso/4101`, `family/session//<id>`,
    /// `story/workItem/contoso/5101`, `mine/<id>`: what the preferences keep.
    public var description: String {
        switch self {
        case .plan(let id): return "plan/\(id.uuidString.lowercased())"
        case .stack(let repository, let number): return "stack/\(repository)/\(number)"
        case .chain(let ref): return "chain/\(ref.description)"
        case .family(let ref): return "family/\(ref.description)"
        case .story(let ref): return "story/\(ref.description)"
        case .mine(let id): return "mine/\(id.uuidString.lowercased())"
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
        case "mine":
            guard let id = UUID(uuidString: rest) else { return nil }
            self = .mine(id)
        default:
            return nil
        }
    }

    /// The kinds of thing whose source makes the mission it names, but for a session's order, which BriefBar keeps: a
    /// GitHub stack's pull requests, a chain's, the sessions a family's pull requests were opened under, and a story's
    /// work items.
    public var kinds: Set<ItemRef.Kind> {
        switch self {
        case .plan, .mine: return []
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
    /// BriefBar sees this one go before it, which its order doesn't say: it's stacked on it, so it merges after it all the
    /// same.
    case orderDisagrees(ItemRef, OrderOrigin)
    /// It's in these other orders too.
    case alsoIn([UUID])
    /// Stacked with one of the order's pull requests: it comes after that one, or before it.
    case stackedWith(ItemRef, comesAfter: Bool, OrderOrigin)
    /// Its work items are for this story too, whose mission it isn't in.
    case alsoFor(MissionStory)
    /// You set it as next to merge, then.
    case yourNext(Date)
    /// You put it after these, then.
    case yourAfter([ItemRef], Date)
    /// The session that told its order, when known, puts it after this one, which you took away.
    case tookAway(ItemRef, by: ItemRef?)
    /// You moved it here, then, from that mission when known.
    case moved(from: MissionKey?, Date)
    /// The mission you put it in is gone, its order forgotten or its pull requests gone: it stays with the others you put
    /// there, as a mission of yours.
    case placementGone(MissionKey)
    /// The story's mission you put it in isn't gone, but unseen while BriefBar can't read stories, as before Show Links has
    /// read them: it stays with the others you put there meanwhile.
    case placementUnseen(MissionKey)
    /// It waits for this one, which you set as next to merge.
    case afterYourNext(ItemRef)
    /// It doesn't wait for this one, which you set as next to merge: you took that away.
    case notAfterYourNext(ItemRef)
    /// Its order, told by that session when known, puts it after this one, which goes after it: BriefBar set that aside.
    case setAside(ItemRef, by: ItemRef?, through: Circle)
    /// Its order, told by that session when known, puts it after this one, which waits for it through stacked branches and
    /// another mission's order: BriefBar set that aside.
    case goesRound(ItemRef, by: ItemRef?)
    /// Its order, told by that session when known, puts it after this one, which waits for it since you set that one as next
    /// to merge in that mission: BriefBar set that aside, as yours goes before a session's order.
    case yourNextGoesFirst(ItemRef, by: ItemRef?, next: ItemRef, in: MissionKey)
    /// Its order puts it after this one, and that order puts this one after it, directly or through other orders' lines:
    /// each mission keeps its own order's, so check the order.
    case ordersGoRound(ItemRef, order: UUID, direct: Bool)
    /// This one is stacked on it, or waits for it, now: your "after" it doesn't hold.
    case yoursDoesntHold(ItemRef, stacked: Bool)
    /// It's stacked on this one now, which hasn't merged, or which merged while it still targets its branch: your "next to
    /// merge" doesn't hold, until that one merges or you retarget it.
    case nextDoesntHold(ItemRef, retarget: Bool)
    /// You set it as next to merge in that mission, which it isn't in now, or which is gone, its order forgotten.
    case nextElsewhere(MissionKey)
    /// You set it as next to merge in that story's mission, which isn't gone, but unseen while BriefBar can't tell stories'
    /// missions, as before Show Links has read them: it holds again once the mission shows.
    case nextUnseen(MissionKey)
    /// You set this one as next to merge here after it, such as in a chain that came to be one with another: that one's
    /// next, and yours doesn't hold.
    case nextSince(ItemRef)
    /// An order changed its place after you had: it shows the order's, until you put yours back.
    case orderChangedIt(OrderOverride)

    /// What makes the one its order puts it after go after it, for `setAside`.
    public enum Circle: Equatable, Sendable {
        /// Stacked branches alone: it's stacked on it.
        case stacked
        /// Its order's other lines and stacked branches.
        case itsOrder
        /// You put that one after it.
        case yours
        /// Your changes, with others.
        case yourChanges
    }

    /// Whether it's about your changes, or about an order's later change or a stacked branch going against one of yours: what
    /// the details' order line says, and what a row with no order known marks.
    public var isAboutYourChanges: Bool {
        switch self {
        case .yourNext, .yourAfter, .tookAway, .moved, .placementGone, .placementUnseen, .afterYourNext, .notAfterYourNext,
             .yoursDoesntHold, .nextDoesntHold, .nextElsewhere, .nextUnseen, .nextSince, .orderChangedIt, .yourNextGoesFirst:
            return true
        case .setAside(_, _, let circle):
            return circle == .yours || circle == .yourChanges
        case .showsAgainst, .orderDisagrees, .alsoIn, .stackedWith, .alsoFor, .goesRound, .ordersGoRound:
            return false
        }
    }
}

/// An order that changed a pull request's place after you had (`OrderChange.holds`).
public struct OrderOverride: Equatable, Sendable {
    /// What the order says of it now.
    public enum Now: Equatable, Sendable {
        case after([ItemRef])
        case anyTime
        /// Its order doesn't name it anymore.
        case out
    }

    /// What you'd changed.
    public enum Yours: Equatable, Sendable {
        case next
        case after([ItemRef])
        case tookAway([ItemRef])
        case moved
    }

    /// The session that told the order, when known.
    public var by: ItemRef?
    /// When the order last changed.
    public var at: Date
    public var now: Now
    public var yours: Yours

    public init(by: ItemRef?, at: Date, now: Now, yours: Yours) {
        self.by = by
        self.at = at
        self.now = now
        self.yours = yours
    }
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
    /// A change of yours decides where it stands, its own or the one you set as next (`OrderChanges`): its capsule has ✎.
    public var isYours: Bool
    /// You changed its own place, and that holds: set it as next, put it after another or took one away, or moved it.
    public var isChangedByYou: Bool

    public init(
        ref: ItemRef, number: Int? = nil, status: OrderStatus, standing: OrderStanding, prerequisites: [OrderPrerequisite] = [],
        directPrerequisites: [ItemRef] = [], review: ReviewTiming? = nil, notes: [OrderNote] = [], session: ItemRef? = nil,
        isYours: Bool = false, isChangedByYou: Bool = false
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
        self.isYours = isYours
        self.isChangedByYou = isChangedByYou
    }

    /// Whether it comes right after that one, with nothing between them.
    public func comesRightAfter(_ other: ItemRef) -> Bool {
        directPrerequisites.contains(other)
    }

    /// Whether it's stacked on that one: it targets that one's branch, or comes right after it in a GitHub stack.
    public func isStacked(on other: ItemRef) -> Bool {
        prerequisites.first { $0.ref == other }?.origins.contains(where: \.isStacked) ?? false
    }

    /// Its note that two orders put it and another in opposite orders (`OrderNote.ordersGoRound`), when they do: its order
    /// needs checking, as its capsule's ⚠ and its stage say.
    public var ordersGoRound: OrderNote? {
        notes.first { note in
            if case .ordersGoRound = note { true } else { false }
        }
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
/// under a session, or a story's pull requests, whose order nobody told BriefBar; or a mission of your own.
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
        /// Pull requests you put together, with New Mission; or those you'd put in a mission that's gone since, by its key.
        case mine
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

    /// Whether it's a mission of your own.
    public var isMine: Bool {
        kind == .mine
    }

    /// Whether its header shows how far it got, a bar and "1 of 3 merged": all but the pull requests opened under a session
    /// and a story's, which nothing told BriefBar go together in an order, whatever order some of them have.
    public var showsProgress: Bool {
        !isFamily && !isStory
    }

    /// Whether any of its pull requests has a place in an order: not a group whose order nobody knows, whatever became of
    /// its pull requests.
    public var hasOrder: Bool {
        steps.contains { step in
            switch step.standing {
            case .unordered: return false
            // One that merged, closed or can't be seen, with no place in an order and nothing before it.
            case .merged, .closed, .notVisible: return step.number != nil || !step.prerequisites.isEmpty
            default: return true
            }
        }
    }

    /// How many of its pull requests you changed the place of, in a way that holds, those stacked with them that its order
    /// doesn't name too.
    public var changedByYou: Int {
        (steps + attached).filter(\.isChangedByYou).count
    }
}

// MARK: - The board

/// The missions to show, from what the sources show now, the orders sessions told BriefBar, what BriefBar saw become of
/// their pull requests, and your changes to them.
public enum OrderBoard {
    /// Each session's order is a mission of its own, however many a session told, even when they share pull requests.
    /// The pull requests no order names group by what BriefBar sees: those stacked with only one order's pull requests
    /// show with it, apart from what it names; then, with what they're stacked with, by the story their work items are
    /// for: apart in the one unfinished order with a pull request of its own for that story, or else as that story's
    /// mission, two or more; others stacked together are a stack of their own; the rest group by the session they were
    /// opened under, two or more, with no order. A pull request alone isn't shown, nor a story's. Your changes come over
    /// it all, those that hold (`OrderChange.holds`): a pull request you moved shows only where you put it, and those you
    /// put in a mission of your own, or in one that's gone, together; then what you set as next, put after another or took
    /// away. What decides what a pull request merges after: stacked branches, which nobody changes but by retargeting;
    /// then yours; then its order's. What goes round in a circle with those before it is set aside, with a note.
    /// What BriefBar sees each pull request stacked on, by its branch or a GitHub stack, those in no mission included: for
    /// what a change can't go against (`OrderChanges.apply`, `MissionChoices.of`).
    public static func stacked(_ facts: OrderFacts) -> [ItemRef: Set<ItemRef>] {
        var before: [ItemRef: Set<ItemRef>] = [:]
        for edge in OrderInference.edges(facts).keys {
            before[edge.after, default: []].insert(edge.before)
        }
        return before
    }

    /// - Parameter focus: the mission you keep on top.
    public static func missions(
        facts: OrderFacts, orders: DeclaredOrders, evidence: OrderEvidence, focus: MissionKey? = nil,
        changes: OrderChanges = OrderChanges(), now: Date = Date()
    ) -> [OrderMission] {
        let board = Board(facts: facts, evidence: evidence)
        let layer = Layer(changes: changes, orders: orders, board: board)
        // The lines each mission keeps, its order's and the one you set as next's, for those made after it: a line that goes
        // round with them through stacked branches, from one mission to another, is set aside. Those you set one as next in
        // come first, so that yours goes before a session's order there too.
        let groups = board.groups(orders: orders, layer: layer)
        let hasNext = { (group: Board.Group) in group.refs.contains { layer.holding[$0]?.first.map(group.names) == true } }
        var lines = Board.Lines()
        var missions: [OrderMission] = []
        for group in groups.filter(hasNext) + groups.filter({ !hasNext($0) }) {
            if let mission = board.mission(of: group, orders: orders, layer: layer, now: now, lines: &lines) {
                missions.append(mission)
            }
        }
        let built = missions
        // What you set as next in a mission it isn't in now, or that's gone: wherever it shows, it says so, beside an order
        // that doesn't name it too.
        func nextElsewhere(_ ref: ItemRef) -> OrderNote? {
            guard let first = layer.holding[ref]?.first,
                  !built.contains(where: { OrderChanges.names($0, first) && $0.steps.contains { $0.ref == ref } })
            else { return nil }
            return elsewhere(first, seesStories: facts.seesStories, isShown: built.contains { $0.key == first && !$0.isMine })
        }
        for index in missions.indices {
            missions[index].isFocused = missions[index].key == focus
            for step in missions[index].steps.indices {
                if let note = nextElsewhere(missions[index].steps[step].ref) { missions[index].steps[step].notes.append(note) }
            }
            for step in missions[index].attached.indices {
                if let note = nextElsewhere(missions[index].attached[step].ref) { missions[index].attached[step].notes.append(note) }
            }
            for step in missions[index].sameStory.indices {
                if let note = nextElsewhere(missions[index].sameStory[step].ref) { missions[index].sameStory[step].notes.append(note) }
            }
            // What the missions made after it found its order's lines go round with.
            guard let notes = lines.notes[missions[index].key] else { continue }
            for step in missions[index].steps.indices {
                for note in notes[missions[index].steps[step].ref] ?? [] where !missions[index].steps[step].notes.contains(note) {
                    missions[index].steps[step].notes.append(note)
                }
            }
        }
        return missions.sorted(by: showsFirst)
    }

    /// What your change to a pull request in no mission says: that an order went against it, or that you set it as next in a
    /// mission it isn't in now, or that's gone, or a story's that BriefBar can't see yet; for its details, where no mission's
    /// card shows it.
    /// - Parameter seesStories: BriefBar can tell which stories' missions there are (`OrderFacts.seesStories`).
    public static func notes(
        outside ref: ItemRef, missions: [OrderMission], changes: OrderChanges, orders: DeclaredOrders, seesStories: Bool = true
    ) -> [OrderNote] {
        guard let change = changes[ref] else { return [] }
        guard change.holds(in: orders) else { return change.overridden(in: orders).map { [.orderChangedIt($0)] } ?? [] }
        if let first = change.first, !missions.contains(where: { OrderChanges.names($0, first) && $0.contains(ref) }) {
            return [elsewhere(first, seesStories: seesStories, isShown: missions.contains { $0.key == first && !$0.isMine })]
        }
        return []
    }

    /// Where you set it as next to merge, which it isn't in now: gone, or, for a story's while BriefBar can't tell stories'
    /// missions and doesn't show that one, unseen. Shown, as while its own work items are read again, it's elsewhere.
    static func elsewhere(_ first: MissionKey, seesStories: Bool, isShown: Bool) -> OrderNote {
        if case .story = first, !seesStories, !isShown { return .nextUnseen(first) }
        return .nextElsewhere(first)
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

    /// Where something kept by a mission's key goes once that mission is gone, as the missions change: Focus, the name you
    /// gave it, and your changes that name it. The mission all its open pull requests went to, but those your changes moved
    /// into it or out of it, wherever they are now, when that's their story's; for a chain whose earliest pull request
    /// left, the chain or GitHub stack they're in now; or, for a story's, as Show Links is turned off or their work items
    /// change, the chain, GitHub stack or session's they're in now, when it has no other open one, so that what followed
    /// them into the story's mission comes back out with them, and goes back in as they do. A chain split as you moved one
    /// from its middle goes to the part with the most of them, the first shown of those with as many. A story's split in
    /// more than one such mission, as a teammate's chain or a session's of the same story, waits: which one what's kept
    /// came from isn't known. Its pull requests on their own, in no mission, don't count. Nil while it's still there, or
    /// when its open pull requests went different ways, or none is open: what's kept waits, as it would. A session's order
    /// and a mission of your own never move: they're kept by their IDs. One that's gone but for what you'd put in it, which
    /// By Mission shows as yours, is gone.
    /// - Parameters:
    ///   - old: the missions as they were.
    ///   - new: the missions now.
    ///   - moved: the pull requests your changes that hold put in a mission, or out of one (`OrderChange.placement`).
    ///   - alone: only to a mission with all of them, and no open pull request but those and the ones your changes moved,
    ///     never to a part of one that split: for where you set one as next to merge, which shouldn't have others wait for
    ///     it, such as a teammate's of the same story, and holds again as the mission comes back whole. Never a chain's into
    ///     its story's mission: the chain's key names the story's mission that holds the chain, where it's next among the
    ///     chain's own pull requests. Out of a story's mission only into another story's, as their tasks move there: never
    ///     to a chain's, a GitHub stack's or a session's, as it's the story's, though its pull requests change while it
    ///     doesn't show.
    public static func successor(
        of key: MissionKey, from old: [OrderMission], to new: [OrderMission], moved: Set<ItemRef> = [], alone: Bool = false
    ) -> MissionKey? {
        switch key {
        case .plan, .mine: return nil
        case .stack, .chain, .family, .story: break
        }
        guard !new.contains(where: { $0.key == key && !$0.isMine }), let was = old.first(where: { $0.key == key }) else { return nil }
        let open = (was.steps + was.attached + was.sameStory).filter { $0.status.isOpen && !moved.contains($0.ref) }.map(\.ref)
        guard !open.isEmpty else { return nil }
        let had = Set((was.steps + was.attached + was.sameStory).map(\.ref))
        let held = { (mission: OrderMission) in open.filter { ref in mission.steps.contains { $0.ref == ref } }.count }
        // Whether a mission has no open pull request but the gone one's and those your changes moved.
        let within = { (mission: OrderMission) in
            !(mission.steps + mission.attached).contains { $0.status.isOpen && !had.contains($0.ref) && !moved.contains($0.ref) }
        }
        // Where what's kept can go on, with all of them; and with some of them, as they split.
        func goesOn(_ mission: OrderMission, split: Bool) -> Bool {
            guard !mission.isMine else { return false }
            switch (key, mission.key) {
            case (.chain, .story): return !split && !alone
            case (_, .story): return !split
            case (.chain, .chain), (.chain, .stack): return true
            case (.story, .chain), (.story, .stack), (.story, .family): return !alone && within(mission)
            default: return false
            }
        }
        var now = new.first { goesOn($0, split: false) && held($0) == open.count }
        if now == nil, !alone {
            let parts = new.filter { goesOn($0, split: true) && held($0) > 0 }
            if case .story = key {
                now = parts.count == 1 ? parts.first : nil
            } else {
                for mission in parts where held(mission) > (now.map(held) ?? 0) {
                    now = mission
                }
            }
        }
        guard let now, !alone || within(now) else { return nil }
        return now.key
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

    /// The order of a story's pull requests, for its mission: those stacked together together, each group by its first in
    /// the story's tasks' order, as BriefBar sees them stacked within; the rest in that order too.
    func inTasksOrder(_ refs: [ItemRef], of story: ItemRef) -> (ItemRef, ItemRef) -> Bool {
        let comesFirst = comesFirst(in: story)
        var firstOf: [ItemRef: ItemRef] = [:]
        for component in components(of: Set(refs)) {
            let first = component.min(by: comesFirst) ?? component[0]
            for ref in component { firstOf[ref] = first }
        }
        return { lhs, rhs in
            let (left, right) = (firstOf[lhs] ?? lhs, firstOf[rhs] ?? rhs)
            return left != right ? comesFirst(left, right) : self.isEarlier(lhs, rhs)
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

    /// A mission's steps, each saying the other stories its pull request is for, when the mission names one story, the one
    /// all its own are for.
    func notingOtherStories(_ steps: [OrderStep], besides story: MissionStory?) -> [OrderStep] {
        guard let story else { return steps }
        return steps.map { step in
            var step = step
            step.notes += alsoFor(step.ref, besides: story.ref)
            return step
        }
    }
}

// MARK: Your changes

/// Your changes as they apply now: those that hold (`OrderChange.holds`), where they put pull requests, and what you put
/// each after, without what goes round in a circle with stacked branches, or with yours made before it.
private struct Layer {
    let changes: OrderChanges
    let holding: [ItemRef: OrderChange]
    let placed: [ItemRef: OrderPlacement]
    /// What you put each pull request after, that holds.
    let yours: [ItemRef: [ItemRef]]
    /// What you put each after that can't hold, as it waits for it now; `stacked` when by a stacked branch alone.
    let dropped: [ItemRef: [(ref: ItemRef, stacked: Bool)]]
    /// What goes before each, for circles: every stacked branch BriefBar sees, and yours that hold.
    let before: [ItemRef: Set<ItemRef>]

    init(changes: OrderChanges, orders: DeclaredOrders, board: Board) {
        self.changes = changes
        let holding = changes.holding(in: orders)
        self.holding = holding
        placed = holding.compactMapValues(\.placement)
        var before = board.before
        var yours: [ItemRef: [ItemRef]] = [:]
        var dropped: [ItemRef: [(ref: ItemRef, stacked: Bool)]] = [:]
        for change in holding.values.sorted(by: { ($0.changedAt, $0.ref) < ($1.changedAt, $1.ref) }) where !change.isFirst {
            for earlier in change.after where earlier != change.ref {
                if Board.isBefore(change.ref, earlier, in: before) {
                    dropped[change.ref, default: []].append((earlier, Board.isBefore(change.ref, earlier, in: board.before)))
                } else {
                    before[change.ref, default: []].insert(earlier)
                    yours[change.ref, default: []].append(earlier)
                }
            }
        }
        self.yours = yours
        self.dropped = dropped
        self.before = before
    }

    /// When a pull request's change was made, for those you put in a mission to show in the order you put them there.
    func changedAt(_ ref: ItemRef) -> Date {
        holding[ref]?.changedAt ?? .distantPast
    }
}

// MARK: Building missions

extension Board {
    /// A mission's pull requests, before their order: an order's, a stack's, those opened under a session, a story's, or
    /// yours.
    struct Group {
        enum Kind {
            case plan(OrderPlan)
            case stack
            case family(ItemRef)
            /// By the story's work item.
            case story(ItemRef)
            case mine
        }

        var key: MissionKey
        var kind: Kind
        /// Its own: an order's pull requests but those you moved elsewhere, a stack's, those opened under a session.
        var members: [ItemRef]
        /// Those you put in it that aren't its own, as you put them there.
        var placed: [ItemRef] = []
        /// Pull requests its order doesn't name that are stacked with its own.
        var attached: [ItemRef] = []
        /// An order's: the pull requests for one of its own's story it doesn't name, nor stacks with its own, by that story,
        /// stacked together or alone.
        var sameStory: [(story: ItemRef, component: [ItemRef])] = []

        var refs: [ItemRef] { members + placed }

        var plan: OrderPlan? {
            if case .plan(let plan) = kind { return plan }
            return nil
        }

        var isStack: Bool {
            if case .stack = kind { return true }
            return false
        }

        var isStory: Bool {
            story != nil
        }

        /// A story's work item, for a story's pull requests.
        var story: ItemRef? {
            if case .story(let story) = kind { return story }
            return nil
        }

        /// Whether it's the stack, or the story's pull requests, you put a pull request in: by its key, or a chain by one of
        /// its pull requests, which a story's can have stacked among its own.
        func isStack(_ target: MissionKey) -> Bool {
            guard isStack || isStory else { return false }
            if key == target { return true }
            if case .chain(let anchor) = target { return members.contains(anchor) }
            return false
        }

        /// Whether a change names it: by its key, or a chain by one of its own pull requests.
        func names(_ target: MissionKey) -> Bool {
            key == target || isStack(target)
        }
    }

    /// The lines the missions made so far kept, for those made after them to go by: their orders', by the order that said
    /// each first, and the ones you set as next's, by the mission you set each in; with what the later ones found their
    /// orders' lines go round with, for the earlier ones' pull requests to say too.
    struct Lines {
        /// By pull request, what goes before it, and the order that said so.
        var declared: [ItemRef: [ItemRef: UUID]] = [:]
        /// The ones you set as next, in the order their missions were made: where, and what waits for each there.
        var nexts: [(mission: MissionKey, next: ItemRef, waiting: Set<ItemRef>)] = []
        /// Notes for the pull requests of the missions made before, by mission.
        var notes: [MissionKey: [ItemRef: [OrderNote]]] = [:]

        /// Orders' lines, by pull request, what goes before it; but those between two of these.
        func orders(besides members: Set<ItemRef> = []) -> [ItemRef: Set<ItemRef>] {
            var graph: [ItemRef: Set<ItemRef>] = [:]
            for (later, earlier) in declared {
                let kept = members.contains(later) ? Set(earlier.keys).subtracting(members) : Set(earlier.keys)
                if !kept.isEmpty { graph[later] = kept }
            }
            return graph
        }

        /// The ones you set as next's lines, by pull request, what goes before it: every mission's, or that one's.
        func next(in mission: MissionKey? = nil) -> [ItemRef: Set<ItemRef>] {
            var graph: [ItemRef: Set<ItemRef>] = [:]
            for set in nexts where mission == nil || set.mission == mission {
                for ref in set.waiting { graph[ref, default: []].insert(set.next) }
            }
            return graph
        }
    }

    /// The lines by which one goes before the other, from it on, through as few others as there are; nil when it doesn't.
    static func route(from earlier: ItemRef, to later: ItemRef, in before: [ItemRef: Set<ItemRef>]) -> [OrderEdge]? {
        var towards: [ItemRef: ItemRef] = [:]
        var queue = [later]
        var seen: Set<ItemRef> = [later]
        var index = 0
        while index < queue.count {
            let ref = queue[index]
            index += 1
            for previous in before[ref, default: []].sorted() where seen.insert(previous).inserted {
                towards[previous] = ref
                guard previous == earlier else {
                    queue.append(previous)
                    continue
                }
                var edges: [OrderEdge] = []
                var at = earlier
                while let after = towards[at] {
                    edges.append(OrderEdge(at, after))
                    at = after
                }
                return edges
            }
        }
        return nil
    }

    /// Whether one goes before the other, directly or through others, by `before`.
    static func isBefore(_ earlier: ItemRef, _ later: ItemRef, in before: [ItemRef: Set<ItemRef>]) -> Bool {
        isBefore(earlier, later, in: before, [:])
    }

    /// Whether one goes before the other, directly or through others, by either.
    static func isBefore(
        _ earlier: ItemRef, _ later: ItemRef, in before: [ItemRef: Set<ItemRef>], _ more: [ItemRef: Set<ItemRef>]
    ) -> Bool {
        var pending = Array(before[later, default: []].union(more[later, default: []]))
        var seen: Set<ItemRef> = []
        while let ref = pending.popLast() {
            if ref == earlier { return true }
            guard seen.insert(ref).inserted else { continue }
            pending += before[ref, default: []].union(more[ref, default: []])
        }
        return false
    }

    /// The missions' pull requests: each order's, but those you moved elsewhere, with those you put in it; then the pull
    /// requests no order names, by what BriefBar sees: with what they're stacked with, by the story their work items are
    /// for, apart in the one unfinished order with a pull request of its own for it, or else as its mission, two or more;
    /// but those you moved, which join the stack, the chain, the story's pull requests or the pull requests opened under a
    /// session you put them in; then those you put in a mission of your own, or in one that's gone, together, by its key.
    func groups(orders: DeclaredOrders, layer: Layer) -> [Group] {
        let placed = layer.placed
        let placedRefs = placed.keys.sorted { lhs, rhs in
            let (left, right) = (layer.changedAt(lhs), layer.changedAt(rhs))
            return left != right ? left < right : lhs < rhs
        }
        var groups: [Group] = []
        var plansByRef: [ItemRef: [UUID]] = [:]
        for plan in orders.plans {
            let key = MissionKey.plan(plan.id)
            let members = plan.refs.filter { placed[$0].map { $0 == .into(key) } ?? true }
            let added = placedRefs.filter { placed[$0] == .into(key) && !plan.contains($0) }
            for ref in members + added { plansByRef[ref, default: []].append(plan.id) }
            groups.append(Group(key: key, kind: .plan(plan), members: members, placed: added))
        }
        // A chain you put pull requests in, by one of its own, stays a chain while that one's left.
        let anchors = Set(placed.values.compactMap { placement -> ItemRef? in
            if case .into(.chain(let anchor)) = placement { return anchor }
            return nil
        })
        var attached: [UUID: [ItemRef]] = [:]
        var stacks: [[ItemRef]] = []
        var alone: [ItemRef] = []
        var byStory: [ItemRef: [[ItemRef]]] = [:]
        // Those that go as they would without a story: a stack, or the pull requests opened under a session.
        func unstoried(_ component: [ItemRef]) {
            if component.count > 1 || anchors.contains(component[0]) {
                stacks.append(component)
            } else {
                alone += component
            }
        }
        for component in components(of: known.subtracting(plansByRef.keys).subtracting(placed.keys)) {
            var touched: Set<UUID> = []
            for ref in component {
                for neighbor in neighbors(of: ref) { touched.formUnion(plansByRef[neighbor] ?? []) }
            }
            if touched.count == 1, let plan = touched.first {
                attached[plan, default: []] += component
            } else if let story = story(of: component) {
                byStory[story, default: []].append(component)
            } else {
                unstoried(component)
            }
        }
        for index in groups.indices {
            if let plan = groups[index].plan { groups[index].attached = attached[plan.id] ?? [] }
        }
        // An order claims the stories of all its own pull requests, merged ones included, until it's finished: until each
        // of its pull requests has merged or closed, as far as BriefBar knows, one it can't see counting as neither. A
        // finished order leaves its stories' new pull requests to go as they would without it. Not the stories of those you
        // put in it: a Move moves only what you moved.
        var plansByStory: [ItemRef: Set<UUID>] = [:]
        for group in groups where group.refs.contains(where: { !status($0).hasEnded }) {
            guard let plan = group.plan else { continue }
            for ref in group.members {
                for story in stories(of: ref) { plansByStory[story.ref, default: []].insert(plan.id) }
            }
        }
        // A story you put a pull request in has its mission, though it has only one of its own.
        let storiesPlacedIn = Set(placed.values.compactMap { placement -> ItemRef? in
            if case .into(.story(let story)) = placement { return story }
            return nil
        })
        for story in byStory.keys.sorted() {
            let components = byStory[story] ?? []
            if let plans = plansByStory[story], plans.count == 1, let plan = plans.first,
               let index = groups.firstIndex(where: { $0.plan?.id == plan }) {
                groups[index].sameStory += components.map { (story, $0) }
            } else if components.joined().count > 1 || storiesPlacedIn.contains(story) {
                groups.append(Group(key: .story(story), kind: .story(story), members: Array(components.joined())))
            } else {
                // A story with one pull request is no mission: it goes as it would without its story.
                components.forEach(unstoried)
            }
        }
        groups += stacks.map(stackGroup)
        var families = familyGroups(alone)
        var own: [Group] = []
        for ref in placedRefs {
            guard case .into(let target)? = placed[ref] else { continue }
            if case .plan(let id) = target, orders.plan(id) != nil { continue }
            if let index = groups.firstIndex(where: { $0.isStack(target) }) {
                groups[index].placed.append(ref)
            } else if let index = families.firstIndex(where: { $0.key == target }) {
                families[index].placed.append(ref)
            } else if let index = own.firstIndex(where: { $0.key == target }) {
                own[index].placed.append(ref)
            } else {
                own.append(Group(key: target, kind: .mine, members: [], placed: [ref]))
            }
        }
        return groups + families.filter { $0.refs.count > 1 } + own
    }

    /// Pull requests BriefBar sees stacked together that no order names: a GitHub stack, by its number, or a chain of
    /// branches, by its earliest pull request.
    func stackGroup(_ refs: [ItemRef]) -> Group {
        let stacks = refs.compactMap { facts.pullRequests[$0]?.stack }
        let key: MissionKey
        if let stack = stacks.min(by: { ($0.number, $0.repository) < ($1.number, $1.repository) }) {
            key = .stack(repository: stack.repository, number: stack.number)
        } else {
            key = .chain(refs.min(by: isEarlier) ?? refs[0])
        }
        return Group(key: key, kind: .stack, members: refs)
    }

    /// Open pull requests that no order names and that BriefBar sees stacked with none, grouped one level up from the
    /// session that opened each: under the session that coordinates it, or else the one that started it, or else that
    /// session itself. Never higher, since a session at the top may coordinate a project's work for months. However many,
    /// for you to put others with them: only two or more together are a mission.
    func familyGroups(_ refs: [ItemRef]) -> [Group] {
        var groups: [ItemRef: [ItemRef]] = [:]
        for ref in refs {
            guard facts.pullRequests[ref]?.state.isOpen == true,
                  let opener = openers[ref]?.first.flatMap({ facts.sessions[$0] })
            else { continue }
            groups[opener.coordinator ?? opener.parent ?? opener.ref, default: []].append(ref)
        }
        return groups.keys.sorted().map { session in
            Group(key: .family(session), kind: .family(session), members: (groups[session] ?? []).sorted(by: isEarlier))
        }
    }

    /// In a story's mission, the pull requests of the chain you set this one as next in, by the chain's key, and those you
    /// put in the mission, as what you put in the chain went there with it; nil where you set it as next by the mission's
    /// own key.
    func chainsOwn(of next: ItemRef, in group: Group, layer: Layer) -> Set<ItemRef>? {
        guard group.isStory, case .chain(let anchor)? = layer.holding[next]?.first else { return nil }
        let chain = components(of: Set(group.members)).first { $0.contains(anchor) } ?? []
        return Set(chain).union(group.placed)
    }

    /// A mission, from its pull requests: what goes before each, their order, where each stands, and what each says. Nil
    /// when you moved all its pull requests elsewhere.
    ///
    /// What goes before a pull request: the pull requests it's stacked on, wherever they are; what you put it after,
    /// wherever that is; its order's, but what you took away and what you moved elsewhere. Of its order's, what goes round
    /// in a circle with stacked branches or yours is set aside, with a note, as is what goes round with them and the lines
    /// of the missions made before it, from one mission to another, the ones you set as next's first. The one you set as next
    /// goes first, and what waits for nothing that hasn't merged waits for it, but what goes before it that way. An order's
    /// line that goes round with another order's between two of its own pull requests stays, as each order says what it
    /// says of its own, and both say so. An order's pull request with nothing before or after it merges any time, as its
    /// order says; one BriefBar or you put with others has no order known, while it's open.
    /// - Parameter lines: the lines the missions made before it kept; it adds its own, and notes for theirs.
    func mission(
        of group: Group, orders: DeclaredOrders, layer: Layer, now: Date, lines: inout Lines
    ) -> OrderMission? {
        let refs = group.refs
        guard !refs.isEmpty else { return nil }
        let members = Set(refs)
        let own = Set(group.members)
        let plan = group.plan
        var prerequisites: [ItemRef: [ItemRef]] = [:]
        var why: [OrderEdge: [OrderOrigin]] = [:]
        var added: [ItemRef: [OrderNote]] = [:]
        // What goes before each, for circles: every stacked branch, yours that hold, and what's added here.
        var before = layer.before
        func add(_ earlier: ItemRef, before ref: ItemRef, _ origins: [OrderOrigin]) {
            let edge = OrderEdge(earlier, ref)
            if why[edge] == nil { prerequisites[ref, default: []].append(earlier) }
            for origin in origins where why[edge]?.contains(origin) != true {
                why[edge, default: []].append(origin)
            }
            before[ref, default: []].insert(earlier)
        }
        // Set as Next, in this mission: the latest you set that holds.
        let next = refs.filter { ref in
            layer.holding[ref]?.first.map(group.names) == true && status(ref).isOpen
        }.max { lhs, rhs in
            let (left, right) = (layer.changedAt(lhs), layer.changedAt(rhs))
            return left != right ? left < right : lhs > rhs
        }
        // What it's stacked on that hasn't merged, or that merged while it still targets that one's branch: while there's one,
        // your next doesn't hold, and its order's lines stay.
        let blocked = next.flatMap { next in
            self.before[next, default: []].sorted(by: isEarlier).first { earlier in
                status(earlier) != .merged || stillTargets(next, branchOf: earlier)
            }
        }
        // Other missions' lines: the ones you set as next's, and their orders', but those between two of this one's pull
        // requests, which its own order says for itself.
        let otherOrders = lines.orders(besides: members)
        let elsewhere = otherOrders.merging(lines.next()) { $0.union($1) }
        if let plan {
            // What goes before each by stacked branches and the order's lines kept so far, without yours: for what a line that
            // goes round is set aside by.
            var withoutYours = self.before
            for ref in group.members where blocked != nil || ref != next {
                guard let entry = plan.entry(for: ref) else { continue }
                let tookAway = layer.holding[ref]?.notAfter ?? []
                for earlier in entry.after where members.contains(earlier) && !tookAway.contains(earlier) {
                    if Self.isBefore(ref, earlier, in: before) {
                        let circle: OrderNote.Circle = if Self.isBefore(ref, earlier, in: self.before) {
                            .stacked
                        } else if Self.isBefore(ref, earlier, in: withoutYours) {
                            .itsOrder
                        } else if layer.yours[earlier]?.contains(ref) == true {
                            .yours
                        } else {
                            .yourChanges
                        }
                        added[ref, default: []].append(.setAside(earlier, by: plan.declaredBy, through: circle))
                    } else if Self.isBefore(ref, earlier, in: before, otherOrders) {
                        added[ref, default: []].append(.goesRound(earlier, by: plan.declaredBy))
                    } else if Self.isBefore(ref, earlier, in: before, elsewhere),
                              let set = lines.nexts.first(where: { set in
                                  Self.isBefore(ref, earlier, in: before, otherOrders.merging(lines.next(in: set.mission)) { $0.union($1) })
                              }) ?? lines.nexts.first {
                        // What you set as next in another mission goes first.
                        added[ref, default: []].append(.yourNextGoesFirst(earlier, by: plan.declaredBy, next: set.next, in: set.mission))
                    } else {
                        add(earlier, before: ref, [.declared(revision: plan.revision)])
                        withoutYours[ref, default: []].insert(earlier)
                    }
                }
            }
        }
        for ref in refs {
            for earlier in layer.yours[ref] ?? [] {
                add(earlier, before: ref, [.yours])
            }
        }
        for ref in refs {
            for earlier in self.before[ref, default: []].sorted(by: isEarlier) {
                add(earlier, before: ref, origins(earlier, ref))
            }
        }
        var chosen: ItemRef?
        if let next {
            // Another you set as next here that holds, such as in a chain that came to be one with another: the one you set
            // last is the one, and the others say so.
            for ref in refs where ref != next && status(ref).isOpen && layer.holding[ref]?.first.map(group.names) == true {
                added[ref, default: []].append(.nextSince(next))
            }
            if let blocked {
                added[next, default: []].append(.nextDoesntHold(blocked, retarget: status(blocked) == .merged))
            } else {
                chosen = next
                added[next, default: []].append(.yourNext(layer.changedAt(next)))
                // What you took away from waiting for yours says so, as your change to it: but its order's line, which says so
                // itself (`tookAway`).
                for ref in refs where ref != next && layer.holding[ref]?.notAfter.contains(next) == true
                    && !(own.contains(ref) && plan?.entry(for: ref)?.after.contains(next) == true) {
                    added[ref, default: []].append(.notAfterYourNext(next))
                }
                // Every line the missions made before kept, other orders' between this one's pull requests too: what waits for
                // nothing here waits for yours, unless that goes round with them. In a story's mission, where you set it as
                // next in a chain it holds, only that chain's own and those you put in the mission: a teammate's of the same
                // story doesn't wait for it.
                let everywhere = lines.orders().merging(lines.next()) { $0.union($1) }
                let among = chainsOwn(of: next, in: group, layer: layer)
                var waiting: Set<ItemRef> = []
                for ref in refs where ref != next && status(ref).isOpen && layer.holding[ref]?.notAfter.contains(next) != true {
                    guard among?.contains(ref) ?? true,
                          prerequisites[ref, default: []].allSatisfy({ status($0).hasEnded }),
                          !Self.isBefore(ref, next, in: before, everywhere)
                    else { continue }
                    add(next, before: ref, [.yourNext])
                    added[ref, default: []].append(.afterYourNext(next))
                    waiting.insert(ref)
                }
                lines.nexts.append((group.key, next, waiting))
            }
        }
        if let plan {
            // Its order's lines that go round with another order's between two of its own pull requests: each mission keeps
            // its own order's, and both say so.
            let graph = before.merging(lines.orders()) { $0.union($1) }.merging(lines.next()) { $0.union($1) }
            for ref in group.members {
                for earlier in prerequisites[ref, default: []] where why[OrderEdge(earlier, ref)]?.contains(where: \.isDeclared) == true {
                    guard let route = Self.route(from: ref, to: earlier, in: graph),
                          let line = route.first(where: { lines.declared[$0.after]?[$0.before] != nil }),
                          let other = lines.declared[line.after]?[line.before]
                    else { continue }
                    let direct = route.count == 1
                    added[ref, default: []].append(.ordersGoRound(earlier, order: other, direct: direct))
                    let note = OrderNote.ordersGoRound(line.before, order: plan.id, direct: direct)
                    if lines.notes[.plan(other)]?[line.after]?.contains(note) != true {
                        lines.notes[.plan(other), default: [:]][line.after, default: []].append(note)
                    }
                }
            }
            for ref in refs {
                for earlier in prerequisites[ref, default: []]
                where why[OrderEdge(earlier, ref)]?.contains(where: \.isDeclared) == true && lines.declared[ref]?[earlier] == nil {
                    lines.declared[ref, default: [:]][earlier] = plan.id
                }
            }
        }

        let within = prerequisites.mapValues { $0.filter(members.contains) }
        let dependents = Set(within.values.flatMap { $0 })
        // The one you set as next is next, though nothing else waits for it.
        let loose = refs.filter { prerequisites[$0, default: []].isEmpty && !dependents.contains($0) && $0 != chosen }
        let anyTime = plan == nil ? [] : Set(loose.filter(own.contains))
        let unordered = Set(loose.filter { !anyTime.contains($0) && !(group.isStack && own.contains($0)) })
        let place = Dictionary(refs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let goesFirst: (ItemRef, ItemRef) -> Bool = switch group.kind {
        case .plan, .mine: { place[$0, default: 0] < place[$1, default: 0] }
        case .stack, .family: isEarlier
        case .story(let story): inTasksOrder(refs, of: story)
        }
        let (order, cycles) = OrderGraph.ordered(refs, before: within, isEarlier: goesFirst)
        let inCycle = cycleMembers(cycles)
        let ancestry = Self.ancestry(prerequisites)
        // Whether your change to a pull request does something here: not one set as next in another mission only, nor one that
        // takes away only what nothing here puts it after.
        func changesHere(_ ref: ItemRef) -> Bool {
            guard let change = layer.holding[ref] else { return false }
            if !change.after.isEmpty || change.placement != nil || change.first.map(group.names) == true { return true }
            let entry = own.contains(ref) ? plan?.entry(for: ref) : nil
            return change.notAfter.contains { entry?.after.contains($0) == true || $0 == chosen }
        }
        func step(_ ref: ItemRef, number: Int?) -> OrderStep {
            let earlier = prerequisites[ref, default: []]
            let entry = own.contains(ref) ? plan?.entry(for: ref) : nil
            // One whose order nobody knows says so while it's open; one that merged, closed or can't be seen says that.
            let stands: OrderStanding = unordered.contains(ref) && status(ref).isOpen ? .unordered : standing(
                of: ref, prerequisites: earlier, hasDependents: dependents.contains(ref) || ref == chosen,
                declared: !(group.isStack && own.contains(ref)), cycle: inCycle[ref], earlier: ancestry
            )
            let origins = earlier.map { OrderOrigin.ordered(why[OrderEdge($0, ref)] ?? []) }
            return OrderStep(
                ref: ref, number: number, status: status(ref), standing: stands,
                prerequisites: zip(earlier, origins).map { OrderPrerequisite(ref: $0, origins: $1, status: status($0)) },
                directPrerequisites: Self.nearest(earlier, earlier: ancestry), review: review(entry?.review),
                notes: notes(of: ref, in: group, entry: entry, orders: orders, layer: layer) + (added[ref] ?? [])
                    + yourNotes(of: ref, in: group, entry: entry, orders: orders, layer: layer),
                session: openers[ref]?.first,
                isYours: changesHere(ref) || origins.contains { $0.contains(.yours) || $0.contains(.yourNext) },
                isChangedByYou: changesHere(ref)
            )
        }
        var steps: [OrderStep] = []
        for ref in order where !anyTime.contains(ref) && !unordered.contains(ref) {
            steps.append(step(ref, number: steps.count + 1))
        }
        for ref in refs where anyTime.contains(ref) {
            steps.append(step(ref, number: nil))
        }
        for ref in order where unordered.contains(ref) {
            steps.append(step(ref, number: nil))
        }

        let kind: OrderMission.Kind
        let date: Date?
        let first: ItemRef?
        var isStale = false
        let isFinished = steps.allSatisfy { $0.status.hasEnded }
        switch group.kind {
        case .plan(let plan):
            kind = .declared(id: plan.id, revision: plan.revision, declaredBy: plan.declaredBy, updatedAt: plan.updatedAt)
            date = plan.updatedAt
            first = plan.declaredBy
            isStale = !isFinished && now.timeIntervalSince(plan.updatedAt) > DeclaredOrders.staleAfter
        case .stack:
            kind = .stack
            date = newest(refs)
            first = nil
        case .family(let session):
            kind = .family(session: session)
            date = newest(refs)
            first = session
        case .story(let story):
            kind = .story(story)
            date = newest(refs)
            first = nil
        case .mine:
            kind = .mine
            date = [newest(refs), refs.compactMap { layer.holding[$0]?.changedAt }.max()].compactMap { $0 }.max()
            first = nil
        }
        let group = group
        // The story it's for: a story's own, or the one all its pull requests are for, of which each says the others it's
        // for too.
        let story = group.story.map(missionStory) ?? commonStory(of: refs)
        let attached = group.attached.sorted(by: isEarlier).map {
            attachedStep($0, among: members.union(group.attached), in: group, orders: orders, layer: layer)
        }
        let sameStory = sameStorySteps(group.sameStory, in: group, orders: orders, layer: layer)
        return OrderMission(
            key: group.key, kind: kind, steps: notingOtherStories(steps, besides: story),
            attached: notingOtherStories(attached, besides: story),
            cycles: cycles, isFocused: false, isFinished: isFinished, isStale: isStale, attention: attention(refs), date: date,
            sessions: sessions(of: steps.map(\.ref) + group.attached + sameStory.map(\.ref), first: first), story: story,
            sameStory: sameStory
        )
    }

    /// The pull requests for an order's story it doesn't name, apart: each group in the order of its story's tasks, by its
    /// first there; one alone with no order known, those stacked together in their order, each saying how; and what your
    /// change to each says, as one stacked with the order's does.
    func sameStorySteps(
        _ parts: [(story: ItemRef, component: [ItemRef])], in group: Group, orders: DeclaredOrders, layer: Layer
    ) -> [OrderStep] {
        let sorted = parts.map { part in
            (story: part.story, component: part.component, first: part.component.min(by: comesFirst(in: part.story)) ?? part.component[0])
        }.sorted { lhs, rhs in
            lhs.story != rhs.story ? lhs.story < rhs.story : comesFirst(in: lhs.story)(lhs.first, rhs.first)
        }
        return sorted.flatMap { part -> [OrderStep] in
            let members = Set(part.component)
            var within: [ItemRef: [ItemRef]] = [:]
            for ref in part.component {
                within[ref] = before[ref, default: []].filter(members.contains).sorted(by: isEarlier)
            }
            return OrderGraph.ordered(part.component, before: within, isEarlier: isEarlier).order.map { ref in
                var step = attachedStep(ref, among: members, in: group, orders: orders, layer: layer)
                if members.count == 1 { step.standing = .unordered }
                step.notes += alsoFor(ref, besides: part.story)
                return step
            }
        }
    }

    /// What a pull request says of itself in its mission, as facts: its changes show against an open pull request's branch;
    /// it's stacked on one its order doesn't put before it; it's in other orders too.
    func notes(of ref: ItemRef, in group: Group, entry: OrderPlan.Entry?, orders: DeclaredOrders, layer: Layer) -> [OrderNote] {
        if case .family = group.kind { return [] }
        var notes = showsAgainst(ref)
        guard let plan = group.plan, entry != nil else { return notes }
        for earlier in before[ref, default: []].sorted() where plan.contains(earlier) && !plan.puts(earlier, before: ref) {
            if let origin = origins(earlier, ref).first { notes.append(.orderDisagrees(earlier, origin)) }
        }
        let others = orders.plans.filter { $0.id != plan.id && $0.contains(ref) }.map(\.id)
        if !others.isEmpty, layer.placed[ref] == nil { notes.append(.alsoIn(others)) }
        return notes
    }

    /// What your change to a pull request says: what you put it after, what you took away, where you moved it, and, once
    /// an order changed its place since, that it shows the order's.
    func yourNotes(of ref: ItemRef, in group: Group, entry: OrderPlan.Entry?, orders: DeclaredOrders, layer: Layer) -> [OrderNote] {
        guard let change = layer.holding[ref] else {
            return layer.changes[ref]?.overridden(in: orders).map { [.orderChangedIt($0)] } ?? []
        }
        var notes: [OrderNote] = []
        if let kept = layer.yours[ref], !kept.isEmpty { notes.append(.yourAfter(kept, change.changedAt)) }
        for dropped in layer.dropped[ref] ?? [] {
            notes.append(.yoursDoesntHold(dropped.ref, stacked: dropped.stacked))
        }
        if let entry, let plan = group.plan {
            for earlier in change.notAfter where entry.after.contains(earlier) {
                notes.append(.tookAway(earlier, by: plan.declaredBy))
            }
        }
        if case .into(let target)? = change.placement {
            if case .mine = group.kind, target == group.key, !Self.isOwn(target) {
                // A story's mission isn't gone while BriefBar can't tell stories' missions yet, only unseen.
                if case .story = target, !facts.seesStories {
                    notes.append(.placementUnseen(target))
                } else {
                    notes.append(.placementGone(target))
                }
            } else if !change.isAttached {
                notes.append(.moved(from: change.from, change.changedAt))
            }
        }
        return notes
    }

    /// Whether a key is a mission of your own's, rather than one that's gone.
    static func isOwn(_ key: MissionKey) -> Bool {
        if case .mine = key { return true }
        return false
    }

    /// A pull request the order doesn't name, with how it's stacked with the others, and what it's stacked on and what you
    /// put it after, wherever those are, for what its Mission menu offers; and what your change to it says, as one in the
    /// order does: what you put it after, that an order went against it, ✎.
    func attachedStep(_ ref: ItemRef, among shown: Set<ItemRef>, in group: Group, orders: DeclaredOrders, layer: Layer) -> OrderStep {
        var notes: [OrderNote] = []
        var prerequisites: [OrderPrerequisite] = []
        let yours = layer.yours[ref] ?? []
        for earlier in before[ref, default: []].sorted() {
            if shown.contains(earlier), let origin = origins(earlier, ref).first {
                notes.append(.stackedWith(earlier, comesAfter: true, origin))
            }
            let origins = OrderOrigin.ordered(origins(earlier, ref) + (yours.contains(earlier) ? [.yours] : []))
            prerequisites.append(OrderPrerequisite(ref: earlier, origins: origins, status: status(earlier)))
        }
        for earlier in yours where before[ref]?.contains(earlier) != true {
            prerequisites.append(OrderPrerequisite(ref: earlier, origins: [.yours], status: status(earlier)))
        }
        for later in after[ref, default: []].sorted() where shown.contains(later) {
            if let origin = origins(ref, later).first { notes.append(.stackedWith(later, comesAfter: false, origin)) }
        }
        let isChanged = layer.holding[ref].map { !$0.after.isEmpty } ?? false
        return OrderStep(
            ref: ref, status: status(ref), standing: .notInOrder, prerequisites: prerequisites,
            notes: notes + yourNotes(of: ref, in: group, entry: nil, orders: orders, layer: layer), session: openers[ref]?.first,
            isYours: isChanged, isChangedByYou: isChanged
        )
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

    /// A note, as a fact: "Its changes show against !4101's branch, which may still change", "You set it as next to merge ·
    /// 2h", "‘Fix the payments bugs’ puts it after !4102; you took that away".
    /// - Parameter names: what names sessions and missions, and the time, for how long ago; without them, the words do
    ///   without.
    public static func note(_ note: OrderNote, of ref: ItemRef, names: OrderNames = .none) -> String {
        func ago(_ date: Date) -> String {
            names.now.map { " · \(Elapsed.short(since: date, now: $0))" } ?? ""
        }
        func teller(_ session: ItemRef?) -> String {
            session.flatMap(names.name).map { "‘\($0)’" } ?? "Its order"
        }
        switch note {
        case .showsAgainst(let earlier):
            return "Its changes show against \(earlier.orderLabel(near: ref))'s branch, which may still change"
        case .orderDisagrees(let earlier, let origin):
            let label = earlier.orderLabel(near: ref)
            if case .gitHubStack(let number, _, _) = origin {
                return "GitHub stack \(number) puts it after \(label), though its order doesn't"
            }
            // A chain Azure DevOps' branches only suggest may be wrong: a pull request can leave it.
            let remedy = ref.kind == .pullRequest ? ". If they don't go together, Move to Mission ▸ Not in a Mission takes it out" : ""
            return "It targets \(label)'s branch, so it merges after \(label), though its order doesn't say so\(remedy)"
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
        case .yourNext(let date):
            return "You set it as next to merge\(ago(date))"
        case .yourAfter(let refs, let date):
            return "You put it after \(list(refs, near: ref))\(ago(date))"
        case .tookAway(let earlier, let session):
            return "\(teller(session)) puts it after \(earlier.orderLabel(near: ref)); you took that away"
        case .moved(let from, let date):
            let mission = from.flatMap(names.title).map { " from ‘\($0)’" } ?? ""
            return "You moved it here\(mission)\(ago(date))"
        case .placementGone(let key):
            if case .plan = key { return "Its order is gone: you'd put it here" }
            return "Its mission is gone: you'd put it here"
        case .placementUnseen:
            return "You put it in a story's mission, which shows once Show Links reads the story"
        case .afterYourNext(let next):
            return "You set \(next.orderLabel(near: ref)) as next to merge"
        case .notAfterYourNext(let next):
            return "You took away its waiting for \(next.orderLabel(near: ref)), which you set as next to merge"
        case .setAside(let earlier, let session, let circle):
            let label = earlier.orderLabel(near: ref)
            switch circle {
            case .stacked: return "\(teller(session)) puts it after \(label), but \(label) is stacked on it"
            case .itsOrder: return "\(teller(session)) puts it after \(label), but \(label) waits for it through its order and a stacked branch"
            case .yours: return "\(teller(session)) puts it after \(label); you put \(label) after it"
            case .yourChanges: return "\(teller(session)) puts it after \(label), but \(label) waits for it through your changes"
            }
        case .goesRound(let earlier, let session):
            let label = earlier.orderLabel(near: ref)
            return "\(teller(session)) puts it after \(label), but \(label) waits for it through another mission"
        case .yourNextGoesFirst(let earlier, let session, let next, let mission):
            let label = earlier.orderLabel(near: ref)
            let place = names.title(mission).map { "‘\($0)’" } ?? "another mission"
            return next == ref
                ? "\(teller(session)) puts it after \(label), but you set it as next to merge in \(place)"
                : "\(teller(session)) puts it after \(label), but \(label) waits for it since you set "
                    + "\(next.orderLabel(near: ref)) as next to merge in \(place)"
        case .ordersGoRound(let other, let order, let direct):
            let label = other.orderLabel(near: ref)
            let name = names.title(.plan(order)).map { "‘\($0)’" }
            return direct
                ? "\(name ?? "Another order") puts \(label) after it: check the order"
                : "\(label) waits for it through \(name ?? "another order"): check the order"
        case .yoursDoesntHold(let earlier, let stacked):
            let label = earlier.orderLabel(near: ref)
            return "\(label) \(stacked ? "is stacked on it" : "waits for it") now, so your ‘after \(label)’ doesn't hold"
        case .nextDoesntHold(let earlier, false):
            return "Stacked on \(earlier.orderLabel(near: ref)) now, so your ‘next to merge’ doesn't hold"
        case .nextDoesntHold(let earlier, true):
            return "\(earlier.orderLabel(near: ref)) merged: your ‘next to merge’ holds once you retarget it"
        case .nextElsewhere(let mission):
            if let title = names.title(mission) { return "You set it as next to merge in ‘\(title)’, which it isn't in now" }
            if case .plan = mission { return "Its order is gone: you'd set it as next to merge there" }
            return "The mission you set it as next to merge in is gone"
        case .nextUnseen:
            return "You set it as next to merge in a story's mission, which shows once Show Links reads the story"
        case .nextSince(let later):
            return "You set \(later.orderLabel(near: ref)) as next to merge here later, so your ‘next to merge’ doesn't hold"
        case .orderChangedIt(let override):
            return overridden(override, of: ref, names: names)
        }
    }

    /// A story by its type and number, "User Story 5101", once BriefBar read its type; else "Work Item 5101".
    public static func story(_ story: MissionStory) -> String {
        let type = story.type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(type.isEmpty ? "Work Item" : type) \(story.ref.id)"
    }

    /// An order that changed a pull request's place after you had: "‘Fix the payments bugs’ put it after !4102 · 5m, after
    /// you'd set it as next".
    public static func overridden(_ override: OrderOverride, of ref: ItemRef, names: OrderNames = .none) -> String {
        let who = override.by.flatMap(names.name).map { "‘\($0)’" } ?? "Its order"
        let did = switch override.now {
        case .after(let refs): "put it after \(list(refs, near: ref))"
        case .anyTime: "said it can merge any time"
        case .out: "took it out of its order"
        }
        let yours = switch override.yours {
        case .next: "set it as next"
        case .after(let refs): "put it after \(list(refs, near: ref))"
        case .tookAway(let refs): "taken \(list(refs, near: ref)) away"
        case .moved: "moved it"
        }
        let ago = names.now.map { " · \(Elapsed.short(since: override.at, now: $0))" } ?? ""
        return "\(who) \(did)\(ago), after you'd \(yours)"
    }

    /// Why one merges after the other, for a tooltip: "You put it after !4101", "Its order says so (revision 3)", "It
    /// targets !4101's branch", "GitHub stack 41, 3 of 4".
    public static func origin(_ origin: OrderOrigin, earlier: ItemRef, later: ItemRef) -> String {
        switch origin {
        case .yours: return "You put it after \(earlier.orderLabel(near: later))"
        case .yourNext: return "You set \(earlier.orderLabel(near: later)) as next to merge"
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
