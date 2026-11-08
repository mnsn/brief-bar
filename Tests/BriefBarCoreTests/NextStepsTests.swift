import Foundation
import Testing
@testable import BriefBarCore

/// What's next, several at once: Up Next's slots, the order in each stage (plan §5.2), the Board's lanes and columns, each
/// mission's next steps, what dropping a card or ⌘→ and ⌘← do (§6.2), and what's remembered.
@Suite struct NextStepsTests {
    static func pr(_ number: Int) -> ItemRef { OrderPlansTests.pr(number) }
    static func gh(_ number: Int) -> ItemRef { .gitHubPullRequest(repository: "contoso/shop-web", number: number) }
    static let cart = ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b")!
    static let kinds: Set<ItemRef.Kind> = [.pullRequest]

    static func name(_ ref: ItemRef) -> String? {
        ref == cart ? "Cart" : nil
    }

    static func reading(
        _ stage: PullRequestStage, _ why: StageWhy, at seconds: TimeInterval? = nil, mark: StageMark? = nil, isOnBoard: Bool = true
    ) -> StageReading {
        StageReading(stage: stage, why: why, since: seconds.map(t), mark: mark, isOnBoard: isOnBoard)
    }

    /// A pull request's step in its mission: where it stands, its place in its order (nil for one that merges any time, or in
    /// a group with no order), what its order puts before it, and what it's stacked on.
    static func step(
        _ number: Int, _ standing: OrderStanding = .unordered, status: OrderStatus = .open, place: Int? = nil, after: [Int] = [],
        stackedOn: [Int] = []
    ) -> OrderStep {
        let prerequisites = after.map { OrderPrerequisite(ref: pr($0), origins: [.declared(revision: 1)], status: .open) }
            + stackedOn.map { OrderPrerequisite(ref: pr($0), origins: [.branch], status: .open) }
        return OrderStep(ref: pr(number), number: place, status: status, standing: standing, prerequisites: prerequisites)
    }

    static func mission(
        _ steps: [OrderStep], attached: [OrderStep] = [], focused: Bool = false, family: ItemRef? = nil
    ) -> OrderMission {
        OrderMission(
            key: family.map { .family($0) } ?? .chain(steps.first?.ref ?? attached[0].ref),
            kind: family.map { .family(session: $0) } ?? .stack, steps: steps, attached: attached, cycles: [], isFocused: focused,
            isFinished: false, isStale: false, attention: nil, date: nil, sessions: []
        )
    }

    /// Each pull request's stage, by its number.
    static func refs(_ stages: [Int: StageReading]) -> [ItemRef: StageReading] {
        Dictionary(uniqueKeysWithValues: stages.map { (pr($0.key), $0.value) })
    }

    static func board(
        _ stages: [Int: StageReading], missions: [OrderMission] = [], lanes: BoardLanes = .missions
    ) -> PullRequestBoard {
        PullRequestBoard.make(stages: refs(stages), missions: missions, kinds: kinds, lanes: lanes)
    }

    /// The numbers of a column's cards, in their order, across the board as Lanes: None has them.
    static func column(_ stage: PullRequestStage, _ stages: [Int: StageReading], missions: [OrderMission] = []) -> [String] {
        board(stages, missions: missions, lanes: .none).lanes.first?.cards(in: stage).map(\.ref.shortOrderLabel) ?? []
    }

    // MARK: Up Next

    /// The user's own example: A waits, B's session finished, C needs someone to review it; with a failed build, a review
    /// Priya asked for, one that can merge and one that merged.
    @Test func upNextHasASlotForEachKindOfNextWithHowManyAndOnlyThoseWithSomething() {
        let payments = Self.mission([
            Self.step(4074, .merged, status: .merged), Self.step(4102, .next), Self.step(4079, .waiting(open: [Self.pr(4102)], unknown: [])),
            Self.step(4091, .waiting(open: [Self.pr(4102)], unknown: [])),
            Self.step(3990, .waiting(open: [Self.pr(4091)], unknown: [])),
        ], focused: true)
        let stages: [Int: StageReading] = [
            4074: Self.reading(.merged, .merged, at: 50),
            4102: Self.reading(.inProgress, .working(StageSession(ref: Self.cart, activity: .working, since: t(10))), at: 10),
            4079: Self.reading(.teammateReview, .findReviewer, at: 20),
            4091: Self.reading(.waits, .waitsFor([Self.pr(4102)], words: "After !4102"), at: 30),
            3990: Self.reading(.teammateReview, .waitingFor("Waiting for Sam"), at: 40),
            4131: Self.reading(.inProgress, .failing("Build failed"), at: 60),
            4088: Self.reading(.yourReview, .asked("Priya asked you"), at: 5),
            4093: Self.reading(.yourReview, .finished(StageSession(ref: Self.cart, activity: .finished, since: t(70))), at: 70),
            4120: Self.reading(.canMerge, .ready(autoComplete: false), at: 80),
        ]
        let board = Self.board(stages, missions: [payments])
        let slots = board.upNext.slots
        #expect(slots.map(\.kind) == [.fix, .yourReview, .teammateReview, .canMerge, .waits])
        #expect(slots.map(\.card.ref.shortOrderLabel) == ["!4131", "!4088", "!4079", "!4120", "!4091"])
        #expect(slots.map(\.count) == [1, 2, 2, 1, 1])
        #expect(slots.map(\.more) == [nil, "1 more", "1 more", nil, nil])
        #expect(slots.map(\.kind.stage) == [.inProgress, .yourReview, .teammateReview, .canMerge, .waits])
        #expect(UpNextSlot.allCases.map(\.title) == ["Fix next", "Your next review", "Next for a teammate", "Merge next", "Waits next"])

        // Up Next's pull request wears Next in its column; a session writing one isn't yours to do, so In progress's Next
        // is Fix next's, ahead of it.
        #expect(board.next[.inProgress] == Self.pr(4131))
        #expect(board.next[.teammateReview] == Self.pr(4079))
        #expect(board.next[.merged] == nil)
        #expect(Self.column(.inProgress, stages, missions: [payments]) == ["!4131", "!4102"])
        #expect(board.counts == [.inProgress: 2, .yourReview: 2, .teammateReview: 2, .canMerge: 1, .waits: 1, .merged: 1])
    }

