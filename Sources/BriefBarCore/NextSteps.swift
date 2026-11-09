import Foundation

// What's next on Azure DevOps' Pull Requests page, several at once: Up Next's slots, the Board's columns and lanes, and each
// mission's next steps, from the pull requests' stages and the missions. Which comes first in a stage (`BoardOrder`) is one
// order for all three, so Up Next's pull request is always the first card in its column. Only how they're shown: nothing
// here changes a group, a count, What's Left or the menu bar, and nothing is read for it.

// MARK: - Cards

/// A pull request on the board: its stage, and where it is among the missions, for which comes first.
public struct BoardCard: Equatable, Sendable, Identifiable {
    public var ref: ItemRef
    public var reading: StageReading
    /// The mission whose lane it's in: the first, as By Mission lists them, that has it; nil in none.
    public var mission: MissionKey?
    /// Its step in that mission.
    public var step: OrderStep?
    /// That mission's place in By Mission's list, from 0.
    public var missionIndex: Int?
    /// Its place in that mission's merge order, among what's left to merge there, from 0: only for one its order numbers.
    /// Nil for one that merges any time, in a group with no order, stacked with the order's or for its story without being
    /// in it, merged or closed, or in no mission.
    public var position: Int?
    /// Its place in that mission as By Mission lists it, from 0: its order's steps, then those stacked with them. Only for
    /// which comes first when nothing else tells them apart, never for which merges first.
    public var listIndex: Int?
    /// The open pull requests that wait for it, directly or through other open ones, by their steps' prerequisites and what
    /// they're stacked on, in any mission the board shows: those that build on it.
    public var waitingForIt: Set<ItemRef>
    /// That mission is the one you focus on.
    public var isFocused: Bool

    public init(
        ref: ItemRef, reading: StageReading, mission: MissionKey? = nil, step: OrderStep? = nil, missionIndex: Int? = nil,
        position: Int? = nil, listIndex: Int? = nil, waitingForIt: Set<ItemRef> = [], isFocused: Bool = false
    ) {
        self.ref = ref
        self.reading = reading
        self.mission = mission
        self.step = step
        self.missionIndex = missionIndex
        self.position = position
        self.listIndex = listIndex
        self.waitingForIt = waitingForIt
        self.isFocused = isFocused
    }

    public var id: ItemRef { ref }
    public var stage: PullRequestStage { reading.stage }
}

extension StageReading {
    /// In progress, and it needs you, with no session on it: a session that asks you something, then a build or check that
    /// failed, then changes someone wants. Nil for the rest, such as a session writing it or a draft.
    public var fixRank: Int? {
        guard stage == .inProgress else { return nil }
        switch why {
        case .asksYou: return 0
        case .failing: return 1
        case .changesWanted: return 2
        default: return nil
        }
    }
}

extension PullRequestStage {
    /// The Board's columns, from left to right.
    public static let columns: [PullRequestStage] = [.inProgress, .yourReview, .teammateReview, .canMerge, .waits, .merged]

    /// Its column's title on the Board: "Waits", short for Waits for another PR.
    public var columnTitle: String {
        self == .waits ? "Waits" : title
    }
}

// MARK: - Which comes first

