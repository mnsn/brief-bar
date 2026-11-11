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
        _ stages: [Int: StageReading], missions: [OrderMission] = [], lanes: BoardLanes = .missions, picks: UpNextPicks = UpNextPicks()
    ) -> PullRequestBoard {
        PullRequestBoard.make(stages: refs(stages), missions: missions, kinds: kinds, lanes: lanes, picks: picks)
    }

    /// The numbers of a column's cards, in their order, across the board as Lanes: None has them.
    static func column(
        _ stage: PullRequestStage, _ stages: [Int: StageReading], missions: [OrderMission] = [], picks: UpNextPicks = UpNextPicks()
    ) -> [String] {
        board(stages, missions: missions, lanes: .none, picks: picks).lanes.first?.cards(in: stage).map(\.ref.shortOrderLabel) ?? []
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
        #expect(UpNextSlot.allCases.map(\.title) == [
            "Fix next", "Your next review", "Next for a teammate", "Approved next", "Merge next", "Waits next",
        ])

        // Up Next's pull request wears Next in its column; a session writing one isn't yours to do, so In progress's Next
        // is Fix next's, ahead of it.
        #expect(board.next[.fix] == Self.pr(4131))
        #expect(board.next[.teammateReview] == Self.pr(4079))
        #expect(board.next[.approved] == nil)
        #expect(Self.column(.inProgress, stages, missions: [payments]) == ["!4131", "!4102"])
        #expect(board.counts == [.inProgress: 2, .yourReview: 2, .teammateReview: 2, .canMerge: 1, .waits: 1, .merged: 1])
    }

    @Test func withNothingNextItSaysSoAndASessionWritingItIsntFixNext() {
        let writing = Self.reading(.inProgress, .working(StageSession(ref: Self.cart, activity: .working, since: t(10))))
        let board = Self.board([4102: writing, 4104: Self.reading(.inProgress, .draft), 4105: Self.reading(.inProgress, .left("Build running"))])
        #expect(board.upNext.isEmpty)
        #expect(board.next[.fix] == nil)
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

    static func flagged(_ stage: PullRequestStage, _ why: StageWhy, at seconds: TimeInterval, _ flags: [StageFlag]) -> StageReading {
        var reading = reading(stage, why, at: seconds)
        reading.flags = flags
        return reading
    }

    /// Fix next has what needs you from every column, as its flags say, saying what and where; one in Your review stays
    /// your next review too, wearing both on the Board; one a session writes isn't there, as it may be fixing just that.
    /// Approved next has the approved ones, the earliest in their mission's order first.
    @Test func fixNextHasWhatNeedsYouFromEveryColumnAndApprovedNextWhatsApproved() throws {
        let writing = StageSession(ref: Self.cart, activity: .working, since: t(5))
        let checkout = Self.mission([
            Self.step(4087, .next, place: 1), Self.step(4088, .waiting(open: [Self.pr(4087)], unknown: []), place: 2, after: [4087]),
        ])
        let stages: [Int: StageReading] = [
            4088: Self.flagged(.approved, .approvedBy("Maria"), at: 10, [.failing("Build failed")]),
            4087: Self.flagged(.approved, .left("Build running"), at: 30, []),
            4093: Self.flagged(.yourReview, .awaitsYourReview, at: 20, [.failing("Merge conflicts")]),
            3990: Self.flagged(.teammateReview, .waitingFor("Waiting on Priya"), at: 0, [.working(writing), .failing("Build expired")]),
            4079: Self.flagged(.teammateReview, .waitingFor("Waiting on Chen"), at: 50, [.changesWanted("Chen wants changes")]),
        ]
        let board = Self.board(stages, missions: [checkout])
        let slots = Dictionary(uniqueKeysWithValues: board.upNext.slots.map { ($0.kind, $0) })
        #expect(board.upNext.slots.map(\.kind) == [.fix, .yourReview, .teammateReview, .approved])
        #expect(slots[.fix]?.cards.map(\.ref.shortOrderLabel) == ["!4088", "!4093", "!4079"])
        #expect(slots[.yourReview]?.card.ref == Self.pr(4093))
        #expect(slots[.approved]?.cards.map(\.ref.shortOrderLabel) == ["!4087", "!4088"])
        #expect(board.next == [.fix: Self.pr(4088), .yourReview: Self.pr(4093), .teammateReview: Self.pr(3990), .approved: Self.pr(4087)])
        #expect(stages[3990]?.fixRank == nil)

        let fix = try #require(stages[4088])
        #expect(StageText.fixWords(fix, name: Self.name) == "Build failed · in Approved")
        #expect(StageText.why(fix, name: Self.name) == "Maria approved it · build failed")
        #expect(StageText.fixWords(Self.reading(.inProgress, .failing("Build failed")), name: Self.name) == "Build failed")

        // Fix next's pick stands while it needs you, or a session writes it, in any column but Merged.
        #expect(UpNextSlot.fix.keeps(stages[4093]) && UpNextSlot.fix.keeps(stages[3990]))
        #expect(!UpNextSlot.fix.has(stages[3990]) && !UpNextSlot.fix.keeps(stages[4087]))
        #expect(!UpNextSlot.fix.keeps(Self.reading(.merged, .merged)))
        // Make Next on a card chooses its column's slot.
        #expect(UpNextSlot.of(BoardCard(ref: Self.pr(4088), reading: fix)) == .approved)
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
        #expect(board.next[.fix] == Self.pr(4101))
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

    /// One for an order's story that the order doesn't name is in that order's lane, as its card in List lists it apart, but
    /// with no place there: no order puts it anywhere.
    @Test func oneForAnOrdersStoryThatItDoesntNameIsInItsLaneWithNoPlace() throws {
        var order = Self.mission([
            Self.step(4101, .next, place: 1), Self.step(4102, .waiting(open: [Self.pr(4101)], unknown: []), place: 2, after: [4101]),
        ])
        order.sameStory = [Self.step(4120, .notInOrder)]
        let review = Self.reading(.yourReview, .asked("Priya asked you"), at: 1)
        let board = Self.board([4101: review, 4102: review, 4120: review], missions: [order])
        #expect(board.lanes.map(\.kind) == [.mission(order.key)])
        #expect(Set(board.lanes[0].cards.map(\.ref)) == [Self.pr(4101), Self.pr(4102), Self.pr(4120)])
        let card = try #require(board.lanes[0].cards.first { $0.ref == Self.pr(4120) })
        #expect(card.mission == order.key)
        #expect(card.position == nil)
        #expect(card.listIndex == 2)
        #expect(board.lanes[0].cards.compactMap(\.position).sorted() == [0, 1])
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
            #expect(board.next[slot.kind] == slot.card.ref, "\(slot.kind)")
            // Whichever lane has it: not the top lane's first card in that column.
            #expect(board.lanes.first?.cards(in: slot.kind.stage).first?.ref != slot.card.ref, "\(slot.kind)")
        }
    }

    // MARK: The one you choose

    /// What needs you to fix: a session that asks you, a failed build and changes wanted, which come in that order; and a
    /// draft, which isn't Fix next's.
    static let fixes: [Int: StageReading] = [
        4101: reading(.inProgress, .failing("Build failed"), at: 5),
        4102: reading(.inProgress, .changesWanted("Priya wants changes"), at: 1),
        4103: reading(.inProgress, .asksYou(StageSession(ref: cart, activity: .waitsForYou, since: t(9))), at: 9),
        4104: reading(.inProgress, .draft, at: 0),
    ]

    /// The user's own example, smaller: of those to fix, the one they know is most urgent, which BriefBar's order puts last.
    /// It's Fix next's, with every other one to choose from in their order after it, and first in In progress, wearing Next
    /// as yours; and in Your review, ahead of the mission you focus on, first in its own mission's lane, and in each lane
    /// that has it, in two missions.
    @Test func theOneYouChooseIsItsSlotsPullRequestFirstInItsColumnInEveryLane() {
        #expect(Self.column(.inProgress, Self.fixes) == ["!4103", "!4101", "!4102", "!4104"])
        let unpicked = Self.board(Self.fixes)
        #expect(unpicked.upNext.slots.first?.isPicked == false)
        #expect(unpicked.picked.isEmpty)

        let picks = UpNextPicks([.fix: Self.pr(4102)])
        let board = Self.board(Self.fixes, picks: picks)
        let fix = board.upNext.slots.first
        #expect(fix?.kind == .fix)
        #expect(fix?.card.ref == Self.pr(4102))
        #expect(fix?.isPicked == true)
        #expect(fix?.cards.map(\.ref.shortOrderLabel) == ["!4102", "!4103", "!4101"])
        #expect(fix?.count == 3 && fix?.more == "2 more")
        #expect(board.next[.fix] == Self.pr(4102))
        #expect(board.picked == [.fix: Self.pr(4102)])
        #expect(Self.column(.inProgress, Self.fixes, picks: picks) == ["!4102", "!4103", "!4101", "!4104"])

        let focused = Self.mission([Self.step(4202)], focused: true)
        let other = Self.mission([Self.step(4302)])
        let reviews: [Int: StageReading] = [
            4202: Self.reading(.yourReview, .asked("Sam asked you"), at: 1),
            4302: Self.reading(.yourReview, .asked("Priya asked you"), at: 9),
        ]
        let review = UpNextPicks([.yourReview: Self.pr(4302)])
        let lanes = Self.board(reviews, missions: [focused, other], picks: review)
        #expect(Self.column(.yourReview, reviews, missions: [focused, other]) == ["!4202", "!4302"])
        #expect(Self.column(.yourReview, reviews, missions: [focused, other], picks: review) == ["!4302", "!4202"])
        #expect(lanes.upNext.slots.map(\.card.ref) == [Self.pr(4302)])
        #expect(lanes.next[.yourReview] == Self.pr(4302))
        #expect(lanes.lane(for: other.key)?.cards(in: .yourReview).first?.ref == Self.pr(4302))
        #expect(lanes.lane(for: focused.key)?.cards(in: .yourReview).first?.ref == Self.pr(4202))

        // In two missions, it's first in each lane that has it, and the next step there.
        let payments = Self.mission([Self.step(4301), Self.step(4302)])
        let checkout = Self.mission([Self.step(4303), Self.step(4302)])
        let shared: [Int: StageReading] = [
            4301: Self.reading(.yourReview, .asked("Sam asked you"), at: 1),
            4302: Self.reading(.yourReview, .asked("Priya asked you"), at: 9),
            4303: Self.reading(.yourReview, .asked("Kai asked you"), at: 2),
        ]
        let twice = Self.board(shared, missions: [payments, checkout], picks: review)
        #expect(twice.lane(for: payments.key)?.cards(in: .yourReview).map(\.ref) == [Self.pr(4302), Self.pr(4301)])
        #expect(twice.lane(for: checkout.key)?.cards(in: .yourReview).map(\.ref) == [Self.pr(4302), Self.pr(4303)])
        #expect(twice.lane(for: checkout.key)?.nextSteps.map(\.title) == ["Review !4302", "Review !4303"])
    }

    /// One its slot doesn't have, as In progress without needing you, in another stage or not on the board, changes
    /// nothing: what needs you still comes first, and BriefBar's order chooses.
    @Test func aChoiceItsSlotDoesntHaveChangesNothing() {
        var stages = Self.fixes
        stages[4201] = Self.reading(.teammateReview, .findReviewer, at: 1)
        let plain = Self.board(stages)
        for pick in [Self.pr(4104), Self.pr(4201), Self.pr(4999)] {
            let board = Self.board(stages, picks: UpNextPicks([.fix: pick, .yourReview: pick]))
            #expect(board == plain, "\(pick)")
        }
        // Each pull request is in one slot at most: Make Next chooses it there.
        let cards = Self.board(stages, lanes: .none).lanes.first?.cards ?? []
        let slots = Dictionary(uniqueKeysWithValues: cards.map { ($0.ref.shortOrderLabel, UpNextSlot.of($0)) })
        #expect(slots == ["!4101": .fix, "!4102": .fix, "!4103": .fix, "!4104": nil, "!4201": .teammateReview])
    }

    /// A choice stands while its pull request does, where you chose it; Fix next's waits while a session writes it, as it
    /// may be fixing just that. Once its pull request has been away for half an hour, in another stage, off
    /// your board, merged or closed, the choice goes, whether it's back by then or not, as when the Mac wakes; back sooner,
    /// as when Sam pushes again just after you finished reviewing it, it's still yours.
    @Test func aChoiceStandsUntilItsPullRequestMovesOn() {
        var picks = UpNextPicks([
            .fix: Self.pr(4101), .yourReview: Self.pr(4202), .teammateReview: Self.pr(4301), .canMerge: Self.pr(4120),
            .waits: Self.pr(4091),
        ])
        // Its source reads each, though no list has !4120, which closed.
        let known = Set(picks.refs.values)
        var readings: [ItemRef: StageReading] = [
            Self.pr(4101): Self.reading(.inProgress, .working(StageSession(ref: Self.cart, activity: .working, since: t(0)))),
            Self.pr(4202): Self.reading(.teammateReview, .finishedReview, isOnBoard: false),
            Self.pr(4301): Self.reading(.canMerge, .ready(autoComplete: false)),
            Self.pr(4091): Self.reading(.merged, .merged),
        ]
        var away: [UpNextSlot: UpNextPicks.Away] = [:]
        func moved(at seconds: TimeInterval) -> Set<UpNextSlot> {
            let moved = picks.moved(by: readings, known: known, away: &away, now: t(seconds))
            for slot in moved { picks[slot] = nil }
            return moved
        }
        #expect(moved(at: 0).isEmpty)
        #expect(away.mapValues(\.since) == [.yourReview: t(0), .teammateReview: t(0), .canMerge: t(0), .waits: t(0)])
        #expect(away[.yourReview]?.ref == Self.pr(4202))

        readings[Self.pr(4202)] = Self.reading(.yourReview, .asked("New commits by Sam"))
        #expect(moved(at: UpNextPicks.awayFor - 1).isEmpty)
        #expect(away[.yourReview] == nil && away[.canMerge]?.since == t(0))
        #expect(moved(at: UpNextPicks.awayFor) == [.teammateReview, .canMerge, .waits])
        #expect(away.isEmpty)
        #expect(picks == UpNextPicks([.fix: Self.pr(4101), .yourReview: Self.pr(4202)]))

        // You finish it again, and it's back only an hour later.
        readings[Self.pr(4202)] = Self.reading(.teammateReview, .finishedReview, isOnBoard: false)
        #expect(moved(at: 2_000).isEmpty)
        readings[Self.pr(4202)] = Self.reading(.yourReview, .asked("New commits by Sam"))
        #expect(moved(at: 5_600) == [.yourReview])
        #expect(picks == UpNextPicks([.fix: Self.pr(4101)]))

        #expect(UpNextSlot.fix.keeps(readings[Self.pr(4101)]))
        #expect(!UpNextSlot.fix.has(readings[Self.pr(4101)]))
        #expect(UpNextSlot.fix.has(Self.fixes[4101]))
        #expect(!UpNextSlot.fix.has(nil))
        // Once nothing needs you there, and no session writes it, as once its build passed, it's moved on.
        #expect(!UpNextSlot.fix.keeps(Self.reading(.inProgress, .left("Build running"))))
    }

    /// One whose source can't tell where it is now, such as before Azure DevOps has read the lists of its organization, or
    /// while it's off, is neither away nor back, and waits, however long. One seen away before is still away since then.
    /// What was noted of a slot you chose another for is forgotten.
    @Test func aChoiceWaitsWhileItsSourceReadsNothingOfIt() {
        let picks = UpNextPicks([.fix: Self.pr(4101), .yourReview: Self.pr(4202)])
        let both: Set<ItemRef> = [Self.pr(4101), Self.pr(4202)]
        let readings: [ItemRef: StageReading] = [
            Self.pr(4101): Self.reading(.inProgress, .failing("Build failed")),
            Self.pr(4202): Self.reading(.teammateReview, .finishedReview, isOnBoard: false),
        ]
        var away: [UpNextSlot: UpNextPicks.Away] = [.fix: UpNextPicks.Away(ref: Self.pr(4999), since: t(0))]
        #expect(picks.moved(by: [:], known: [], away: &away, now: t(0)).isEmpty)
        #expect(away.isEmpty)

        #expect(picks.moved(by: readings, known: both, away: &away, now: t(0)).isEmpty)
        #expect(away.mapValues(\.since) == [.yourReview: t(0)])
        #expect(picks.moved(by: [:], known: [], away: &away, now: t(3_600)).isEmpty)
        #expect(away.mapValues(\.since) == [.yourReview: t(0)])
        #expect(picks.moved(by: readings, known: both, away: &away, now: t(3_601)) == [.yourReview])
        #expect(away.isEmpty)
    }

    /// What BriefBar keeps of what you chose: for each account, by its name in lowercase, each slot's pull request with
    /// when a list last had it, a record each; of what another program or an earlier build wrote, only the records it can
    /// read, each alone.
    @Test func itRemembersWhatEachAccountChoseAndReadsOnlyWhatItCan() throws {
        let defaults = MemorySettings()
        #expect(UpNextPicks.Kept.load(from: defaults).isEmpty)
        var kept = UpNextPicks.Kept()
        kept.set(UpNextPicks([.fix: Self.pr(4101), .yourReview: Self.pr(4202)]), for: "Robin@contoso.com", at: t(0))
        kept.set(UpNextPicks([.fix: Self.pr(4103)]), for: "sam@contoso.com", at: t(60))
        #expect(kept.picks(for: "robin@contoso.com") == UpNextPicks([.fix: Self.pr(4101), .yourReview: Self.pr(4202)]))
        #expect(kept.picks(for: "SAM@contoso.com") == UpNextPicks([.fix: Self.pr(4103)]))
        #expect(kept.picks(for: "kai@contoso.com").isEmpty)
        kept.save(to: defaults)
        let data = try #require(defaults.data(forKey: "order.upNextPicks"))
        let saved = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(saved.map { $0["account"] as? String } == ["robin@contoso.com", "robin@contoso.com", "sam@contoso.com"])
        #expect(saved.map { $0["slot"] as? String } == ["fix", "yourReview", "fix"])
        #expect(saved.map { $0["pullRequest"] as? String } == ["pullRequest/contoso/4101", "pullRequest/contoso/4202", "pullRequest/contoso/4103"])
        #expect(saved.allSatisfy { Set($0.keys) == ["account", "slot", "pullRequest", "listedAt"] })
        #expect(UpNextPicks.Kept.load(from: defaults) == kept)

        // Only the pull requests of slots it knows, with an account; one that isn't a pull request doesn't take its slot.
        defaults.set(Data(#"""
        [{"account":"Robin@contoso.com","slot":"fix","pullRequest":"pullRequest/contoso/4101","listedAt":0},
         {"account":"robin@contoso.com","slot":"later","pullRequest":"pullRequest/contoso/1","listedAt":0},
         {"account":"robin@contoso.com","slot":"waits","pullRequest":"workItem/contoso/5","listedAt":0},
         {"account":"robin@contoso.com","slot":"yourReview","pullRequest":42,"listedAt":0},
         {"slot":"canMerge","pullRequest":"pullRequest/contoso/4120","listedAt":0},
         {"account":"robin@contoso.com","slot":"fix","pullRequest":"pullRequest/contoso/4102","listedAt":0},
         {"account":"robin@contoso.com","slot":"waits","pullRequest":"pullRequest/contoso/4140","listedAt":0}]
        """#.utf8), forKey: UpNextPicks.Kept.defaultsKey)
        #expect(UpNextPicks.Kept.load(from: defaults) == UpNextPicks.Kept(accounts: [
            "robin@contoso.com": [
                .fix: .init(ref: Self.pr(4101), listedAt: Date(timeIntervalSinceReferenceDate: 0)),
                .waits: .init(ref: Self.pr(4140), listedAt: Date(timeIntervalSinceReferenceDate: 0)),
            ],
        ]))
        // An earlier build's, each slot's reference alone, and what isn't a list.
        defaults.set(Data(#"{"fix":"pullRequest/contoso/4101"}"#.utf8), forKey: UpNextPicks.Kept.defaultsKey)
        #expect(UpNextPicks.Kept.load(from: defaults).isEmpty)
        defaults.set(Data("[".utf8), forKey: UpNextPicks.Kept.defaultsKey)
        #expect(UpNextPicks.Kept.load(from: defaults).isEmpty)

        UpNextPicks.Kept().save(to: defaults)
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
    }

    /// What an account chose keeps when a list last had each, as the stages you set do: choosing another for a slot notes it
    /// then, a list that has one notes it at most once a day, and one no list has had for 30 days goes, with any account.
    /// Turning a source off forgets its own; none chosen keeps nothing for the account.
    @Test func whatEachAccountChoseGoesOnceNoListHasHadItFor30Days() {
        var kept = UpNextPicks.Kept()
        kept.set(UpNextPicks([.fix: Self.pr(4101), .yourReview: Self.pr(4202)]), for: "robin@contoso.com", at: t(0))
        kept.set(UpNextPicks([.canMerge: Self.gh(12)]), for: "sam@contoso.com", at: t(0))
        kept.set(UpNextPicks([.fix: Self.pr(4101), .yourReview: Self.pr(4203)]), for: "robin@contoso.com", at: t(3_600))
        #expect(kept.accounts["robin@contoso.com"]?[.fix]?.listedAt == t(0))
        #expect(kept.accounts["robin@contoso.com"]?[.yourReview] == UpNextPicks.Kept.Entry(ref: Self.pr(4203), listedAt: t(3_600)))

        let tooSoon = kept.listed([Self.pr(4101)], for: "robin@contoso.com", at: t(3_600))
        let aDayLater = kept.listed([Self.pr(4101), Self.gh(12)], for: "Robin@contoso.com", at: t(86_400))
        #expect(!tooSoon && aDayLater)
        #expect(kept.accounts["robin@contoso.com"]?[.fix]?.listedAt == t(86_400))
        #expect(kept.accounts["sam@contoso.com"]?[.canMerge]?.listedAt == t(0))
        let anotherAccount = kept.listed([Self.pr(4101)], for: "kai@contoso.com", at: t(2 * 86_400))
        #expect(!anotherAccount)

        let notYet = kept.forgetUnlisted(now: t(UpNextPicks.Kept.unlistedFor), of: [.pullRequest, .gitHubPullRequest])
        // Only of the kinds whose sources have listed since: GitHub's waits till it has.
        let azureDevOpsOnes = kept.forgetUnlisted(now: t(3_601 + UpNextPicks.Kept.unlistedFor), of: [.pullRequest])
        #expect(kept.picks(for: "sam@contoso.com") == UpNextPicks([.canMerge: Self.gh(12)]))
        let then = kept.forgetUnlisted(now: t(3_601 + UpNextPicks.Kept.unlistedFor), of: [.pullRequest, .gitHubPullRequest])
        #expect(!notYet && azureDevOpsOnes && then)
        #expect(kept == UpNextPicks.Kept(accounts: ["robin@contoso.com": [.fix: .init(ref: Self.pr(4101), listedAt: t(86_400))]]))

        kept.set(UpNextPicks([.fix: Self.pr(4101), .canMerge: Self.gh(12)]), for: "robin@contoso.com", at: t(90_000))
        let forgot = kept.forget([.gitHubPullRequest])
        let again = kept.forget([.gitHubPullRequest])
        #expect(forgot && !again)
        #expect(kept.picks(for: "robin@contoso.com") == UpNextPicks([.fix: Self.pr(4101)]))
        kept.set(UpNextPicks(), for: "robin@contoso.com", at: t(90_000))
        #expect(kept.isEmpty)
        #expect(UpNextPicks.Kept(accounts: ["robin@contoso.com": [.fix: .init(ref: .workItem(organization: "contoso", id: 5), listedAt: t(0))]]).isEmpty)
    }

    @Test func choicesSplitMergeAndForgetASourcesOwn() {
        var picks = UpNextPicks([.fix: Self.pr(4101), .canMerge: Self.gh(12)])
        picks[.waits] = .workItem(organization: "contoso", id: 5)
        #expect(picks[.waits] == nil)
        #expect(picks.first(in: .inProgress) == Self.pr(4101))
        #expect(picks.first(in: .merged) == nil)
        let (sent, kept) = picks.split { $0 == Self.pr(4101) }
        #expect(sent == UpNextPicks([.fix: Self.pr(4101)]))
        #expect(kept == UpNextPicks([.canMerge: Self.gh(12)]))
        #expect(kept.merging(sent) == picks)
        #expect(UpNextPicks([.fix: Self.pr(4102)]).merging(sent)[.fix] == Self.pr(4102))
        let forgot = picks.forget([.gitHubPullRequest])
        let again = picks.forget([.gitHubPullRequest])
        #expect(forgot && !again)
        #expect(picks == UpNextPicks([.fix: Self.pr(4101)]))
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

    /// A mission's next step for one of its cards: a session that asks you first, wherever it is; then its column's own, a
    /// review whatever its build; then what to fix.
    @Test func aMissionsNextStepIsAnAnswerThenItsColumnsThenAFix() {
        let asking = StageSession(ref: Self.cart, activity: .waitsForYou, since: t(1))
        func step(_ reading: StageReading) -> String? {
            MissionNextStep.of(BoardCard(ref: Self.pr(4093), reading: reading))?.title
        }
        #expect(step(Self.flagged(.yourReview, .awaitsYourReview, at: 0, [.failing("Build failed")])) == "Review !4093")
        #expect(step(Self.flagged(.approved, .approvedBy("Maria"), at: 0, [.failing("Build failed")])) == "Fix !4093")
        #expect(step(Self.flagged(.teammateReview, .findReviewer, at: 0, [.changesWanted("Sam wants changes")])) == "Find a reviewer: !4093")
        #expect(step(Self.flagged(.teammateReview, .waitingFor("Waiting on Sam"), at: 0, [.changesWanted("Sam wants changes")]))
            == "Fix !4093")
        #expect(step(Self.flagged(.yourReview, .awaitsYourReview, at: 0, [.asksYou(asking)])) == "Answer !4093")
        #expect(step(Self.flagged(.approved, .left("Build running"), at: 0, [])) == nil)
    }

    /// Of its next steps of one kind, the one you chose for Up Next's slot comes first, as it does in its column; a session
    /// that asks you is still Answer, before what to fix. What to fix comes as Fix next has it, from every column: the one
    /// you chose for Fix next first, then what failed, then changes someone wants, the oldest first.
    @Test func aMissionsNextStepsPutTheOneYouChoseFirst() {
        let payments = Self.mission([Self.step(4101), Self.step(4102), Self.step(4103), Self.step(4104)])
        func titles(_ picks: UpNextPicks, _ stages: [Int: StageReading] = Self.fixes, in mission: OrderMission? = nil) -> [String] {
            let mission = mission ?? payments
            return Self.board(stages, missions: [mission], picks: picks).lane(for: mission.key)?.nextSteps.map(\.title) ?? []
        }
        #expect(titles(UpNextPicks()) == ["Answer !4103", "Fix !4101", "Fix !4102"])
        #expect(titles(UpNextPicks([.fix: Self.pr(4102)])) == ["Answer !4103", "Fix !4102", "Fix !4101"])

        // Two approved whose builds failed: the one you chose for Fix next is its next fix, as it's Up Next's, while the
        // Approved column keeps the one you chose for Approved next first.
        var approved = Self.fixes
        approved[4105] = Self.flagged(.approved, .approvedBy("Maria"), at: 3, [.failing("Build failed")])
        approved[4106] = Self.flagged(.approved, .approvedBy("Sam"), at: 4, [.failing("Build failed")])
        let shop = Self.mission([4101, 4102, 4103, 4104, 4105, 4106].map { Self.step($0) })
        #expect(titles(UpNextPicks(), approved, in: shop) == ["Answer !4103", "Fix !4105", "Fix !4106", "Fix !4101", "Fix !4102"])
        let picks = UpNextPicks([.fix: Self.pr(4106), .approved: Self.pr(4105)])
        let chosen = Self.board(approved, missions: [shop], picks: picks)
        #expect(chosen.next[.fix] == Self.pr(4106))
        #expect(chosen.lane(for: shop.key)?.nextSteps.map(\.title)
            == ["Answer !4103", "Fix !4106", "Fix !4105", "Fix !4101", "Fix !4102"])
        #expect(chosen.lane(for: shop.key)?.cards(in: .approved).map(\.ref) == [Self.pr(4105), Self.pr(4106)])
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
        #expect(BoardRules.move(review, to: .approved, isYours: true)
            == .refused("Azure DevOps decides when it's approved: once the reviewers it requires approve"))
        let approved = Self.card(.approved, .approvedBy("Maria"))
        #expect(BoardRules.move(approved, to: .teammateReview, isYours: true) == .setStage(.teammateReview))
        #expect(BoardRules.move(approved, to: .canMerge, isYours: true)
            == .refused("Azure DevOps decides when it can merge: once it says it's ready to complete"))

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
        #expect(BoardMove.setStage(.inProgress).isTaken && BoardMove.setAsNext(.plan(PullRequestStageTests.planID)).isTaken)
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
        #expect(BoardRules.move(waits, to: .canMerge, isYours: true, missionChanges: true, missions: free) == .setAsNext(free[0].key))
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

    /// Its order puts it after one that comes after its base, without naming the base: its branch still puts it after the
    /// base, and what its changes show against still refuses it.
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
        #expect(step?.prerequisites.map(\.ref) == [Self.pr(4102), Self.pr(4101)])
        #expect(step?.prerequisites.last?.origins == [.branch])
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
        #expect(forward == [.yourReview, .teammateReview, .approved, .canMerge, .waits, .merged, nil])
        #expect(backward == [nil, .inProgress, .yourReview, .teammateReview, .teammateReview, .canMerge, .teammateReview])
        #expect(PullRequestStage.columns.map(\.columnTitle)
            == ["In progress", "Your review", "Teammate's review", "Approved", "Can merge", "Waits", "Merged"])
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

    /// So does a lane of one for its story apart from its order, such as a teammate's whose review you finished.
    @Test func aMissionsLaneKeepsTheUndoOfOneForItsStoryApartFromItsOrderThatLeftTheBoard() throws {
        var payments = Self.mission([Self.step(4201, .next)])
        payments.sameStory = [Self.step(4202)]
        let stages: [Int: StageReading] = [
            4201: Self.reading(.inProgress, .draft),
            4202: Self.reading(.teammateReview, .finishedReview, isOnBoard: false),
        ]
        let board = Self.board(stages, missions: [payments])
        let lane = try #require(board.lane(for: payments.key))
        #expect(lane.cards.map(\.ref) == [Self.pr(4201)])
        #expect(board.undoRefs(of: lane, missions: [payments], changed: Self.pr(4202)) == [Self.pr(4201), Self.pr(4202)])
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
        let bySession = Self.reading(.teammateReview, .findReviewer, mark: StageMark(stage: .teammateReview, at: t(0), by: Self.cart))
        #expect(BoardText.setter(bySession, now: t(300), name: Self.name) == "‘Cart’ · 5m")
        // Where why it's in its stage, on the card above, names the session, only when: "‘Cart’ says it's ready".
        let ready = Self.reading(.yourReview, .set, mark: StageMark(stage: .yourReview, at: t(0), by: Self.cart))
        #expect(BoardText.setter(ready, now: t(300), name: Self.name) == "set 5m ago")
        #expect(BoardText.setter(Self.reading(.yourReview, .asked("Priya asked you")), now: t(0), name: Self.name) == nil)
        // Where a session's replaced yours, as its row, details, tooltip and VoiceOver say too.
        let yours = StageMark(stage: .teammateReview, at: t(-60))
        var replacing = ready
        replacing.replaced = yours
        #expect(BoardText.setter(replacing, now: t(300), name: Self.name) == "set 5m ago, after you")
        var replacingTitled = bySession
        replacingTitled.replaced = StageMark(stage: .yourReview, at: t(-60))
        #expect(BoardText.setter(replacingTitled, now: t(300), name: Self.name) == "‘Cart’ · 5m, after you")
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

    // MARK: Folding columns

    /// The Board's columns on My Work with + Sprint Tasks, from left to right.
    static let allColumns: [BoardColumn] = [.toStart] + PullRequestStage.columns.map(BoardColumn.stage) + [.completed]

    /// Which columns fold, and why, on a page this wide at 100%.
    static func folded(
        _ counts: [BoardColumn: Int], yourMove: Set<BoardColumn> = [], choices: BoardFolds = BoardFolds(), open: Set<BoardColumn> = [],
        width: Double, columns: [BoardColumn] = allColumns
    ) -> [BoardColumn: BoardFolding.Why] {
        BoardFolding.make(
            columns: columns, count: { counts[$0] ?? 0 }, yourMove: { yourMove.contains($0) }, choices: choices, open: open,
            widths: BoardWidths(scale: 1, available: width)
        ).folded
    }

    @Test func aColumnFoldsAsYouChoseElseOnceItHasNoCards() {
        let columns = PullRequestStage.columns.map(BoardColumn.stage)
        let counts: [BoardColumn: Int] = [
            .stage(.inProgress): 2, .stage(.yourReview): 1, .stage(.teammateReview): 1, .stage(.approved): 1, .stage(.merged): 1,
        ]
        #expect(Self.folded(counts, width: 2_000, columns: columns) == [.stage(.canMerge): .empty, .stage(.waits): .empty])
        // One you folded stays folded, and one you opened open, cards or none.
        let choices = BoardFolds([.stage(.teammateReview): .folded, .stage(.canMerge): .open])
        #expect(Self.folded(counts, choices: choices, width: 2_000, columns: columns)
            == [.stage(.teammateReview): .yours, .stage(.waits): .empty])
        // Open for the moment, as a dragged card springs it open, whatever else says.
        #expect(Self.folded(counts, choices: choices, open: [.stage(.teammateReview), .stage(.waits)], width: 2_000, columns: columns)
            .isEmpty)
    }

    /// The user's window, 946 points wide, leaves the Board 664: its sidebar takes 240 and the page's margins 42.
    @Test func tooNarrowFoldsCompletedMergedWaitsAndToStartThenWhereYouWaitWhatNeedsLeastFromYouFirst() {
        let counts = Dictionary(uniqueKeysWithValues: Self.allColumns.map { ($0, 1) })
        let review: Set<BoardColumn> = [.stage(.yourReview)]
        let least: [BoardColumn: BoardFolding.Why] = [
            .completed: .narrow, .stage(.merged): .narrow, .stage(.waits): .narrow, .toStart: .narrow,
        ]
        func also(_ columns: PullRequestStage...) -> [BoardColumn: BoardFolding.Why] {
            least.merging(columns.map { (.stage($0), .narrow) }) { $1 }
        }
        // Only as many as it takes: then where you wait, Can merge, whose pull requests complete by themselves, first.
        #expect(Self.folded(counts, yourMove: review, width: 900) == also(.canMerge))
        // Then In progress, where nothing's yours alone, which leaves Your review, Teammate's review and Approved open.
        #expect(Self.folded(counts, yourMove: review, width: 664) == also(.canMerge, .inProgress))
        // Then Teammate's review, and Approved last. Your review, where it's your move, stays open, and the Board scrolls
        // past that.
        #expect(Self.folded(counts, yourMove: review, width: 600) == also(.canMerge, .inProgress, .teammateReview))
        #expect(Self.folded(counts, yourMove: review, width: 400) == also(.canMerge, .inProgress, .teammateReview, .approved))
        #expect(Self.folded(counts, yourMove: review, width: 300) == also(.canMerge, .inProgress, .teammateReview, .approved))
        // One you complete yourself keeps Can merge open, and your draft In progress: the next folds instead.
        #expect(Self.folded(counts, yourMove: review.union([.stage(.canMerge)]), width: 664)
            == also(.inProgress, .teammateReview))
        #expect(Self.folded(counts, yourMove: review.union([.stage(.inProgress)]), width: 600)
            == also(.canMerge, .teammateReview, .approved))
        // A column you opened yourself, or one open for the moment, stays open: the next folds instead.
        let opened = BoardFolds([.stage(.merged): .open])
        #expect(Self.folded(counts, yourMove: review, choices: opened, open: [.toStart], width: 664)
            == [.completed: .narrow, .stage(.waits): .narrow, .stage(.canMerge): .narrow, .stage(.inProgress): .narrow,
                .stage(.teammateReview): .narrow, .stage(.approved): .narrow])
    }

    @Test func threeOpenColumnsFitTheUsersWindowAndShareTheRoomTheStripsLeave() {
        let open: Set<BoardColumn> = [.stage(.inProgress), .stage(.yourReview), .stage(.teammateReview)]
        let folded = Set(Self.allColumns).subtracting(open)
        let window = BoardWidths(scale: 1, available: 664)
        #expect(window.fits(Self.allColumns, folded: folded))
        #expect(!window.fits(Self.allColumns, folded: folded.subtracting([.stage(.canMerge)])))
        // Strips of 18 points, with 3 beside each, 10 between open columns.
        let strips = Double(folded.count) * (18 + 3) + 2 * 10
        #expect(window.open(Self.allColumns, folded: folded) == (664 - strips) / 3)
        // Never narrower than 172, which grows with the text, as a strip does a little.
        #expect(BoardWidths(scale: 1, available: 300).open(Self.allColumns, folded: folded) == 172)
        #expect(BoardWidths(scale: 1.5, available: 0).open(Self.allColumns, folded: folded) == 258)
        #expect(BoardWidths(scale: 1.5, available: 0).strip == 22)
    }

    @Test func whatNeedsYouMarksAStripAndOnlyYourMoveKeepsAColumnOpen() {
        let review = Self.card(.yourReview, .asked("Priya asked you"))
        let complete = Self.card(.canMerge, .ready(autoComplete: false))
        let completesItself = Self.card(.canMerge, .ready(autoComplete: true))
        let failing = Self.card(.inProgress, .failing("Build failed"))
        let reviewer = Self.card(.teammateReview, .findReviewer)
        let merged = Self.card(.merged, .merged)
        #expect([review, complete].allSatisfy { $0.isYourMove && $0.needsYou })
        #expect(failing.needsYou && !failing.isYourMove)
        #expect([completesItself, reviewer, merged].allSatisfy { !$0.needsYou && !$0.isYourMove })
        // In progress, what only you are working on is your move, though it doesn't need you: your draft, or one you set
        // there yourself. Not one a session set there, nor one a session writes, or asks you about, which leaves a draft
        // and what you set as they are, with the session in their flags. A failing build there is only a mark.
        let draft = Self.card(.inProgress, .draft)
        var setByYou = Self.card(.inProgress, .set)
        setByYou.reading.mark = StageMark(stage: .inProgress, at: t(10))
        var setBySession = setByYou
        setBySession.reading.mark?.by = Self.cart
        let session = StageSession(ref: Self.cart, activity: .working, since: t(20))
        let writing = Self.card(.inProgress, .working(session))
        var draftAtWork = draft
        draftAtWork.reading.flags = [.working(session)]
        var setByYouAsking = setByYou
        setByYouAsking.reading.flags = [.asksYou(StageSession(ref: Self.cart, activity: .waitsForYou, since: t(20)))]
        var draftFailing = draft
        draftFailing.reading.flags = [.failing("Build failed")]
        #expect([draft, setByYou].allSatisfy { $0.isYourMove && !$0.needsYou })
        #expect(draftFailing.isYourMove)
        #expect([setBySession, writing, draftAtWork, setByYouAsking].allSatisfy { !$0.isYourMove })

        // Each once, whatever lanes show it.
        let first = Self.mission([Self.step(4101), Self.step(4102)])
        let second = Self.mission([Self.step(4102), Self.step(4103)])
        let board = Self.board([
            4101: Self.reading(.inProgress, .failing("Build failed")), 4102: Self.reading(.inProgress, .changesWanted("Priya wants changes")),
            4103: Self.reading(.inProgress, .draft), 4104: Self.reading(.yourReview, .asked("Sam asked you")),
        ], missions: [first, second])
        #expect(board.needingYou(in: .stage(.inProgress)) == 2)
        #expect(board.lanes.map { $0.needingYou(in: .stage(.inProgress)).count } == [2, 1, 0])
        #expect(board.hasYourMove(in: .stage(.yourReview)) && board.hasYourMove(in: .stage(.inProgress)))

        // Problems only mark a strip: they aren't your move. A work item you started is, not one you sent to Copilot.
        let problems = Self.board([4101: Self.reading(.inProgress, .failing("Build failed"))])
        #expect(!problems.hasYourMove(in: .stage(.inProgress)))
        #expect(problems.withWork([Self.work(5201, .inProgress)], missions: [], stories: []).hasYourMove(in: .stage(.inProgress)))
        #expect(!problems.withWork([Self.work(5202, .inProgress, copilot: true)], missions: [], stories: [])
            .hasYourMove(in: .stage(.inProgress)))
    }

    /// Whether a column shows folded on a page 664 points wide at 100%, once a move took the board's pull requests from these
    /// stages to those.
    static func foldsOnceMoved(_ column: PullRequestStage, from before: [Int: StageReading], to moved: [Int: StageReading]) -> Bool {
        board(before).foldsOnceMoved(
            to: .stage(column), stages: refs(before.merging(moved) { $1 }), choices: BoardFolds(), open: [],
            widths: BoardWidths(scale: 1, available: 664)
        )
    }

    /// A card you drop where its column shows folded once it's in it, its title flashes: as the Board was before the drop,
    /// with each pull request where its stage is once moved.
    @Test func aCardMovedInKeepsItsColumnOpenOnlyWhereItsYourMoveThere() {
        let session = StageSession(ref: Self.cart, activity: .working, since: t(20))
        let before = [
            4091: Self.reading(.teammateReview, .findReviewer), 4102: Self.reading(.teammateReview, .findReviewer),
            4101: Self.reading(.inProgress, .working(session)), 4104: Self.reading(.yourReview, .asked("Sam asked you")),
            4105: Self.reading(.approved, .approvedBy("Maria")),
        ]
        let setByYou = Self.reading(.inProgress, .set, mark: StageMark(stage: .inProgress, at: t(30)))
        var atWork = setByYou
        atWork.flags = [.working(session)]
        // Set in progress by you, it's your move there: In progress stays open, and Teammate's review folds instead.
        #expect(!Self.foldsOnceMoved(.inProgress, from: before, to: [4091: setByYou]))
        // Not while a session writes it: there you wait, so In progress folds for room.
        #expect(Self.foldsOnceMoved(.inProgress, from: before, to: [4091: atWork]))
    }

    /// Each card counts where the move leaves it: no longer in the column it left, and wherever the move took others too.
    @Test func aDroppedCardsColumnFoldsAsTheBoardIsOnceEveryCardMoved() {
        let review = [
            4101: Self.reading(.inProgress, .draft), 4104: Self.reading(.yourReview, .awaitsYourReview),
            4105: Self.reading(.teammateReview, .findReviewer), 4106: Self.reading(.approved, .approvedBy("Maria")),
        ]
        // Your review's only one, set to Teammate's review: Your review, empty, folds, and Teammate's review has the room.
        #expect(!Self.foldsOnceMoved(.teammateReview, from: review, to: [4104: Self.reading(.teammateReview, .findReviewer)]))
        // One that completes by itself, set as next to merge: the one you complete yourself waits for it now, so Can merge,
        // no longer your move, folds for room.
        let next = review.merging([
            4107: Self.reading(.canMerge, .ready(autoComplete: false)),
            4108: Self.reading(.waits, .waitsFor([Self.pr(4107)], words: "After !4107")),
        ]) { $1 }
        #expect(Self.foldsOnceMoved(.canMerge, from: next, to: [
            4108: Self.reading(.canMerge, .ready(autoComplete: true)),
            4107: Self.reading(.waits, .waitsFor([Self.pr(4108)], words: "After !4108")),
        ]))
    }

    @Test func itRemembersTheColumnsYouFoldedOrOpenedAndAClickBackForgetsIt() {
        let defaults = MemorySettings()
        #expect(BoardFolds.load(from: defaults) == BoardFolds())
        let folds = BoardFolds([.stage(.teammateReview): .folded, .toStart: .open, .completed: .folded])
        folds.save(to: defaults)
        #expect(defaults.object(forKey: "order.boardColumns") as? [String: String]
            == ["teammateReview": "folded", "toStart": "open", "completed": "folded"])
        #expect(BoardFolds.load(from: defaults) == folds)
        defaults.set(["approvedLater": "folded", "merged": "half", "waits": "open"], forKey: BoardFolds.defaultsKey)
        #expect(BoardFolds.load(from: defaults) == BoardFolds([.stage(.waits): .open]))
        BoardFolds().save(to: defaults)
        #expect(defaults.object(forKey: BoardFolds.defaultsKey) == nil)

        // A click that does what BriefBar would do by itself forgets your choice, rather than keep its opposite.
        #expect(folds.choosing(.folded, for: .stage(.merged), byItself: false)[.stage(.merged)] == .folded)
        #expect(folds.choosing(.open, for: .stage(.teammateReview), byItself: false)[.stage(.teammateReview)] == nil)
        #expect(folds.choosing(.folded, for: .toStart, byItself: true)[.toStart] == nil)
        #expect(folds.choosing(.open, for: .stage(.waits), byItself: true)[.stage(.waits)] == .open)
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

    // MARK: My Work's + Sprint Tasks

    static func task(_ id: Int) -> ItemRef { .workItem(organization: "contoso", id: id) }

    static func work(
        _ id: Int, _ progress: SprintWork.Progress, story: Int? = nil, linked: [LinkedPullRequest] = [], copilot: Bool = false
    ) -> SprintWork {
        SprintWork(ref: task(id), story: story.map(task), progress: progress, pullRequests: linked, copilotWorks: copilot)
    }

    static func linked(_ number: Int, _ state: LinkedPullRequest.State = .open(author: nil)) -> LinkedPullRequest {
        LinkedPullRequest(ref: pr(number), state: state)
    }

    /// Your sprint work goes on the Board as cards of its own: in To start until it's started, then in In progress, in its
    /// story's mission's lane, else in a lane for its story, else in no mission's; one resolved in Merged; one with a pull
    /// request on the board only on that pull request's card, a resolved one too. Nothing about the pull requests changes.
    @Test func sprintWorkHasCardsOfItsOwnUntilAPullRequestOnTheBoardNamesIt() throws {
        var checkout = Self.mission([Self.step(4101, .next), Self.step(4102, .waiting(open: [Self.pr(4101)], unknown: []))])
        checkout.story = MissionStory(ref: Self.task(5001))
        let stages: [Int: StageReading] = [
            4101: Self.reading(.inProgress, .draft, at: 1), 4102: Self.reading(.yourReview, .asked("Priya asked you"), at: 2),
            4200: Self.reading(.teammateReview, .findReviewer, at: 3),
        ]
        let base = Self.board(stages, missions: [checkout])
        let work = [
            Self.work(5103, .inProgress, story: 5001, linked: [Self.linked(4101)]),
            Self.work(5104, .toDo, story: 5001),
            Self.work(5105, .resolved, story: 5001, linked: [Self.linked(4101)]),
            Self.work(5106, .resolved, story: 5001),
            Self.work(5201, .inProgress, story: 5002),
            Self.work(5202, .toDo, story: 5002, copilot: true),
            // Its story isn't in the sprint, and has no mission.
            Self.work(5301, .toDo, story: 5003),
            Self.work(5401, .toDo),
            // A bug of yours without tasks has no lane of its own.
            Self.work(5002, .toDo, story: 5002),
        ]
        let board = base.withWork(work, missions: [checkout], stories: [Self.task(5001), Self.task(5002)])
        #expect(board.showsWork)
        #expect(board.lanes.map(\.kind) == [.mission(checkout.key), .story(Self.task(5002)), .notInAMission])
        let labels = { (lane: BoardLane, column: BoardTask.Column) in lane.tasks(in: column).map(\.ref.shortOrderLabel) }
        #expect(labels(board.lanes[0], .toStart) == ["5104"])
        #expect(board.lanes[0].tasks(in: .inProgress).isEmpty)
        #expect(labels(board.lanes[0], .merged) == ["5106"])
        // Its work to start keeps a finished mission's lane from folding, as it would hide it.
        #expect(board.lanes[0].hasWorkToDo)
        #expect(labels(board.lanes[1], .inProgress) == ["5201", "5202"])
        #expect(board.lanes[1].story == Self.task(5002))
        #expect(labels(board.lanes[2], .toStart) == ["5301", "5401", "5002"])
        #expect(board.taskCounts == [.toStart: 4, .inProgress: 2, .merged: 1])
        #expect(board.columns == [.toStart] + PullRequestStage.columns.map(BoardColumn.stage) + [.completed])
        #expect(base.columns == PullRequestStage.columns.map(BoardColumn.stage))
        #expect(board.count(of: .toStart) == 4)
        #expect(board.count(of: .stage(.inProgress)) == 3)
        #expect(board.count(of: .stage(.yourReview)) == 1)
        #expect(board.count(of: .stage(.merged)) == 1)
        #expect(board.count(of: .completed) == 0)
        #expect(board.workOfPullRequests == [Self.pr(4101): [Self.task(5103), Self.task(5105)]])
        let copilot = try #require(board.lanes[1].tasks.last)
        #expect(copilot.why == .copilot)

        // The pull requests' cards, columns, counts and Up Next stay as they were.
        #expect(board.lanes.map(\.cards) == [base.lanes[0].cards, [], base.lanes[1].cards])
        #expect(board.counts == base.counts)
        #expect(board.upNext == base.upNext)
        #expect(board.refs == base.refs)

        // With Lanes: None, every card is in one lane, which a board with no pull request has too.
        let one = Self.board(stages, missions: [checkout], lanes: .none).withWork(work, missions: [checkout], stories: [])
        #expect(one.lanes.map(\.kind) == [.all])
        #expect(one.lanes[0].tasks.map(\.ref.shortOrderLabel) == ["5104", "5106", "5201", "5202", "5301", "5401", "5002"])
        let empty = Self.board([:]).withWork([Self.work(5401, .toDo)], missions: [], stories: [])
        #expect(empty.lanes.map(\.kind) == [.notInAMission])
        #expect(!empty.lanes[0].isEmpty)
    }

    /// A work item whose pull requests aren't on your board is in In progress, its card saying what its pull request is: an
    /// open one first, then one that merged, which puts it in Merged, then one BriefBar couldn't read. One abandoned counts
    /// as none, and its card says so.
    @Test func aWorkItemsPullRequestOffTheBoardSaysWhatItIs() throws {
        func task(_ work: SprintWork) -> (column: BoardTask.Column, why: String) {
            let task = BoardTask(work)
            let state = switch work.progress {
            case .toDo: "New"
            case .inProgress: "Active"
            case .resolved: "Resolved"
            case .completed: "Closed"
            }
            return (task.column, BoardText.why(task, state: state, type: "Task"))
        }
        let sams = task(Self.work(5103, .toDo, linked: [Self.linked(4120, .open(author: "Sam"))]))
        #expect(sams.column == .inProgress)
        #expect(sams.why == "Sam's !4120")
        #expect(task(Self.work(5103, .toDo, linked: [Self.linked(4120)])).why == "Your !4120")
        let github = LinkedPullRequest(ref: Self.gh(412), state: .open(author: nil))
        #expect(task(Self.work(5103, .inProgress, linked: [github])).why == "#412 on GitHub")
        #expect(task(Self.work(5103, .inProgress, linked: [Self.linked(4120, .merged)])) == (.merged, "!4120 merged · task still open"))
        #expect(task(Self.work(5103, .inProgress, linked: [Self.linked(4120, .unknown)])) == (.inProgress, "!4120 can't be read"))
        let several = [Self.linked(4118, .abandoned), Self.linked(4119, .unknown), Self.linked(4120, .merged), Self.linked(4121, .open(author: "Sam"))]
        #expect(task(Self.work(5103, .inProgress, linked: several)) == (.inProgress, "Sam's !4121"))
        #expect(task(Self.work(5103, .inProgress, linked: Array(several.prefix(3)))) == (.merged, "!4120 merged · task still open"))

        let abandoned = task(Self.work(5103, .toDo, linked: [Self.linked(4120, .abandoned)]))
        #expect(abandoned.column == .toStart)
        #expect(abandoned.why == "New · !4120 abandoned")
        let started = task(Self.work(5103, .inProgress, linked: [Self.linked(4120, .abandoned)]))
        #expect(started.column == .inProgress)
        #expect(started.why == "Active · no pull request yet · !4120 abandoned")
        #expect(task(Self.work(5103, .toDo, copilot: true)) == (column: .inProgress, why: "New · Copilot works on it"))
    }

    /// Resolved work is in Merged, its card saying so after its state, but in In progress while its pull request is still
    /// under way, or Copilot works on it. Done work is in Completed, whatever its pull requests are.
    @Test func resolvedWorkIsInMergedAndDoneWorkInCompleted() {
        func task(_ work: SprintWork) -> (column: BoardTask.Column, why: String) {
            let task = BoardTask(work)
            return (task.column, BoardText.why(task, state: work.progress == .resolved ? "Resolved" : "Closed", type: "Bug"))
        }
        #expect(task(Self.work(5110, .resolved)) == (.merged, "Resolved"))
        #expect(task(Self.work(5110, .resolved, linked: [Self.linked(4120, .merged)])) == (.merged, "Resolved · !4120 merged"))
        #expect(task(Self.work(5110, .resolved, linked: [Self.linked(4120, .abandoned)])) == (.merged, "Resolved · !4120 abandoned"))
        #expect(task(Self.work(5110, .resolved, linked: [Self.linked(4120, .open(author: "Sam"))])) == (.inProgress, "Resolved · Sam's !4120"))
        #expect(task(Self.work(5110, .resolved, linked: [Self.linked(4120, .unknown)])) == (.inProgress, "Resolved · !4120 can't be read"))
        #expect(task(Self.work(5110, .resolved, copilot: true)) == (.inProgress, "Resolved · Copilot works on it"))

        #expect(task(Self.work(5102, .completed)) == (.completed, "Closed"))
        #expect(task(Self.work(5102, .completed, linked: [Self.linked(4120, .merged)])) == (.completed, "Closed · !4120 merged"))
        #expect(task(Self.work(5102, .completed, linked: [Self.linked(4120, .open(author: "Sam"))])) == (.completed, "Closed · Sam's !4120"))
        #expect(task(Self.work(5102, .completed, linked: [Self.linked(4120, .abandoned)])) == (.completed, "Closed · !4120 abandoned"))
        #expect(task(Self.work(5102, .completed, copilot: true)) == (.completed, "Closed"))
    }

    /// With your work on the board, a merged pull request's card is in Completed once it's out and every work item of yours
    /// it names is done, one that names none too; else in Merged, with your resolved work. Its stage stays Merged, and
    /// Merged and Completed count each card once, whatever lanes show it. Pull requests alone have no Completed.
    @Test func aMergedPullRequestIsInCompletedOnceItsOutAndYourWorkOnItIsDone() throws {
        var checkout = Self.mission([Self.step(4301, status: .merged), Self.step(4302, status: .merged)])
        checkout.story = MissionStory(ref: Self.task(5001))
        let stages: [Int: StageReading] = [
            // Your work on it is still open.
            4301: Self.reading(.merged, .merged, at: 5),
            // Out, its work done.
            4302: Self.reading(.merged, .merged, at: 4),
            // Out, with none of your work on it.
            4303: Self.reading(.merged, .merged, at: 3),
            // Its work done, but its pipelines still run.
            4304: Self.reading(.merged, .merged, at: 2),
            4305: Self.reading(.yourReview, .asked("Priya asked you"), at: 1),
        ]
        let base = Self.board(stages, missions: [checkout])
        let work = [
            Self.work(5501, .inProgress, story: 5001, linked: [Self.linked(4301, .merged)]),
            Self.work(5502, .completed, story: 5001, linked: [Self.linked(4302, .merged)]),
            Self.work(5504, .completed, linked: [Self.linked(4304, .merged)]),
            Self.work(5505, .completed, linked: [Self.linked(4305)]),
            Self.work(5506, .completed, story: 5001),
            Self.work(5507, .resolved, story: 5001),
        ]
        let board = base.withWork(work, missions: [checkout], stories: [Self.task(5001)]) { $0 != Self.pr(4304) }
        #expect(board.completed == [Self.pr(4302), Self.pr(4303)])
        let labels = { (lane: BoardLane, column: BoardColumn) in lane.cards(in: column).map(\.ref.shortOrderLabel) }
        #expect(board.lanes.map(\.kind) == [.mission(checkout.key), .notInAMission])
        #expect(labels(board.lanes[0], .stage(.merged)) == ["!4301"])
        #expect(labels(board.lanes[0], .completed) == ["!4302"])
        #expect(board.lanes[0].tasks.map(\.ref.shortOrderLabel) == ["5506", "5507"])
        #expect(board.lanes[0].tasks(in: .completed).map(\.ref.shortOrderLabel) == ["5506"])
        #expect(board.lanes[0].tasks(in: .merged).map(\.ref.shortOrderLabel) == ["5507"])
        // !4301 names 5501, still open: a merged pull request naming your work that's still to do keeps a finished mission's
        // lane open, as that work's own card would.
        #expect(board.lanes[0].hasWorkToDo)
        // Once its pull requests' work and its own cards' is resolved or done, nothing keeps it open.
        var resolved = work
        resolved[0] = Self.work(5501, .resolved, story: 5001, linked: [Self.linked(4301, .merged)])
        let finished = base.withWork(resolved, missions: [checkout], stories: [Self.task(5001)]) { $0 != Self.pr(4304) }
        #expect(!finished.lanes[0].hasWorkToDo)
        // But a work item still open, whose pull request merged off the board, does, though it's in Merged.
        let stillOpen = Self.work(5508, .inProgress, story: 5001, linked: [Self.linked(4399, .merged)])
        let open = base.withWork(resolved + [stillOpen], missions: [checkout], stories: [Self.task(5001)]) { $0 != Self.pr(4304) }
        #expect(open.lanes[0].tasks(in: .merged).map(\.ref.shortOrderLabel) == ["5507", "5508"])
        #expect(open.lanes[0].hasWorkToDo)
        #expect(labels(board.lanes[1], .stage(.merged)) == ["!4304"])
        #expect(labels(board.lanes[1], .completed) == ["!4303"])
        #expect(labels(board.lanes[1], .stage(.yourReview)) == ["!4305"])
        #expect(board.lanes[1].completed == [Self.pr(4303)])
        #expect(board.count(of: .stage(.merged)) == 3)
        #expect(board.count(of: .completed) == 3)
        #expect(board.count(of: .stage(.yourReview)) == 1)
        #expect(board.workOfPullRequests[Self.pr(4305)] == [Self.task(5505)])

        // Only where they show: their stage, the counts by stage and Up Next stay.
        #expect(board.lanes[0].cards(in: PullRequestStage.merged).map(\.ref.shortOrderLabel) == ["!4301", "!4302"])
        #expect(board.counts == base.counts)
        #expect(board.upNext == base.upNext)

        // With Lanes: None, in the one lane, each once; out by default.
        let one = Self.board(stages, missions: [checkout], lanes: .none).withWork(work, missions: [checkout], stories: [])
        #expect(one.completed == [Self.pr(4302), Self.pr(4303), Self.pr(4304)])
        #expect(labels(one.lanes[0], .stage(.merged)) == ["!4301"])
        #expect(labels(one.lanes[0], .completed) == ["!4302", "!4303", "!4304"])
        #expect(one.count(of: .completed) == 4)

        // Pull requests alone: no Completed, and Merged has every merged one.
        #expect(!base.columns.contains(.completed))
        #expect(base.count(of: .stage(.merged)) == 4)
        #expect(labels(base.lanes[0], .stage(.merged)) == ["!4301", "!4302"])
    }

    /// A story's lane whose work is all resolved or done folds to its header, as a finished mission's does, saying what it
    /// holds; not while any of it is still to do, though in Merged, as one still open whose pull request merged.
    @Test func aStorysLaneWhoseWorkIsAllResolvedOrDoneFoldsSayingWhatItHolds() {
        let work = [
            Self.work(5101, .completed, story: 5001),
            Self.work(5102, .completed, story: 5001),
            Self.work(5103, .completed, story: 5001, linked: [Self.linked(4120, .merged)]),
            Self.work(5201, .resolved, story: 5002),
            Self.work(5202, .completed, story: 5002),
            Self.work(5203, .completed, story: 5002),
            Self.work(5301, .inProgress, story: 5003, linked: [Self.linked(4121, .merged)]),
            Self.work(5302, .completed, story: 5003),
            Self.work(5401, .toDo, story: 5004),
            Self.work(5402, .completed),
        ]
        let stories = [5001, 5002, 5003, 5004].map(Self.task)
        let board = Self.board([:]).withWork(work, missions: [], stories: stories)
        #expect(board.lanes.map(\.kind) == stories.map(BoardLane.Kind.story) + [.notInAMission])
        #expect(board.lanes.map(\.isFinishedStory) == [true, true, false, false, false])
        #expect(board.lanes[0].finishedWork == "3 completed")
        #expect(board.lanes[1].finishedWork == "1 merged · 2 completed")
        #expect(board.lanes[2].tasks(in: .merged).map(\.ref.shortOrderLabel) == ["5301"])
        #expect(board.lanes[2].count(of: .stage(.merged)) == 1 && board.lanes[2].count(of: .completed) == 1)
    }
}