    @Test func withNothingNextItSaysSoAndASessionWritingItIsntFixNext() {
        let writing = Self.reading(.inProgress, .working(StageSession(ref: Self.cart, activity: .working, since: t(10))))
        let board = Self.board([4102: writing, 4104: Self.reading(.inProgress, .draft), 4105: Self.reading(.inProgress, .left("Build running"))])
        #expect(board.upNext.isEmpty)
        #expect(board.next[.inProgress] == nil)
        #expect(UpNext.nothingNext == "Nothing's next for you")
    }

    // MARK: Which comes first in a stage

    @Test func fixNextIsASessionAskingYouThenWhatFailedThenChangesWantedTheOldestFirst() {
        let asking = StageSession(ref: Self.cart, activity: .waitsForYou, since: t(90))
        let stages: [Int: StageReading] = [
            4101: Self.reading(.inProgress, .changesWanted("Priya wants changes"), at: 1),
            4102: Self.reading(.inProgress, .failing("Build failed"), at: 50),
            4103: Self.reading(.inProgress, .failing("Merge conflicts"), at: 20),
            4104: Self.reading(.inProgress, .asksYou(asking), at: 90),
            4105: Self.reading(.inProgress, .authorChanges("Waiting for Sam's changes"), at: 0),
            4106: Self.reading(.inProgress, .set, at: 0, mark: StageMark(stage: .inProgress, at: t(0))),
        ]
        #expect(Self.column(.inProgress, stages) == ["!4104", "!4103", "!4102", "!4101", "!4105", "!4106"])
        #expect(Self.board(stages).upNext.slots.first?.count == 4)
    }

    /// The mission you focus on comes first in every stage but In progress, ahead of what would otherwise come first there: the
    /// review that waited longest, Find a reviewer, the next to merge, the one closest to merging, the latest merged.
    @Test func theMissionYouFocusOnComesFirstInEveryStageButInProgress() {
        let focused = Self.mission([Self.step(4202), Self.step(4203), Self.step(4204, .anyTime), Self.step(4205), Self.step(4206)], focused: true)
        let other = Self.mission([Self.step(4104, .next)])
        let stages: [Int: StageReading] = [
            4102: Self.reading(.yourReview, .asked("Priya asked you"), at: 1),
            4202: Self.reading(.yourReview, .asked("Sam asked you"), at: 99),
            4103: Self.reading(.teammateReview, .findReviewer, at: 1),
            4203: Self.reading(.teammateReview, .waitingFor("Waiting for Sam"), at: 99),
            4104: Self.reading(.canMerge, .ready(autoComplete: false), at: 1),
            4204: Self.reading(.canMerge, .ready(autoComplete: false), at: 99),
            4101: Self.reading(.canMerge, .ready(autoComplete: false), at: 0),
            // One that waits for what can merge is closest; the focused one waits for one still in review.
            4106: Self.reading(.waits, .waitsFor([Self.pr(4101)], words: "After !4101"), at: 1),
            4205: Self.reading(.waits, .waitsFor([Self.pr(4103)], words: "After !4103"), at: 99),
            4105: Self.reading(.merged, .merged, at: 99),
            4206: Self.reading(.merged, .merged, at: 1),
        ]
        let missions = [other, focused]
        #expect(Self.column(.yourReview, stages, missions: missions) == ["!4202", "!4102"])
        #expect(Self.column(.teammateReview, stages, missions: missions) == ["!4203", "!4103"])
        #expect(Self.column(.canMerge, stages, missions: missions) == ["!4204", "!4104", "!4101"])
        #expect(Self.column(.waits, stages, missions: missions) == ["!4205", "!4106"])
        #expect(Self.column(.merged, stages, missions: missions) == ["!4206", "!4105"])
    }

    /// In progress puts what needs you first, so that Fix next is always its column's first card, the mission you focus on
    /// first among it; then the rest, the mission you focus on first.
    @Test func inProgressPutsWhatNeedsYouFirstThenTheMissionYouFocusOn() {
        let focused = Self.mission([Self.step(4201), Self.step(4202)], focused: true)
        let stages: [Int: StageReading] = [
            4101: Self.reading(.inProgress, .failing("Build failed"), at: 1),
            4102: Self.reading(.inProgress, .draft, at: 0),
            4201: Self.reading(.inProgress, .draft, at: 50),
            4202: Self.reading(.inProgress, .failing("Merge conflicts"), at: 99),
        ]
        #expect(Self.column(.inProgress, stages, missions: [focused]) == ["!4202", "!4101", "!4201", "!4102"])

        // With nothing in the focused mission that needs you, what needs you elsewhere still comes first, as Fix next.
        var drafts = stages
        drafts[4202] = Self.reading(.inProgress, .draft, at: 99)
        #expect(Self.column(.inProgress, drafts, missions: [focused]) == ["!4101", "!4201", "!4202", "!4102"])
        let board = Self.board(drafts, missions: [focused])
        #expect(board.upNext.slots.first?.kind == .fix)
        #expect(board.upNext.slots.first?.card.ref == Self.pr(4101))
        #expect(board.next[.inProgress] == Self.pr(4101))
    }

    @Test func yourReviewIsTheLongestWaitingAndAnEarlierOneInItsMissionFirstAsLaterOnesBuildOnIt() {
        // !4202 has waited longest, but it builds on !4201, which comes first in their mission: so !4201, then !4202, then
        // !4101, which waited less long than !4202.
        let coupons = Self.mission([
            Self.step(4201, .next, place: 1), Self.step(4202, .waiting(open: [Self.pr(4201)], unknown: []), place: 2, after: [4201]),
        ])
        let stages: [Int: StageReading] = [
            4101: Self.reading(.yourReview, .asked("Priya asked you"), at: 30),
            4201: Self.reading(.yourReview, .asked("Sam asked you"), at: 90),
            4202: Self.reading(.yourReview, .asked("Sam asked you"), at: 10),
            4102: Self.reading(.yourReview, .asked("Priya asked you")),
        ]
        #expect(Self.column(.yourReview, stages, missions: [coupons]) == ["!4201", "!4202", "!4101", "!4102"])
    }