/// Which comes first in a stage: on the Board, in Up Next and in a mission's next steps. The mission you focus on first, in
/// every stage but In progress, where what needs you comes before it, so that Fix next is always its column's first card;
/// then, in each:
/// - **In progress:** what needs you first, as Fix next has it, the mission you focus on first among it: a session that
///   asks you, then what failed, then changes someone wants, the oldest first; then the rest, the mission you focus on
///   first, as By Mission lists them.
/// - **Your review:** the one that has waited longest; one that others build on as long as the longest waiting of those
///   that wait for it, by their orders or what they're stacked on, in any lane, as none of them can merge before it; of
///   those that waited as long, the one more build on.
/// - **Teammate's review:** Find a reviewer first, as that's yours to do; then the earliest in its mission's merge order.
/// - **Can merge:** next to merge first, then any time, then those with no order; the oldest first, then as By Mission
///   lists them.
/// - **Waits:** the one closest to merging: what it waits for can merge.
/// - **Merged:** the latest first.
public enum BoardOrder {
    /// These cards, all in `stage`, in the order they come in it.
    /// - Parameter stages: every pull request's stage, for what a card in Waits waits for, and how long those that build on
    ///   one in Your review have waited, whatever their lane.
    public static func sorted(_ cards: [BoardCard], in stage: PullRequestStage, stages: [ItemRef: StageReading]) -> [BoardCard] {
        switch stage {
        case .inProgress:
            return cards.sorted { lhs, rhs in
                let left = lhs.reading.fixRank, right = rhs.reading.fixRank
                if (left == nil) != (right == nil) { return left != nil }
                if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
                if let left, let right {
                    if left != right { return left < right }
                    return isOlder(lhs, rhs)
                }
                return isEarlierInMissions(lhs, rhs) ?? isOlder(lhs, rhs)
            }
        case .yourReview:
            let waited = waitedLongest(cards, stages: stages)
            return cards.sorted { lhs, rhs in
                if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
                let left = waited[lhs.ref] ?? .distantFuture, right = waited[rhs.ref] ?? .distantFuture
                if left != right { return left < right }
                // Of those that waited as long, the one more build on, which merges before them.
                if lhs.waitingForIt.count != rhs.waitingForIt.count { return lhs.waitingForIt.count > rhs.waitingForIt.count }
                return isEarlierInMissions(lhs, rhs) ?? isOlder(lhs, rhs)
            }
        case .teammateReview:
            return cards.sorted { lhs, rhs in
                if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
                let left = lhs.reading.why == .findReviewer, right = rhs.reading.why == .findReviewer
                if left != right { return left }
                if let earlier = isEarlierInOrder(lhs, rhs) { return earlier }
                return isEarlierInMissions(lhs, rhs) ?? isOlder(lhs, rhs)
            }
        case .canMerge:
            return cards.sorted { lhs, rhs in
                if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
                let left = mergeRank(lhs), right = mergeRank(rhs)
                if left != right { return left < right }
                let leftSince = lhs.reading.since ?? .distantFuture, rightSince = rhs.reading.since ?? .distantFuture
                if leftSince != rightSince { return leftSince < rightSince }
                // The same each refresh: as By Mission lists them.
                return isEarlierInMissions(lhs, rhs) ?? (lhs.ref < rhs.ref)
            }
        case .waits:
            var distances: [ItemRef: Int] = [:]
            for card in cards {
                var visiting: Set<ItemRef> = []
                distances[card.ref] = distance(card.ref, stages: stages, visiting: &visiting)
            }
            return cards.sorted { lhs, rhs in
                if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
                let left = distances[lhs.ref] ?? farthest, right = distances[rhs.ref] ?? farthest
                if left != right { return left < right }
                if let earlier = isEarlierInOrder(lhs, rhs) { return earlier }
                return isEarlierInMissions(lhs, rhs) ?? isOlder(lhs, rhs)
            }
        case .merged:
            return cards.sorted { lhs, rhs in
                if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
                let left = lhs.reading.since ?? .distantPast, right = rhs.reading.since ?? .distantPast
                if left != right { return left > right }
                return lhs.ref < rhs.ref
            }
        }
    }

    /// Of two, the one longer in its stage, as far as BriefBar knows: one whose time it doesn't know last.
    static func isOlder(_ lhs: BoardCard, _ rhs: BoardCard) -> Bool {
        let left = lhs.reading.since ?? .distantFuture, right = rhs.reading.since ?? .distantFuture
        if left != right { return left < right }
        return lhs.ref < rhs.ref
    }

    /// Whether one comes before the other in its mission's merge order, whatever their missions: nil when neither has a
    /// place, or both the same one.
    static func isEarlierInOrder(_ lhs: BoardCard, _ rhs: BoardCard) -> Bool? {
        switch (lhs.position, rhs.position) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return nil
        }
    }

    /// Whether one comes first as By Mission lists them: by its mission, then its place in that mission's list; one in no
    /// mission after those in one. Nil when that doesn't tell them apart.
    static func isEarlierInMissions(_ lhs: BoardCard, _ rhs: BoardCard) -> Bool? {
        switch (lhs.missionIndex, rhs.missionIndex) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            guard let left = lhs.listIndex, let right = rhs.listIndex, left != right else { return nil }
            return left < right
        }
    }

    /// Since when each in Your review has waited, as its turn counts it: one that others build on as long as the longest
    /// waiting of those in Your review on the board that wait for it, directly or through others, as none of them can merge
    /// before it. From every pull request's stage, not only these cards', so that a mission's lane counts those in other
    /// missions too, and agrees with Up Next.
    static func waitedLongest(_ cards: [BoardCard], stages: [ItemRef: StageReading]) -> [ItemRef: Date] {
        var waited: [ItemRef: Date] = [:]
        for card in cards {
            var since = card.reading.since ?? .distantFuture
            for ref in card.waitingForIt {
                guard let other = stages[ref], other.stage == .yourReview, other.isOnBoard else { continue }
                since = min(since, other.since ?? .distantFuture)
            }
            waited[card.ref] = since
        }
        return waited
    }

    /// Next to merge first, then any time, then those with no order: in no mission, or in one with no order.
    static func mergeRank(_ card: BoardCard) -> Int {
        switch card.step?.standing {
        case .next?: return 0
        case .anyTime?: return 1
        default: return 2
        }
    }

    static let far = 100
    static let farthest = 1_000

    /// How many merges away one in Waits is: 1 when everything it waits for can merge now, one more for each that waits
    /// itself; far while what it waits for is in review, in progress, or can't be seen, and farthest when its order needs
    /// checking.
    static func distance(_ ref: ItemRef, stages: [ItemRef: StageReading], visiting: inout Set<ItemRef>) -> Int {
        guard case .waitsFor(let refs, _)? = stages[ref]?.why, visiting.insert(ref).inserted else { return farthest }
        defer { visiting.remove(ref) }
        var most = 0
        for other in refs {
            let away: Int = switch stages[other]?.stage {
            case .canMerge?: 1
            case .waits?: min(far, 1 + distance(other, stages: stages, visiting: &visiting))
            default: far
            }
            most = max(most, away)
        }
        return most
    }
}