    /// The user's own example, two lines in one order: !4301 → !4302 → !4303, and !4302 → !4305 → !4306, with !4304 any
    /// time. Each waits as long as the longest waiting of those that build on it, through others too: !4303 and !4306 take
    /// no one's wait, !4305 takes !4306's, !4302 takes !4303's, !4305's and !4306's, and !4301 all of theirs. !4304's goes
    /// to no one, though it has waited longest. Of those that waited as long, the one more build on comes first.
    @Test func aReviewWaitsAsLongAsTheLongestWaitingOfThoseThatBuildOnIt() {
        let order = Self.mission([
            Self.step(4301, .next, place: 1), Self.step(4302, place: 2, after: [4301]), Self.step(4303, place: 3, after: [4302]),
            Self.step(4305, place: 4, after: [4302]), Self.step(4306, place: 5, after: [4305]), Self.step(4304, .anyTime),
        ])
        let asked = StageWhy.asked("Sam asked you")
        let stages: [Int: StageReading] = [
            4301: Self.reading(.yourReview, asked, at: 60), 4302: Self.reading(.yourReview, asked, at: 50),
            4303: Self.reading(.yourReview, asked, at: 20), 4305: Self.reading(.yourReview, asked, at: 40),
            4306: Self.reading(.yourReview, asked, at: 30), 4304: Self.reading(.yourReview, asked, at: 10),
        ]
        let cards = Self.board(stages, missions: [order]).lanes.first?.cards ?? []
        func waiting(_ number: Int) -> Set<ItemRef>? { cards.first { $0.ref == Self.pr(number) }?.waitingForIt }
        #expect(waiting(4303) == [] && waiting(4306) == [] && waiting(4304) == [])
        #expect(waiting(4305) == [Self.pr(4306)])
        #expect(waiting(4302) == Set([4303, 4305, 4306].map(Self.pr)))
        #expect(waiting(4301) == Set([4302, 4303, 4305, 4306].map(Self.pr)))

        let waited = BoardOrder.waitedLongest(cards, stages: Self.refs(stages))
        #expect([4301, 4302, 4303, 4304, 4305, 4306].map { waited[Self.pr($0)] } == [t(20), t(20), t(20), t(10), t(30), t(30)])
        #expect(Self.column(.yourReview, stages, missions: [order]) == ["!4304", "!4301", "!4302", "!4303", "!4305", "!4306"])
    }

    /// A family's list, the pull requests opened under one session whose order nobody told, says nothing of what merges
    /// first: its first takes no one's wait.
    @Test func aFamilysFirstPullRequestDoesntTakeTheOthersWait() {
        let family = Self.mission([Self.step(4501), Self.step(4502), Self.step(4503)], family: Self.cart)
        let asked = StageWhy.asked("Sam asked you")
        let stages: [Int: StageReading] = [
            4501: Self.reading(.yourReview, asked, at: 30), 4502: Self.reading(.yourReview, asked, at: 20),
            4503: Self.reading(.yourReview, asked, at: 10),
        ]
        #expect(PullRequestBoard.places(in: family).map(\.position) == [nil, nil, nil])
        #expect(Self.column(.yourReview, stages, missions: [family]) == ["!4503", "!4502", "!4501"])
    }

    /// With nothing in it yours, a family waits for the one waiting longest, not the first in its list, which merges no
    /// sooner than the others.
    @Test func aFamilyWaitsForTheOneWaitingLongestNotItsFirst() {
        let family = Self.mission([Self.step(4501), Self.step(4502)], family: Self.cart)
        let stages: [Int: StageReading] = [
            4501: Self.reading(.teammateReview, .waitingFor("Waiting for Sam"), at: 30),
            4502: Self.reading(.teammateReview, .waitingFor("Waiting for Priya"), at: 10),
        ]
        #expect(Self.board(stages, missions: [family]).lane(for: family.key)?.waiting(name: Self.name) == "Waiting for Priya (!4502)")
    }

    /// The base the order's pull requests are stacked on, which its order doesn't name, waits as long as they do, as they
    /// build on it, and comes before them, though By Mission lists it after them.
    @Test func aBaseTheOrdersPullRequestsAreStackedOnTakesTheirWait() {
        let order = Self.mission(
            [Self.step(4701, .next, place: 1, stackedOn: [4700]), Self.step(4702, place: 2, after: [4701])],
            attached: [Self.step(4700, .notInOrder)]
        )
        let asked = StageWhy.asked("Sam asked you")
        let stages: [Int: StageReading] = [
            4700: Self.reading(.yourReview, asked, at: 50), 4701: Self.reading(.yourReview, asked, at: 30),
            4702: Self.reading(.yourReview, asked, at: 10),
        ]
        #expect(Self.column(.yourReview, stages, missions: [order]) == ["!4700", "!4701", "!4702"])
    }

    /// The same, in a mission `OrderBoard.missions` builds: the order doesn't name the base, and its first pull request's
    /// changes show against the base's branch, which its step notes, whether or not its prerequisites name the base too.
    @Test func aBaseTheOrderDoesntNameTakesTheWaitOfThoseItsChangesShowAgainst() {
        let missions = Self.missions(
            [OrderBoardTests.ado(4700, from: "robin/base"),
             OrderBoardTests.ado(4701, from: "robin/totals", into: "robin/base"),
             OrderBoardTests.ado(4702, from: "robin/tax")],
            plan: [.init(ref: Self.pr(4701)), .init(ref: Self.pr(4702), after: [Self.pr(4701)])]
        )
        #expect(missions.count == 1)
        #expect(missions.first?.attached.map(\.ref) == [Self.pr(4700)])
        let asked = StageWhy.asked("Sam asked you")
        let stages: [Int: StageReading] = [
            4700: Self.reading(.yourReview, asked, at: 50), 4701: Self.reading(.yourReview, asked, at: 30),
            4702: Self.reading(.yourReview, asked, at: 10),
        ]
        #expect(Self.column(.yourReview, stages, missions: missions) == ["!4700", "!4701", "!4702"])
    }

    /// A mission's lane counts the waits of those in other missions that build on its pull requests, as Up Next does: its
    /// order, its Next and its next steps agree with Up Next's. !4101 → !4105, with !4102 any time, and !4105 → !4106 in
    /// another order; !4106 has waited longest, then !4102, !4105 and !4101, which takes !4106's wait through !4105.
    @Test func aLaneCountsTheWaitsOfThoseInOtherMissionsThatBuildOnItsPullRequests() throws {
        let first = Self.mission([
            Self.step(4101, .next, place: 1), Self.step(4105, place: 2, after: [4101]), Self.step(4102, .anyTime),
        ])
        let second = Self.mission([Self.step(4105, .next, place: 1), Self.step(4106, place: 2, after: [4105])])
        let asked = StageWhy.asked("Sam asked you")
        let stages: [Int: StageReading] = [
            4106: Self.reading(.yourReview, asked, at: 10), 4102: Self.reading(.yourReview, asked, at: 20),
            4105: Self.reading(.yourReview, asked, at: 30), 4101: Self.reading(.yourReview, asked, at: 40),
        ]
        let board = Self.board(stages, missions: [first, second])
        #expect(board.upNext.slots.first { $0.kind == .yourReview }?.card.ref == Self.pr(4101))
        let lane = try #require(board.lane(for: first.key))
        #expect(lane.cards(in: .yourReview).map(\.ref.shortOrderLabel) == ["!4101", "!4105", "!4102"])
        #expect(lane.nextSteps.first?.title == "Review !4101")
        #expect(board.lane(for: second.key)?.cards(in: .yourReview).map(\.ref.shortOrderLabel) == ["!4105", "!4106"])
        #expect(Self.column(.yourReview, stages, missions: [first, second]) == ["!4101", "!4105", "!4106", "!4102"])
    }

    /// One that merged or closed waits for nothing, and nothing waits through it, as its order lets what comes after it
    /// merge once it merged: in !4801 → !4802 → !4803 with !4802 ended, !4801 doesn't take !4803's wait, nor count either
    /// among what builds on it.
    @Test func oneThatEndedInBetweenPassesNoWaitOn() {
        for (status, standing) in [(OrderStatus.merged, OrderStanding.merged), (.closed, .closed)] {
            let order = Self.mission([
                Self.step(4801, .next, place: 1), Self.step(4802, standing, status: status, place: 2, after: [4801]),
                Self.step(4803, .next, place: 3, after: [4802]),
            ])
            let asked = StageWhy.asked("Sam asked you")
            let stages: [Int: StageReading] = [
                4801: Self.reading(.yourReview, asked, at: 40), 4803: Self.reading(.yourReview, asked, at: 10),
            ]
            let cards = Self.board(stages, missions: [order]).lanes.first?.cards ?? []
            #expect(cards.first { $0.ref == Self.pr(4801) }?.waitingForIt == [], "\(status)")
            #expect(Self.column(.yourReview, stages, missions: [order]) == ["!4803", "!4801"], "\(status)")
        }
    }

    /// Only an open pull request its order numbers has a place in its merge order, among what's left to merge; one that
    /// merged, one that merges any time and one stacked with the order's have none. Each keeps its place in By Mission's
    /// list, for ties.
    @Test func onlyAnOpenOneItsOrderNumbersHasAPlaceInItsMergeOrder() {
        let order = Self.mission(
            [
                Self.step(4601, .merged, status: .merged, place: 1), Self.step(4602, .next, place: 2),
                Self.step(4603, .waiting(open: [Self.pr(4602)], unknown: []), place: 3, after: [4602]), Self.step(4604, .anyTime),
            ],
            attached: [Self.step(4605, .notInOrder)]
        )
        let places = PullRequestBoard.places(in: order)
        #expect(places.map(\.position) == [nil, 0, 1, nil, nil])
        #expect(places.map(\.listIndex) == [0, 1, 2, 3, 4])
    }

    @Test func teammatesReviewPutsFindAReviewerFirstThenTheEarliestInItsMissionsOrder() {
        // !4202 has waited longer, but its order merges !4201 first.
        let payments = Self.mission([
            Self.step(4074, .merged, status: .merged, place: 1), Self.step(4201, .next, place: 2),
            Self.step(4202, .waiting(open: [Self.pr(4201)], unknown: []), place: 3, after: [4201]),
        ])
        let stages: [Int: StageReading] = [
            4202: Self.reading(.teammateReview, .waitingFor("Waiting for Sam"), at: 1),
            4201: Self.reading(.teammateReview, .waitingFor("1 of 2 approvals"), at: 50),
            4101: Self.reading(.teammateReview, .waitingFor("Waiting for Priya"), at: 0),
            4102: Self.reading(.teammateReview, .findReviewer, at: 99),
        ]
        #expect(Self.column(.teammateReview, stages, missions: [payments]) == ["!4102", "!4201", "!4202", "!4101"])
    }

    @Test func canMergeIsNextToMergeThenAnyTimeThenTheRestTheOldestFirst() {
        let order = Self.mission([Self.step(4201, .next), Self.step(4202, .anyTime), Self.step(4203, .anyTime)])
        let ready = StageWhy.ready(autoComplete: false)
        let stages: [Int: StageReading] = [
            4101: Self.reading(.canMerge, ready, at: 0),
            4203: Self.reading(.canMerge, ready, at: 5),
            4202: Self.reading(.canMerge, .ready(autoComplete: true), at: 1),
            4201: Self.reading(.canMerge, ready, at: 99),
        ]
        #expect(Self.column(.canMerge, stages, missions: [order]) == ["!4201", "!4202", "!4203", "!4101"])
    }

    @Test func waitsIsTheOneClosestToMergingFirst() {
        let waits = { (refs: [Int]) in
            StageWhy.waitsFor(refs.map(Self.pr), words: "After " + refs.map { "!\($0)" }.joined(separator: " and "))
        }
        let stages: [Int: StageReading] = [
            4101: Self.reading(.canMerge, .ready(autoComplete: false)),
            4102: Self.reading(.teammateReview, .findReviewer),
            // Waits for one still in review: far.
            4201: Self.reading(.waits, waits([4102]), at: 0),
            // Waits for one that waits for one that can merge: two merges away.
            4202: Self.reading(.waits, waits([4203]), at: 1),
            // Waits for one that can merge: closest.
            4203: Self.reading(.waits, waits([4101]), at: 2),
            // Its order needs checking: last.
            4204: Self.reading(.waits, .orderHolds("!4100 was closed without merging: check the order"), at: 0),
        ]
        #expect(Self.column(.waits, stages) == ["!4203", "!4202", "!4201", "!4204"])
    }

    @Test func mergedIsTheLatestFirst() {
        let stages: [Int: StageReading] = [
            4101: Self.reading(.merged, .merged, at: 10), 4102: Self.reading(.merged, .merged, at: 30), 4103: Self.reading(.merged, .merged),
        ]
        #expect(Self.column(.merged, stages) == ["!4102", "!4101", "!4103"])
    }