// MARK: - Up Next

/// One of Up Next's slots: a kind of next, each in its stage's color.
public enum UpNextSlot: String, CaseIterable, Sendable, Identifiable {
    /// In progress, and it needs you: what Fix next shows.
    case fix
    case yourReview
    case teammateReview
    case canMerge
    case waits

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fix: "Fix next"
        case .yourReview: "Your next review"
        case .teammateReview: "Next for a teammate"
        case .canMerge: "Merge next"
        case .waits: "Waits next"
        }
    }

    /// The stage it's from: its column on the Board, and its color.
    public var stage: PullRequestStage {
        switch self {
        case .fix: .inProgress
        case .yourReview: .yourReview
        case .teammateReview: .teammateReview
        case .canMerge: .canMerge
        case .waits: .waits
        }
    }

    /// What it shows, for its tooltip.
    public var help: String {
        switch self {
        case .fix: "What needs you to fix or answer: a session that asks you, then a build that failed, then changes someone wants"
        case .yourReview: "The review that has waited longest; in a mission, the earlier one first, as later ones build on it"
        case .teammateReview: "A pull request of yours that needs a reviewer first; then the earliest in its mission"
        case .canMerge: "What Azure DevOps says is ready to complete: next to merge first, then any time"
        case .waits: "Ready to complete, but its order puts it after another: the one closest to merging"
        }
    }

    /// Whether a card of its stage is in it: every one, but Fix next's, which has only what needs you.
    func takes(_ card: BoardCard) -> Bool {
        self == .fix ? card.reading.fixRank != nil : true
    }
}

/// Up Next, at the top of Azure DevOps' Pull Requests page: a slot for each kind of next, with how many more, and only those
/// that have something.
public struct UpNext: Equatable, Sendable {
    public struct Slot: Equatable, Sendable, Identifiable {
        public var kind: UpNextSlot
        /// Its pull request: the first card in its column.
        public var card: BoardCard
        /// How many it has, that one included.
        public var count: Int

        public var id: UpNextSlot { kind }

        /// "1 more", "2 more"; nil when it's the only one.
        public var more: String? {
            count > 1 ? "\(count - 1) more" : nil
        }
    }

    public var slots: [Slot]

    public init(slots: [Slot] = []) {
        self.slots = slots
    }

    public var isEmpty: Bool { slots.isEmpty }

    /// What it says when nothing's next.
    public static let nothingNext = "Nothing's next for you"

    /// Whether you folded it, remembered.
    public static let foldedKey = "order.upNextFolded"

    public static func isFolded(in defaults: some SettingsStorage) -> Bool {
        defaults.bool(forKey: foldedKey)
    }

    public static func setFolded(_ folded: Bool, in defaults: some SettingsStorage) {
        if folded {
            defaults.set(true, forKey: foldedKey)
        } else {
            defaults.removeObject(forKey: foldedKey)
        }
    }
}

// MARK: - A mission's next steps

/// One of a mission's next steps that's yours, as a chip under its header in its stage's color: "Review !4093", "Find a
/// reviewer: !4079", "Complete !4120", "Fix !4131", "Answer !4102". It shows that pull request.
public struct MissionNextStep: Equatable, Sendable, Identifiable {
    public enum Kind: Int, Comparable, Sendable {
        /// A session asks you something.
        case answer
        /// A build or check failed, or someone wants changes.
        case fix
        case review
        case findReviewer
        case complete

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    public var ref: ItemRef

    public init(kind: Kind, ref: ItemRef) {
        self.kind = kind
        self.ref = ref
    }

    public var id: ItemRef { ref }

    /// Its color's stage.
    public var stage: PullRequestStage {
        switch kind {
        case .answer, .fix: .inProgress
        case .review: .yourReview
        case .findReviewer: .teammateReview
        case .complete: .canMerge
        }
    }

    public var title: String {
        let label = ref.shortOrderLabel
        return switch kind {
        case .answer: "Answer \(label)"
        case .fix: "Fix \(label)"
        case .review: "Review \(label)"
        case .findReviewer: "Find a reviewer: \(label)"
        case .complete: "Complete \(label)"
        }
    }

    public var symbol: String {
        switch kind {
        case .answer: "bubble.left.fill"
        case .fix: "xmark.circle.fill"
        case .review: PullRequestStage.yourReview.symbol
        case .findReviewer: PullRequestStage.teammateReview.symbol
        case .complete: PullRequestStage.canMerge.symbol
        }
    }