    // MARK: Lanes and cards

    @Test func aLaneForEachMissionInByMissionsOrderThenTheRestAndEveryCardOnceInOne() {
        let first = Self.mission([Self.step(4101, .next), Self.step(4102, .waiting(open: [Self.pr(4101)], unknown: []))], focused: true)
        // !4102 is in two orders: it shows in both lanes, and counts once.
        let second = Self.mission([Self.step(4102, .next), Self.step(4103, .anyTime)])
        let review = Self.reading(.yourReview, .asked("Priya asked you"), at: 1)
        let stages: [Int: StageReading] = [
            4101: Self.reading(.inProgress, .draft, at: 1), 4102: review, 4103: review, 4200: review,
            // Someone else's that you finished reviewing is off your board.
            4300: Self.reading(.teammateReview, .finishedReview, isOnBoard: false),
        ]
        let board = Self.board(stages, missions: [first, second])
        #expect(board.lanes.map(\.kind) == [.mission(first.key), .mission(second.key), .notInAMission])
        #expect(board.lanes.map { $0.cards.map(\.ref.shortOrderLabel) } == [["!4101", "!4102"], ["!4102", "!4103"], ["!4200"]])
        #expect(board.counts[.yourReview] == 3)
        #expect(board.refs == [Self.pr(4101), Self.pr(4102), Self.pr(4103), Self.pr(4200)])
        #expect(board.notOnBoard([Self.pr(4101), Self.pr(4300), Self.pr(4301)]) == 2)
        #expect(BoardText.notOnBoard(2) == "2 more in your lists aren't on the board")
        #expect(BoardText.notOnBoard(1) == "1 more in your lists isn't on the board")
        #expect(BoardText.notOnBoard(0) == nil)

        // Each card's place is in its own lane's mission; Up Next takes each from the first mission that has it.
        #expect(board.lanes[1].cards(in: .yourReview).first?.mission == second.key)
        #expect(board.upNext.slots.first?.card.mission == first.key)

        let one = Self.board(stages, missions: [first, second], lanes: .none)
        #expect(one.lanes.map(\.kind) == [.all])
        #expect(one.lanes[0].cards.map(\.ref.shortOrderLabel) == ["!4101", "!4102", "!4103", "!4200"])
    }

    @Test func onlyThePagesKindsAndAMissionWithNoneOfThemHasNoLane() {
        let github = OrderMission(
            key: .stack(repository: "contoso/shop-web", number: 41), kind: .stack,
            steps: [OrderStep(ref: Self.gh(212), status: .open, standing: .next)], attached: [], cycles: [], isFocused: false,
            isFinished: false, isStale: false, attention: nil, date: nil, sessions: []
        )
        let board = PullRequestBoard.make(
            stages: [Self.gh(212): Self.reading(.yourReview, .asked("Priya asked you")), Self.pr(4101): Self.reading(.inProgress, .draft)],
            missions: [github], kinds: Self.kinds
        )
        #expect(board.lanes.map(\.kind) == [.notInAMission])
        #expect(board.refs == [Self.pr(4101)])
    }

    /// Up Next's pull request is the first in its column's order, across the lanes, whichever lane has it: the one that wears
    /// Next, though another lane above has a card in that column, and the first card with every card in one lane.
    @Test func upNextsPullRequestIsAlwaysTheFirstCardInItsColumnAcrossTheLanes() {
        let focused = Self.mission([Self.step(4201, .next), Self.step(4202, .waiting(open: [Self.pr(4201)], unknown: []))], focused: true)
        let other = Self.mission([Self.step(4301, .next), Self.step(4302, .anyTime), Self.step(4303)])
        let stages: [Int: StageReading] = [
            4201: Self.reading(.teammateReview, .waitingFor("Waiting for Sam"), at: 9),
            4202: Self.reading(.yourReview, .asked("Sam asked you"), at: 9),
            4203: Self.reading(.inProgress, .draft, at: 9),
            4301: Self.reading(.teammateReview, .findReviewer, at: 1),
            4302: Self.reading(.yourReview, .asked("Priya asked you"), at: 1),
            4303: Self.reading(.inProgress, .draft, at: 1),
            // In no mission, so in the last lane, but Fix next.
            4101: Self.reading(.inProgress, .failing("Build failed"), at: 5),
            4102: Self.reading(.yourReview, .asked("Priya asked you"), at: 0),
        ]
        // The other mission's lane is above the one you focus on, and the lane of those in no mission below both.
        let board = Self.board(stages, missions: [other, focused])
        let oneLane = Self.board(stages, missions: [other, focused], lanes: .none)
        #expect(board.lanes.map(\.kind) == [.mission(other.key), .mission(focused.key), .notInAMission])
        #expect(board.upNext == oneLane.upNext)
        #expect(board.upNext.slots.map(\.card.ref.shortOrderLabel) == ["!4101", "!4202", "!4201"])
        for slot in board.upNext.slots {
            #expect(oneLane.lanes.first?.cards(in: slot.kind.stage).first?.ref == slot.card.ref, "\(slot.kind)")
            #expect(board.next[slot.kind.stage] == slot.card.ref, "\(slot.kind)")
            // Whichever lane has it: not the top lane's first card in that column.
            #expect(board.lanes.first?.cards(in: slot.kind.stage).first?.ref != slot.card.ref, "\(slot.kind)")
        }
    }

    // MARK: A mission's next steps

    @Test func aMissionsNextStepsAreYoursAndWithNoneWhatItWaitsFor() {
        let payments = Self.mission([
            Self.step(4101, .next), Self.step(4102), Self.step(4103), Self.step(4104), Self.step(4105), Self.step(4106), Self.step(4107),
        ])
        let asking = StageSession(ref: Self.cart, activity: .waitsForYou, since: t(1))
        let stages: [Int: StageReading] = [
            4101: Self.reading(.canMerge, .ready(autoComplete: false)),
            4102: Self.reading(.teammateReview, .findReviewer),
            4103: Self.reading(.yourReview, .asked("Priya asked you")),
            4104: Self.reading(.inProgress, .failing("Build failed")),
            4105: Self.reading(.inProgress, .asksYou(asking)),
            // Not yours: completing by itself, waiting for Priya, and a session writing it.
            4106: Self.reading(.canMerge, .ready(autoComplete: true)),
            4107: Self.reading(.teammateReview, .waitingFor("Waiting for Priya")),
        ]
        let lane = Self.board(stages, missions: [payments]).lane(for: payments.key)
        let steps = lane?.nextSteps ?? []
        #expect(steps.map(\.title) == ["Answer !4105", "Fix !4104", "Review !4103", "Find a reviewer: !4102", "Complete !4101"])
        #expect(steps.map(\.stage) == [.inProgress, .inProgress, .yourReview, .teammateReview, .canMerge])
        #expect(lane?.waiting(name: Self.name) == nil)

        // !4092 has waited longer, but its order merges !4091 first.
        let waiting = Self.mission([
            Self.step(4091, .next, place: 1), Self.step(4092, .waiting(open: [Self.pr(4091)], unknown: []), place: 2, after: [4091]),
        ])
        let theirs: [Int: StageReading] = [
            4092: Self.reading(.waits, .waitsFor([Self.pr(4091)], words: "After !4091"), at: 0),
            4091: Self.reading(.teammateReview, .waitingFor("Waiting for Priya"), at: 50),
        ]
        let quiet = Self.board(theirs, missions: [waiting]).lane(for: waiting.key)
        #expect(quiet?.nextSteps.isEmpty == true)
        #expect(quiet?.waiting(name: Self.name) == "Waiting for Priya (!4091)")
    }

    // MARK: Moving a card

    static func card(
        _ stage: PullRequestStage, _ why: StageWhy, step: OrderStep? = nil
    ) -> BoardCard {
        BoardCard(ref: pr(4091), reading: reading(stage, why), mission: step.map { _ in .chain(pr(4091)) }, step: step)
    }