    /// The step one of a mission's cards is, when it's yours: nil for one that waits on others, or that completes by itself.
    public static func of(_ card: BoardCard) -> MissionNextStep? {
        let kind: Kind
        switch (card.stage, card.reading.why) {
        case (.inProgress, .asksYou): kind = .answer
        case (.inProgress, .failing), (.inProgress, .changesWanted): kind = .fix
        case (.yourReview, _): kind = .review
        case (.teammateReview, .findReviewer): kind = .findReviewer
        case (.canMerge, .ready(autoComplete: false)): kind = .complete
        default: return nil
        }
        return MissionNextStep(kind: kind, ref: card.ref)
    }
}

// MARK: - The Board

/// How the Board puts its cards in lanes: one for each mission, or every card in one.
public enum BoardLanes: String, CaseIterable, Sendable {
    case missions
    case none

    public static let defaultsKey = "order.boardLanes"

    /// What you chose last: a lane for each mission until you choose.
    public static func load(from defaults: some SettingsStorage) -> BoardLanes {
        defaults.string(forKey: defaultsKey).flatMap(BoardLanes.init(rawValue:)) ?? .missions
    }

    public func save(to defaults: some SettingsStorage) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public var title: String {
        switch self {
        case .missions: "Missions"
        case .none: "None"
        }
    }
}

/// A lane of the Board: a mission's cards, those in no mission, or all of them.
public struct BoardLane: Equatable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case mission(MissionKey)
        case notInAMission
        /// Every card, with Lanes: None.
        case all
    }

    public var kind: Kind
    /// Its cards in each column, in the order they come there.
    public var columns: [PullRequestStage: [BoardCard]]

    public init(kind: Kind, columns: [PullRequestStage: [BoardCard]]) {
        self.kind = kind
        self.columns = columns
    }

    public var id: Kind { kind }

    public var mission: MissionKey? {
        if case .mission(let key) = kind { return key }
        return nil
    }

    /// Its cards, column by column.
    public var cards: [BoardCard] {
        PullRequestStage.columns.flatMap { columns[$0] ?? [] }
    }

    public func cards(in stage: PullRequestStage) -> [BoardCard] {
        columns[stage] ?? []
    }

    public var isEmpty: Bool { columns.values.allSatisfy(\.isEmpty) }

    /// Its next steps that are yours, in the order Up Next takes them: what a session asks you, what to fix, reviews, finding
    /// a reviewer, completing; in each, as its column has them.
    public var nextSteps: [MissionNextStep] {
        let steps = cards.compactMap(MissionNextStep.of)
        let fixRanks = Dictionary(cards.map { ($0.ref, $0.reading.fixRank ?? 0) }, uniquingKeysWith: { first, _ in first })
        return steps.enumerated().sorted { lhs, rhs in
            if lhs.element.kind != rhs.element.kind { return lhs.element.kind < rhs.element.kind }
            let left = fixRanks[lhs.element.ref] ?? 0, right = fixRanks[rhs.element.ref] ?? 0
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// With no next step of yours, what it waits for: its first pull request that hasn't merged, in its order, as its stage
    /// says why, "Waiting for Priya (!4091)"; nil once all merged, or with a step of yours.
    /// - Parameters:
    ///   - name: what a source calls a session, when it says.
    ///   - separator: what goes before a second reason, "‘Cart’ is writing it · build failed": ", " for VoiceOver's
    ///     pause.
    public func waiting(name: (ItemRef) -> String?, then separator: String = " · ") -> String? {
        guard nextSteps.isEmpty else { return nil }
        let open = cards.filter { $0.stage != .merged }
        guard let first = open.min(by: { BoardOrder.isEarlierInOrder($0, $1) ?? BoardOrder.isOlder($0, $1) }) else { return nil }
        return "\(StageText.why(first.reading, name: name, then: separator)) (\(first.ref.shortOrderLabel))"
    }
}

/// The Board: a column for each stage, a lane for each mission, and their cards, with Up Next, worked out together so that
/// they agree. Only pull requests of the page's kinds that are on your board, by their stages.
public struct PullRequestBoard: Equatable, Sendable {
    public var lanes: [BoardLane]
    /// How many pull requests each column has, each once, whatever lanes show it.
    public var counts: [PullRequestStage: Int]
    /// The pull request that wears Next in each column: Up Next's, the first in its column's order, across the lanes.
    public var next: [PullRequestStage: ItemRef]
    public var upNext: UpNext
    /// Each pull request on the board, once.
    public var refs: Set<ItemRef>
    /// The kinds of pull request its page lists.
    public var kinds: Set<ItemRef.Kind>
    /// A lane for each mission, or one for every card.
    public var mode: BoardLanes

    public init(
        lanes: [BoardLane] = [], counts: [PullRequestStage: Int] = [:], next: [PullRequestStage: ItemRef] = [:], upNext: UpNext = UpNext(),
        refs: Set<ItemRef> = [], kinds: Set<ItemRef.Kind> = [], mode: BoardLanes = .missions
    ) {
        self.lanes = lanes
        self.counts = counts
        self.next = next
        self.upNext = upNext
        self.refs = refs
        self.kinds = kinds
        self.mode = mode
    }

    /// - Parameters:
    ///   - stages: each pull request's stage, as Pull Request Order works it out.
    ///   - missions: the missions, as By Mission lists them.
    ///   - kinds: the kinds of pull request the page lists.
    ///   - lanes: a lane for each mission, or one for all.
    public static func make(
        stages: [ItemRef: StageReading], missions: [OrderMission], kinds: Set<ItemRef.Kind>, lanes: BoardLanes = .missions
    ) -> PullRequestBoard {
        let shown = missions.filter { $0.shows(kinds) }
        let onBoard = stages.filter { kinds.contains($0.key.kind) && $0.value.isOnBoard }

        // Each pull request once, in the first mission that has it, but one that waits (below).
        var first: [ItemRef: BoardCard] = [:]
        var laneCards: [[BoardCard]] = []
        let waiters = waiters(in: shown)
        for (index, mission) in shown.enumerated() {
            var cards: [BoardCard] = []
            for place in places(in: mission) {
                let step = place.step
                guard let reading = onBoard[step.ref] else { continue }
                let card = BoardCard(
                    ref: step.ref, reading: reading, mission: mission.key, step: step, missionIndex: index, position: place.position,
                    listIndex: place.listIndex, waitingForIt: waiters[step.ref] ?? [], isFocused: mission.isFocused
                )
                cards.append(card)
                if first[step.ref] == nil { first[step.ref] = card }
            }
            laneCards.append(cards)
        }
        // One that waits, in the first mission that holds it, as its stage says: with a lane for every card too, its card
        // speaks for that mission, its capsule, its menu and Set as Next to Merge. It stays among the mission you focus
        // on's, where that one has it too, as each column puts those first.
        for (ref, card) in first where card.stage == .waits {
            guard let holder = StageOrder.holders(of: ref, in: shown).first, holder != card.mission,
                  let index = shown.firstIndex(where: { $0.key == holder }),
                  var held = laneCards[index].first(where: { $0.ref == ref }) else { continue }
            held.isFocused = held.isFocused || card.isFocused
            first[ref] = held
        }
        let outside = onBoard.keys.filter { first[$0] == nil }.sorted().compactMap { ref in
            onBoard[ref].map { BoardCard(ref: ref, reading: $0) }
        }
        let all = Array(first.values) + outside

        var counts: [PullRequestStage: Int] = [:]
        var next: [PullRequestStage: ItemRef] = [:]
        var slots: [UpNext.Slot] = []
        let sorted = columns(all, stages: stages)
        for stage in PullRequestStage.columns {
            let cards = sorted[stage] ?? []
            if !cards.isEmpty { counts[stage] = cards.count }
        }
        for kind in UpNextSlot.allCases {
            let taken = (sorted[kind.stage] ?? []).filter(kind.takes)
            guard let card = taken.first else { continue }
            slots.append(UpNext.Slot(kind: kind, card: card, count: taken.count))
            next[kind.stage] = card.ref
        }

        var boardLanes: [BoardLane] = []
        switch lanes {
        case .missions:
            for (mission, cards) in zip(shown, laneCards) {
                boardLanes.append(BoardLane(kind: .mission(mission.key), columns: columns(cards, stages: stages)))
            }
            if !outside.isEmpty {
                boardLanes.append(BoardLane(kind: .notInAMission, columns: columns(outside, stages: stages)))
            }
        case .none:
            if !all.isEmpty { boardLanes.append(BoardLane(kind: .all, columns: sorted)) }
        }
        return PullRequestBoard(
            lanes: boardLanes, counts: counts, next: next, upNext: UpNext(slots: slots), refs: Set(onBoard.keys), kinds: kinds,
            mode: lanes
        )
    }

    /// A mission's lane, as a lane for each mission has it, for its next steps in List and on the Map too.
    public func lane(for mission: MissionKey) -> BoardLane? {
        lanes.first { $0.mission == mission }
    }

    /// A pull request's card as the board has it now: in this lane, where it has it, else in the first lane that does; nil
    /// once it left the board.
    public func card(_ ref: ItemRef, preferring lane: BoardLane.Kind) -> BoardCard? {
        let preferred = lanes.first { $0.kind == lane }?.cards.first { $0.ref == ref }
        return preferred ?? lanes.lazy.compactMap { $0.cards.first { $0.ref == ref } }.first
    }

    // MARK: Undo

    /// Its lanes, with one more where your last change was to one of the page's pull requests that no lane has now: it left
    /// the board, and no mission's lane has it. That lane, of those in no mission, or of every card, shows its Undo line,
    /// though it has no card.
    /// - Parameter missions: the missions the page shows, as the lanes' headers have them.
    public func lanes(keepingUndoOf changed: ItemRef?, missions: [OrderMission]) -> [BoardLane] {
        guard let changed, isUnhosted(changed, missions: missions) else { return lanes }
        let kind: BoardLane.Kind = mode == .none ? .all : .notInAMission
        return lanes.contains { $0.kind == kind } ? lanes : lanes + [BoardLane(kind: kind, columns: [:])]
    }

    /// The pull requests whose Undo line a lane shows, when your last change was to one of them: a mission's lane, every
    /// one of its mission's, those for its story apart from its order too, on the board or not, as List's card does; the
    /// lane of those in no mission, or of every card, its cards, and the one you changed once it left the board where no
    /// mission's lane has it.
    public func undoRefs(of lane: BoardLane, missions: [OrderMission], changed: ItemRef?) -> Set<ItemRef> {
        var refs = Set(lane.cards.map(\.ref))
        switch lane.kind {
        case .mission(let key):
            if let mission = missions.first(where: { $0.key == key }) {
                refs.formUnion(mission.refs)
            }
        case .notInAMission, .all:
            if let changed, isUnhosted(changed, missions: missions) { refs.insert(changed) }
        }
        return refs
    }

    /// Whether a pull request of the page's kinds has no lane to show its Undo in: it left the board, and, with a lane for
    /// each mission, no mission has it.
    func isUnhosted(_ ref: ItemRef, missions: [OrderMission]) -> Bool {
        guard kinds.contains(ref.kind), !refs.contains(ref) else { return false }
        return mode == .none || !missions.contains { $0.shows(kinds) && $0.contains(ref) }
    }

    /// Of a page's pull requests, how many aren't on the board, such as others' that you approved, others' drafts, and those
    /// closed without merging.
    public func notOnBoard(_ listed: [ItemRef]) -> Int {
        Set(listed).subtracting(refs).count
    }

    /// Each of a mission's pull requests as By Mission lists them, its order's, those stacked with them, then those for its
    /// story that its order doesn't name, with its place in that list and its place in the merge order among what's left to
    /// merge: only for an open one its order numbers, as a family's list or an any-time one's place says nothing of what
    /// merges first.
    static func places(in mission: OrderMission) -> [(step: OrderStep, position: Int?, listIndex: Int)] {
        let numbered = mission.steps.filter { $0.number != nil && !$0.status.hasEnded }
            .sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        let positions = Dictionary(numbered.enumerated().map { ($1.ref, $0) }, uniquingKeysWith: { first, _ in first })
        return (mission.steps + mission.attached + mission.sameStory).enumerated().map { index, step in
            (step, index < mission.steps.count ? positions[step.ref] : nil, index)
        }
    }

    /// For each pull request in these missions, those that wait for it, directly or through others: by their steps'
    /// prerequisites, and by what they're stacked on (`OrderMission.stackedBases(of:)`), as one stacked on a pull request
    /// its order doesn't name can't merge before it either. Only between open ones: one that merged or closed waits for
    /// nothing, and nothing waits through it, as its order lets what comes after it merge once it merged. Across the
    /// missions, so that a pull request in two gathers what waits for it in each.
    static func waiters(in missions: [OrderMission]) -> [ItemRef: Set<ItemRef>] {
        var ended: Set<ItemRef> = []
        for mission in missions {
            for step in mission.steps + mission.attached {
                if step.status.hasEnded { ended.insert(step.ref) }
                for prerequisite in step.prerequisites where prerequisite.status.hasEnded { ended.insert(prerequisite.ref) }
            }
        }
        var direct: [ItemRef: Set<ItemRef>] = [:]
        for mission in missions {
            for step in mission.steps + mission.attached where !ended.contains(step.ref) {
                for earlier in step.prerequisites.map(\.ref) + mission.stackedBases(of: step.ref)
                where earlier != step.ref && !ended.contains(earlier) {
                    direct[earlier, default: []].insert(step.ref)
                }
            }
        }
        var all: [ItemRef: Set<ItemRef>] = [:]
        for ref in direct.keys {
            var found: Set<ItemRef> = []
            var next = Array(direct[ref] ?? [])
            while let waiter = next.popLast() {
                guard waiter != ref, found.insert(waiter).inserted else { continue }
                next.append(contentsOf: direct[waiter] ?? [])
            }
            all[ref] = found
        }
        return all
    }

    static func columns(_ cards: [BoardCard], stages: [ItemRef: StageReading]) -> [PullRequestStage: [BoardCard]] {
        let byStage = Dictionary(grouping: cards, by: \.stage)
        return byStage.mapValues { cards in BoardOrder.sorted(cards, in: cards[0].stage, stages: stages) }
    }
}

// MARK: - Moving a card

/// A card you drag on the Board: its pull request, and a token that only this drag carries, so that a column takes only a card
/// dragged from its own board, never text dragged in from another app that names a pull request.
public struct BoardDrag: Equatable, Sendable {
    public let ref: ItemRef
    public let token: UUID

    public init(ref: ItemRef, token: UUID = UUID()) {
        self.ref = ref
        self.token = token
    }

    /// What the drag carries.
    public var payload: String {
        "\(token.uuidString)|\(ref.description)"
    }

    /// The pull request a drop carries, when it's this drag's: nil for anything else.
    public func ref(dropped payload: String) -> ItemRef? {
        payload == self.payload ? ref : nil
    }
}

/// What moving a card to a column does, by dragging it or with ⌘→ and ⌘←.
public enum BoardMove: Equatable, Sendable {
    /// Nothing: it's there already.
    case stays
    /// Sets that stage, as you.
    case setStage(PullRequestStage)
    /// Set as Next to Merge in this mission, which holds it: it no longer waits there.
    case setAsNext(MissionKey)
    /// Why it can't go there.
    case refused(String)

    /// Whether the column takes it.
    public var isTaken: Bool {
        switch self {
        case .setStage, .setAsNext: true
        case .stays, .refused: false
        }
    }
}

/// What the Board lets you do with a card. You can set the three stages that are yours to set; Can merge, Waits and Merged
/// come only from what BriefBar sees, so a card goes there only by Set as Next to Merge, from Waits, in a mission whose order
/// holds it. Someone else's pull request asks its own reviewers: Finished My Review takes it off your board instead. A card
/// moves between columns in its own lane: another mission is Move to Mission's, in its menu.
public enum BoardRules {
    /// What dropping a card on a column does.
    /// - Parameters:
    ///   - sameLane: the column is in its own lane.
    ///   - isYours: you opened it.
    ///   - author: who did, for someone else's: "Priya".
    ///   - missionChanges: you can change missions yourself: Set as Next to Merge, Merge After and Move to Mission.
    ///   - missions: the missions it's in, for whether it can be set as next to merge (`OrderMission.whyNotNext`), and
    ///     where it waits (`StageOrder.holders(of:in:)`).
    ///   - names: what names the mission it waits in, where its lane's doesn't hold it.
    ///   - nextIn: the mission you set it as next to merge in, whose order would hold it again were it next in its lane's
    ///     mission instead, or in another's, where its lane's doesn't hold it.
    public static func move(
        _ card: BoardCard, to stage: PullRequestStage, sameLane: Bool = true, isYours: Bool, author: String? = nil,
        missionChanges: Bool = false, missions: [OrderMission] = [], names: OrderNames = .none, nextIn: MissionKey? = nil
    ) -> BoardMove {
        if card.stage == .merged { return stage == .merged && sameLane ? .stays : .refused(BoardText.hasMerged) }
        guard sameLane else { return .refused(BoardText.otherLane(missionChanges: missionChanges)) }
        if stage == card.stage, card.reading.isOnBoard { return .stays }
        switch stage {
        case .inProgress, .yourReview:
            return .setStage(stage)
        case .teammateReview:
            return isYours ? .setStage(stage) : .refused(BoardText.someoneElses(author))
        case .canMerge:
            guard card.stage == .waits else { return .refused(BoardText.azureDevOpsDecides) }
            if let why = missions.lazy.compactMap({ $0.whyNotNext(card.ref) }).first { return .refused(why) }
            guard missionChanges else { return .refused(BoardText.waitsUntilMerged(card)) }
            // Next in a mission whose order would hold it again: set as next in its lane's, it would only wait in that one
            // instead, back and forth. Merge After takes away what it waits for where it waits.
            if let nextIn, let there = missions.first(where: { $0.key == nextIn }),
               let why = BoardText.nextIn(there, ref: card.ref, lane: card.mission, missions: missions, names: names) {
                return .refused(why)
            }
            // In its lane's mission, where that one holds it: set as next in another of its missions, it would still wait.
            let holders = StageOrder.holders(of: card.ref, in: missions)
            if let mission = card.mission, holders.isEmpty || holders.contains(mission) { return .setAsNext(mission) }
            guard let holder = holders.first.flatMap({ key in missions.first { $0.key == key } }) else {
                return .refused(BoardText.waitsUntilMerged(card))
            }
            return .refused(BoardText.waitsIn(BoardText.title(of: holder, names: names)))
        case .waits:
            return .refused(BoardText.orderDecides(missionChanges: missionChanges))
        case .merged:
            return .refused(BoardText.mergesInAzureDevOps)
        }
    }

    /// Where ⌘→ or ⌘← takes a card in a stage: the next or previous stage you can set, in the columns' order; else the next
    /// or previous column, which says why it can't go there; nil at either end. From Waits, ⌘← is Can merge: Set as Next to
    /// Merge, as dropping it there is.
    public static func keyTarget(from stage: PullRequestStage, forward: Bool) -> PullRequestStage? {
        // From Waits, back is Can merge: Set as Next to Merge, which `move` takes or refuses.
        if stage == .waits, !forward { return .canMerge }
        let columns = PullRequestStage.columns
        guard let index = columns.firstIndex(of: stage) else { return nil }
        let ahead = forward ? Array(columns[(index + 1)...]) : Array(columns[..<index].reversed())
        return ahead.first(where: \.isSettable) ?? ahead.first
    }

}

// MARK: - Words

/// What the Board and Up Next say, in BriefBar's words: pull requests by their numbers, sessions by their names.
public enum BoardText {
    /// Who set a card's stage, and how long ago, when someone did: "You · 2h", "‘Cart’ · 5m"; only when, where why it's in
    /// its stage, which the card says too, names the session already (`StageText.namesWhoSetIt`): "set 5m ago".
    public static func setter(_ reading: StageReading, now: Date, name: (ItemRef) -> String?) -> String? {
        guard let mark = reading.mark else { return nil }
        if StageText.namesWhoSetIt(reading) { return "set " + StageText.agoWords(mark.at, now: now) }
        return StageText.setter(mark, name: name) + " · " + Elapsed.short(since: mark.at, now: now)
    }

    /// The line under the Board: "3 more in your lists aren't on the board"; nil for none.
    public static func notOnBoard(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 more in your lists isn't on the board"
        default: "\(count) more in your lists aren't on the board"
        }
    }

    /// Why some pull requests in your lists aren't on the board, for that line's tooltip.
    public static let notOnBoardHelp =
        "Others' pull requests you approved or declined, others' drafts, and those closed without merging. By Status lists them."

    static let hasMerged = "It merged: nothing changes its stage now"
    static let azureDevOpsDecides = "Azure DevOps decides when it can merge: once it says it's ready to complete"
    static let mergesInAzureDevOps = "It merges in Azure DevOps: complete it there"

    static func otherLane(missionChanges: Bool) -> String {
        missionChanges
            ? "It goes in another mission with Mission ▸ Move to Mission, in its menu"
            : "A card moves between stages in its own mission's lane"
    }

    static func orderDecides(missionChanges: Bool) -> String {
        missionChanges ? "Its order decides what it waits for: Mission ▸ Merge After, in its menu" : "Its order decides what it waits for"
    }

    /// Why a card that waits isn't set as next to merge in its lane's mission, which doesn't hold it.
    static func waitsIn(_ mission: String) -> String {
        "It waits in ‘\(mission)’: set it as next there"
    }

    /// Where a pull request still waits once set as next to merge in a mission whose order held it, as another's holds it
    /// too, and what frees it there: "It still waits for !4102 in ‘Payments’: its Mission ▸ Merge After there takes that
    /// away". Only one mission has it as next, so the Board doesn't set it as next there too, which would leave it waiting
    /// here again (`BoardRules.move`). Nil where no other mission holds it.
    public static func stillWaits(
        _ ref: ItemRef, besides mission: MissionKey, in missions: [OrderMission], names: OrderNames = .none
    ) -> String? {
        waitsElsewhere(ref, besides: mission, in: missions, names: names).map { "It still " + $0 }
    }

    /// Why the Board doesn't set a pull request as next to merge in one of its missions where it's next in another, whose
    /// order would hold it again: "It's next to merge in ‘Checkout’ and still waits for !4102 in ‘Payments’: its Mission ▸
    /// Merge After there takes that away", naming the lane's mission where it waits there too. Nil where no other mission
    /// holds it.
    static func nextIn(
        _ mission: OrderMission, ref: ItemRef, lane: MissionKey?, missions: [OrderMission], names: OrderNames
    ) -> String? {
        waitsElsewhere(ref, besides: mission.key, lane: lane, in: missions, names: names).map {
            "It's next to merge in ‘\(title(of: mission, names: names))’ and still " + $0
        }
    }

    /// "waits for !4102 in ‘Payments’: its Mission ▸ Merge After there takes that away", or "waits in ‘Payments’, whose
    /// order needs checking", for the lane's mission where its order holds it, else the first other mission whose does.
    private static func waitsElsewhere(
        _ ref: ItemRef, besides mission: MissionKey, lane: MissionKey? = nil, in missions: [OrderMission], names: OrderNames
    ) -> String? {
        let others = missions.filter { $0.key != mission }
        for other in others.filter({ $0.key == lane }) + others.filter({ $0.key != lane }) {
            guard let hold = StageOrder.hold(ref, in: other, among: missions) else { continue }
            let title = title(of: other, names: names)
            if case .waits(let refs, _) = hold, !refs.isEmpty {
                return "waits for \(OrderText.list(refs, near: ref)) in ‘\(title)’: its Mission ▸ Merge After there takes that away"
            }
            return "waits in ‘\(title)’, whose order needs checking"
        }
        return nil
    }

    /// A mission as these words name it: as its header does.
    static func title(of mission: OrderMission, names: OrderNames) -> String {
        names.title(mission.key) ?? OrderText.title(of: mission, name: names.name)
    }

    static func someoneElses(_ author: String?) -> String {
        StageText.whyNotTeammateReview(author: author) + ". Finished My Review takes it off your board"
    }

    /// Without Set as Next to Merge: what it waits for, and when it can merge.
    static func waitsUntilMerged(_ card: BoardCard) -> String {
        switch card.reading.why {
        case .waitsFor(let refs, _):
            let named = OrderText.list(refs, near: card.ref)
            return "It waits for \(named): it can merge once BriefBar sees \(refs.count == 1 ? "it" : "them") merge"
        case .orderHolds(let words):
            return words
        default:
            return "Its order decides when it can merge"
        }
    }
}