    @Test func dropsSetTheStagesYouCanSetAndRefuseTheRestSayingWhy() {
        let review = Self.card(.yourReview, .asked("Priya asked you"))
        #expect(BoardRules.move(review, to: .inProgress, isYours: true) == .setStage(.inProgress))
        #expect(BoardRules.move(review, to: .teammateReview, isYours: true) == .setStage(.teammateReview))
        #expect(BoardRules.move(review, to: .yourReview, isYours: true) == .stays)
        #expect(BoardRules.move(review, to: .canMerge, isYours: true)
            == .refused("Azure DevOps decides when it can merge: once it says it's ready to complete"))
        #expect(BoardRules.move(review, to: .waits, isYours: true) == .refused("Its order decides what it waits for"))
        #expect(BoardRules.move(review, to: .waits, isYours: true, missionChanges: true)
            == .refused("Its order decides what it waits for: Mission ▸ Merge After, in its menu"))
        #expect(BoardRules.move(review, to: .merged, isYours: true) == .refused("It merges in Azure DevOps: complete it there"))

        // Someone else's asks its own reviewers.
        #expect(BoardRules.move(review, to: .teammateReview, isYours: false, author: "Priya")
            == .refused("It's Priya's: they ask for its reviews. Finished My Review takes it off your board"))
        #expect(BoardRules.move(review, to: .teammateReview, isYours: false)
            == .refused("It's someone else's: they ask for its reviews. Finished My Review takes it off your board"))
        #expect(BoardRules.move(review, to: .inProgress, isYours: false) == .setStage(.inProgress))

        // What can merge goes back to review, as you say.
        let ready = Self.card(.canMerge, .ready(autoComplete: false))
        #expect(BoardRules.move(ready, to: .teammateReview, isYours: true) == .setStage(.teammateReview))

        // Merged stays, and another lane is Move to Mission's.
        let merged = Self.card(.merged, .merged)
        #expect(BoardRules.move(merged, to: .inProgress, isYours: true) == .refused("It merged: nothing changes its stage now"))
        #expect(BoardRules.move(merged, to: .merged, isYours: true) == .stays)
        #expect(BoardRules.move(review, to: .inProgress, sameLane: false, isYours: true)
            == .refused("A card moves between stages in its own mission's lane"))
        #expect(BoardRules.move(review, to: .inProgress, sameLane: false, isYours: true, missionChanges: true)
            == .refused("It goes in another mission with Mission ▸ Move to Mission, in its menu"))
        #expect(BoardMove.setStage(.inProgress).isTaken && BoardMove.setAsNext.isTaken)
        #expect(!BoardMove.stays.isTaken && !BoardMove.refused("No").isTaken)
    }

    /// The missions of these pull requests, with an order a session told of them, as By Mission has them.
    static func missions(_ pullRequests: [OrderPullRequest], plan entries: [OrderPlan.Entry]) -> [OrderMission] {
        let orders = DeclaredOrders(plans: [OrderPlan(id: PullRequestStageTests.planID, createdAt: t(0), updatedAt: t(0), entries: entries)])
        return OrderBoard.missions(facts: OrderFacts(pullRequests: pullRequests), orders: orders, evidence: OrderEvidence(), now: t(1_000))
    }

    static func waiting(_ number: Int, in missions: [OrderMission]) -> BoardCard {
        let step = missions.lazy.compactMap { $0.steps.first { $0.ref == pr(number) } ?? $0.attached.first { $0.ref == pr(number) } }.first
        let order = StageOrder.of(pr(number), in: missions)
        let why: StageWhy = switch order {
        case .waits(let refs, let words): .waitsFor(refs, words: words)
        case .holds(let words): .orderHolds(words)
        case .free: .ready(autoComplete: false)
        }
        return BoardCard(ref: pr(number), reading: reading(.waits, why), mission: missions.first?.key, step: step)
    }

    @Test func waitsOntoCanMergeSetsItAsNextToMergeUnlessItsStacked() {
        let free = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding"),
             OrderBoardTests.ado(4102, from: "robin/cart")],
            plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102), after: [Self.pr(4101)])]
        )
        let waits = Self.waiting(4102, in: free)
        #expect(free[0].whyNotNext(Self.pr(4102)) == nil)
        #expect(BoardRules.move(waits, to: .canMerge, isYours: true, missionChanges: true, missions: free) == .setAsNext)
        // Until you can change missions yourself, it says what it waits for.
        #expect(BoardRules.move(waits, to: .canMerge, isYours: true, missions: free)
            == .refused("It waits for !4101: it can merge once BriefBar sees it merge"))
    }

    /// Its order names only the nearest of what it waits for: one it's stacked on can hide behind another.
    @Test func aStackedBaseBehindAnotherPrerequisiteStillRefusesIt() {
        let missions = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/base"),
             OrderBoardTests.ado(4102, from: "robin/docs"),
             OrderBoardTests.ado(4103, from: "robin/top", into: "robin/base")],
            plan: [
                .init(ref: Self.pr(4101)), .init(ref: Self.pr(4102), after: [Self.pr(4101)]),
                .init(ref: Self.pr(4103), after: [Self.pr(4101), Self.pr(4102)]),
            ]
        )
        #expect(StageOrder.of(Self.pr(4103), in: missions) == .waits([Self.pr(4102)], words: "After !4102"))
        #expect(missions[0].stackedBases(of: Self.pr(4103)) == [Self.pr(4101)])
        #expect(BoardRules.move(Self.waiting(4103, in: missions), to: .canMerge, isYours: true, missionChanges: true, missions: missions)
            == .refused("Stacked on !4101: retarget it in Azure DevOps first"))
    }

    /// Its order puts it after one that comes after its base, so it names neither the base nor the branch: what its changes
    /// show against still does.
    @Test func aBaseItsOrderPutsBeforeItOnlyThroughAnotherStillRefusesIt() {
        let missions = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/base"),
             OrderBoardTests.ado(4102, from: "robin/docs"),
             OrderBoardTests.ado(4103, from: "robin/top", into: "robin/base")],
            plan: [
                .init(ref: Self.pr(4101)), .init(ref: Self.pr(4102), after: [Self.pr(4101)]),
                .init(ref: Self.pr(4103), after: [Self.pr(4102)]),
            ]
        )
        let step = missions[0].steps.first { $0.ref == Self.pr(4103) }
        #expect(step?.prerequisites.map(\.ref) == [Self.pr(4102)])
        #expect(step?.notes.contains { if case .orderDisagrees = $0 { true } else { false } } == false)
        #expect(missions[0].stackedBases(of: Self.pr(4103)) == [Self.pr(4101)])
        #expect(BoardRules.move(Self.waiting(4103, in: missions), to: .canMerge, isYours: true, missionChanges: true, missions: missions)
            == .refused("Stacked on !4101: retarget it in Azure DevOps first"))
    }

    @Test func oneStackedOnAnOrdersPullRequestThatItDoesntNameIsRefused() {
        let missions = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding"),
             OrderBoardTests.ado(4105, from: "robin/tests", into: "robin/rounding")],
            plan: [.init(ref: Self.pr(4101))]
        )
        #expect(missions[0].attached.map(\.ref) == [Self.pr(4105)])
        #expect(missions[0].whyNotNext(Self.pr(4105)) == "Stacked on !4101: retarget it in Azure DevOps first")
    }

    /// Its order doesn't put it after the branch it targets: BriefBar sees it stacked all the same.
    @Test func oneStackedOnABranchItsOrderDoesntSayIsRefused() {
        let missions = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding"),
             OrderBoardTests.ado(4102, from: "robin/cart"),
             OrderBoardTests.ado(4103, from: "robin/checkout", into: "robin/cart")],
            plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102)), .init(ref: Self.pr(4103), after: [Self.pr(4101)])]
        )
        #expect(missions[0].steps.first { $0.ref == Self.pr(4103) }?.notes.contains(.orderDisagrees(Self.pr(4102), .branch)) == true)
        #expect(missions[0].whyNotNext(Self.pr(4103)) == "Stacked on !4102: retarget it in Azure DevOps first")
    }

    @Test func oneThatStillTargetsAMergedBranchIsRetargetedFirstAndAMergedBaseHoldsNothing() {
        let stale = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding", state: .merged),
             OrderBoardTests.ado(4102, from: "robin/cart", into: "robin/rounding")],
            plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102), after: [Self.pr(4101)])]
        )
        #expect(stale[0].whyNotNext(Self.pr(4102)) == "!4101 merged: retarget it to main")

        let retargeted = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding", state: .merged),
             OrderBoardTests.ado(4102, from: "robin/cart")],
            plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102), after: [Self.pr(4101)])]
        )
        #expect(retargeted[0].stackedBases(of: Self.pr(4102)).isEmpty)
        #expect(retargeted[0].whyNotNext(Self.pr(4102)) == nil)
    }

    /// From Waits, ⌘← is Can merge, Set as Next to Merge's: what `move` takes or refuses, never a skip past it.
    @Test func theKeyboardMovesToTheNextOrPreviousStageYouCanSetElseSaysWhyNot() {
        let forward = PullRequestStage.columns.map { BoardRules.keyTarget(from: $0, forward: true) }
        let backward = PullRequestStage.columns.map { BoardRules.keyTarget(from: $0, forward: false) }
        #expect(forward == [.yourReview, .teammateReview, .canMerge, .waits, .merged, nil])
        #expect(backward == [nil, .inProgress, .yourReview, .teammateReview, .canMerge, .teammateReview])
        #expect(PullRequestStage.columns.map(\.columnTitle)
            == ["In progress", "Your review", "Teammate's review", "Can merge", "Waits", "Merged"])
    }

    // MARK: Undo, once a card leaves the board

    /// A mission's lane shows the Undo of a change to any of its pull requests, on the board or not, as List's card does.
    @Test func aMissionsLaneKeepsTheUndoOfOneThatLeftTheBoard() throws {
        let payments = Self.mission([Self.step(4201, .next), Self.step(4202)])
        let stages: [Int: StageReading] = [
            4201: Self.reading(.inProgress, .draft),
            4202: Self.reading(.teammateReview, .finishedReview, isOnBoard: false),
        ]
        let board = Self.board(stages, missions: [payments])
        let lane = try #require(board.lane(for: payments.key))
        #expect(lane.cards.map(\.ref) == [Self.pr(4201)])
        #expect(board.undoRefs(of: lane, missions: [payments], changed: Self.pr(4202)) == [Self.pr(4201), Self.pr(4202)])
        // Its lane has it: no other lane for it.
        #expect(board.lanes(keepingUndoOf: Self.pr(4202), missions: [payments]) == board.lanes)
    }

    /// One in no mission that left the board keeps the lane of those in no mission, though it was the only card there, or
    /// with every card in one lane, that lane, though the board is empty.
    @Test func oneInNoMissionThatLeftTheBoardKeepsALaneForItsUndo() {
        let payments = Self.mission([Self.step(4201, .next)])
        let stages: [Int: StageReading] = [
            4201: Self.reading(.inProgress, .draft),
            4088: Self.reading(.teammateReview, .finishedReview, isOnBoard: false),
        ]
        let board = Self.board(stages, missions: [payments])
        #expect(board.lanes.map(\.kind) == [.mission(payments.key)])
        let kept = board.lanes(keepingUndoOf: Self.pr(4088), missions: [payments])
        #expect(kept.map(\.kind) == [.mission(payments.key), .notInAMission])
        #expect(kept.last?.isEmpty == true)
        #expect(kept.last.map { board.undoRefs(of: $0, missions: [payments], changed: Self.pr(4088)) } == [Self.pr(4088)])
        // Not the mission's lane's, which doesn't have it.
        #expect(kept.first.map { board.undoRefs(of: $0, missions: [payments], changed: Self.pr(4088)) } == [Self.pr(4201)])

        // Where that lane has other cards, it keeps it beside them.
        var more = stages
        more[4089] = Self.reading(.yourReview, .asked("Sam asked you"))
        let board2 = Self.board(more, missions: [payments])
        #expect(board2.lanes(keepingUndoOf: Self.pr(4088), missions: [payments]) == board2.lanes)
        #expect(board2.lanes.last.map { board2.undoRefs(of: $0, missions: [payments], changed: Self.pr(4088)) }
            == [Self.pr(4089), Self.pr(4088)])

        // Every card in one lane, and none left.
        let empty = Self.board([4088: Self.reading(.teammateReview, .finishedReview, isOnBoard: false)], lanes: .none)
        #expect(empty.lanes.isEmpty)
        let one = empty.lanes(keepingUndoOf: Self.pr(4088), missions: [])
        #expect(one.map(\.kind) == [.all])
        #expect(one.first.map { empty.undoRefs(of: $0, missions: [], changed: Self.pr(4088)) } == [Self.pr(4088)])
    }

    @Test func onlyAChangeThatLeftThePagesBoardWithNoLaneGetsOne() {
        let board = Self.board([4101: Self.reading(.inProgress, .draft)])
        // On the board: its own lane shows it.
        #expect(board.lanes(keepingUndoOf: Self.pr(4101), missions: []) == board.lanes)
        // Another page's pull request, or none.
        #expect(board.lanes(keepingUndoOf: Self.gh(212), missions: []) == board.lanes)
        #expect(board.lanes(keepingUndoOf: nil, missions: []) == board.lanes)
        #expect(board.lanes.first.map { board.undoRefs(of: $0, missions: [], changed: Self.gh(212)) } == [Self.pr(4101)])
    }

    // MARK: Dragging

    /// A drop takes only what this drag carries: never text that names a pull request, such as from another app, nor
    /// another drag's.
    @Test func aDropTakesOnlyWhatThisDragCarries() {
        let drag = BoardDrag(ref: Self.pr(4093))
        #expect(drag.ref(dropped: drag.payload) == Self.pr(4093))
        #expect(drag.ref(dropped: Self.pr(4093).description) == nil)
        #expect(drag.ref(dropped: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/4093") == nil)
        #expect(drag.ref(dropped: BoardDrag(ref: Self.pr(4093)).payload) == nil)
        #expect(drag.payload != BoardDrag(ref: Self.pr(4093)).payload)
    }

    /// A card is found again as the board has it now: in the lane it's moved in where that lane has it, else in its own;
    /// none once it left the board.
    @Test func aCardIsFoundAgainInTheLaneItsMovedIn() {
        let first = Self.mission([Self.step(4101, .next), Self.step(4102, .waiting(open: [Self.pr(4101)], unknown: []))])
        let second = Self.mission([Self.step(4102, .next)])
        let board = Self.board(
            [4101: Self.reading(.inProgress, .draft), 4102: Self.reading(.yourReview, .asked("Sam asked you"))],
            missions: [first, second]
        )
        #expect(board.card(Self.pr(4102), preferring: .mission(second.key))?.mission == second.key)
        #expect(board.card(Self.pr(4102), preferring: .mission(first.key))?.mission == first.key)
        #expect(board.card(Self.pr(4101), preferring: .mission(second.key))?.mission == first.key)
        #expect(board.card(Self.pr(4999), preferring: .mission(first.key)) == nil)
    }

    // MARK: Words and choices

    @Test func aCardSaysWhoSetItsStageShortly() {
        let set = Self.reading(.teammateReview, .findReviewer, mark: StageMark(stage: .teammateReview, at: t(0)))
        #expect(BoardText.setter(set, now: t(7_200), name: Self.name) == "You · 2h")
        let bySession = Self.reading(.yourReview, .set, mark: StageMark(stage: .yourReview, at: t(0), by: Self.cart))
        #expect(BoardText.setter(bySession, now: t(300), name: Self.name) == "‘Cart’ · 5m")
        #expect(BoardText.setter(Self.reading(.yourReview, .asked("Priya asked you")), now: t(0), name: Self.name) == nil)
    }

    @Test func itRemembersTheLanesAndWhetherUpNextIsFolded() {
        let defaults = MemorySettings()
        #expect(BoardLanes.load(from: defaults) == .missions)
        BoardLanes.none.save(to: defaults)
        #expect(BoardLanes.load(from: defaults) == .none)
        #expect(defaults.string(forKey: "order.boardLanes") == "none")
        defaults.set("swimlanes", forKey: BoardLanes.defaultsKey)
        #expect(BoardLanes.load(from: defaults) == .missions)

        #expect(!UpNext.isFolded(in: defaults))
        UpNext.setFolded(true, in: defaults)
        #expect(UpNext.isFolded(in: defaults))
        #expect(defaults.bool(forKey: "order.upNextFolded"))
        UpNext.setFolded(false, in: defaults)
        #expect(defaults.object(forKey: UpNext.foldedKey) == nil)
    }

    @Test func theBoardIsAzureDevOpsPagesAndGitHubsShowsListWhereYouChoseIt() {
        let azure = OrderView.offered(for: [.pullRequest])
        let github = OrderView.offered(for: [.gitHubPullRequest])
        #expect(azure == [.list, .map, .board])
        #expect(github == [.list, .map])
        #expect(OrderView.board.shown(offering: github) == .list)
        #expect(OrderView.map.shown(offering: github) == .map)
        #expect(OrderView.board.shown(offering: azure) == .board)
    }
}
