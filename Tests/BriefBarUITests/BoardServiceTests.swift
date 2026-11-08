import BriefBarCore
import BriefBarUI
import Foundation
import Testing

/// Up Next and the Board, as Pull Request Order keeps them: one view for both pages, which GitHub's shows as List without
/// saving it, the lanes and Up Next's fold remembered, Up Next's "2 more ›", whose pull request is yours, and the board from
/// what Azure DevOps tells, which changes no stage by itself.
@MainActor
@Suite struct BoardServiceTests {
    private static let repository = "contoso/7d3f9a12/shop-web"
    private static let account = "robin@contoso.com"

    private static func ref(_ number: Int) -> ItemRef {
        .pullRequest(organization: "contoso", number: number)
    }

    private static func ado(_ number: Int) -> OrderPullRequest {
        OrderPullRequest(
            ref: ref(number), repository: repository, sourceBranch: "robin/work-\(number)", targetBranch: "main", author: "robin",
            createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
        )
    }

    private static func service(_ defaults: MemoryDefaults) -> PullRequestOrder {
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        return PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
    }

    private static func tell(_ order: PullRequestOrder, _ facts: [Int: StageFacts], states: [Int: PullRequestState] = [:]) {
        order.publish(
            .azureDevOps, pullRequests: facts.keys.sorted().map { number in
                var pullRequest = ado(number)
                pullRequest.state = states[number] ?? .open
                return pullRequest
            },
            stages: Dictionary(uniqueKeysWithValues: facts.map { (ref($0.key), $0.value) }), account: account
        )
    }

    private static let cart = ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b")!

    /// What the Copilot app tells: one session, on these pull requests, in this state since then.
    private static func tellSession(_ order: PullRequestOrder, on numbers: [Int], state: ItemState?, since: Date) {
        order.publish(
            .copilot, sessions: [OrderSession(ref: cart, pullRequests: numbers.map(ref))],
            items: [LinkedItem(ref: cart, label: "Cart", title: "Cart", symbol: "bolt.fill", color: .blue, state: state, date: since)]
        )
    }

    /// The preferences, with orders sessions told: each one's pull requests in turn, each after the one before.
    private static func defaults(orders: [[Int]]) throws -> MemoryDefaults {
        let defaults = MemoryDefaults()
        var declared = DeclaredOrders()
        for (index, numbers) in orders.enumerated() {
            try declared.apply(
                OrderRequest(entries: numbers.enumerated().map { place, number in
                    .init(link: link(number), after: place == 0 ? [] : ["\(numbers[place - 1])"])
                }),
                now: Date(timeIntervalSince1970: 1_791_900_000 + Double(index)), newID: UUID()
            )
        }
        declared.save(to: defaults)
        return defaults
    }

    private static func link(_ number: Int) -> String {
        "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)"
    }

    /// The Board's moves for Azure DevOps' page, as it has them now.
    private static func moves(_ order: PullRequestOrder, missionChanges: Bool = false, lanes: BoardLanes = .missions) -> BoardMoves {
        BoardMoves(
            board: order.board(kinds: kinds, lanes: lanes), missions: MissionsBody.missions(order.missions, kinds: kinds), order: order,
            missionChanges: missionChanges
        )
    }

    private static let kinds: Set<ItemRef.Kind> = [.pullRequest]

    @Test func theBoardIsOneChoiceForBothPagesAndGitHubsShowsListWithoutSavingIt() {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        order.setView(.board)
        #expect(order.view(offering: OrderView.offered(for: [.pullRequest])) == .board)
        // GitHub's page offers List and Map: it shows List, and reading that writes nothing.
        #expect(order.view(offering: OrderView.offered(for: [.gitHubPullRequest])) == .list)
        #expect(defaults.string(forKey: OrderView.defaultsKey) == "board")
        #expect(Self.service(defaults).view == .board)
    }

    @Test func theLanesAndUpNextsFoldAreRemembered() {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        #expect(order.lanes == .missions)
        #expect(!order.isUpNextFolded)

        order.setLanes(.none)
        order.setUpNextFolded(true)

        let again = Self.service(defaults)
        #expect(again.lanes == .none)
        #expect(again.isUpNextFolded)
        again.setUpNextFolded(false)
        #expect(defaults.object(forKey: UpNext.foldedKey) == nil)
    }

    @Test func upNextsMoreShowsTheBoardAtItsColumn() {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        order.revealColumn(.yourReview)
        #expect(order.view == .board)
        #expect(order.revealedColumn == .yourReview)
        #expect(defaults.string(forKey: OrderView.defaultsKey) == "board")
    }

    /// A row's capsule asks By Mission to show its mission. On the Board with Lanes: None, which has no lane for it, the
    /// Board shows a lane for each mission again, remembered; List, and GitHub's page, which shows List, change nothing.
    @Test func showingAMissionOnTheBoardWithNoLanesShowsTheMissionsLanes() {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        let key = MissionKey.chain(Self.ref(4101))
        order.setLanes(.none)

        order.reveal(key, kinds: Self.kinds)
        #expect(order.revealed == key && order.lanes == .none)

        order.setView(.board)
        order.reveal(key, kinds: [.gitHubPullRequest])
        #expect(order.lanes == .none)

        order.reveal(key, kinds: Self.kinds)
        #expect(order.revealed == key && order.lanes == .missions)
        #expect(Self.service(defaults).lanes == .missions)
    }

    @Test func theBoardAndUpNextFollowWhatAzureDevOpsTellsAndOnlyYoursCanGoToATeammate() {
        let order = Self.service(MemoryDefaults())
        Self.tell(order, [
            4131: StageFacts(role: .author, failure: "Build failed"),
            4088: StageFacts(role: .reviewer, asksYou: "Priya asked you"),
            4079: StageFacts(role: .author),
            4120: StageFacts(role: .author, isReady: true, othersVoted: true),
            // Someone else's that you approved isn't on your board.
            4140: StageFacts(role: .reviewer),
        ])
        let board = order.board(kinds: [.pullRequest])
        #expect(board.upNext.slots.map(\.kind) == [.fix, .yourReview, .teammateReview, .canMerge])
        #expect(board.upNext.slots.map(\.card.ref) == [Self.ref(4131), Self.ref(4088), Self.ref(4079), Self.ref(4120)])
        #expect(board.lanes.map(\.kind) == [.notInAMission])
        #expect(board.notOnBoard([Self.ref(4140), Self.ref(4079)]) == 1)
        #expect(order.isYours(Self.ref(4079)))
        #expect(!order.isYours(Self.ref(4088)))
        #expect(!order.isYours(Self.ref(4999)))

        // A drop that sets a stage is yours to undo; nothing on the board changed a stage by itself.
        #expect(order.lastStageChange == nil)
        #expect(order.setStage(.teammateReview, of: Self.ref(4131)) == .done)
        #expect(order.board(kinds: [.pullRequest]).upNext.slots.first?.kind == .yourReview)
        order.undo()
        #expect(order.board(kinds: [.pullRequest]).upNext.slots.first?.card.ref == Self.ref(4131))
    }

    @Test func withPullRequestOrderOffTheresNothingNext() {
        let defaults = MemoryDefaults()
        let order = PullRequestOrder(defaults: defaults, isDemo: false)
        Self.tell(order, [4131: StageFacts(role: .author, failure: "Build failed")])
        #expect(order.board(kinds: [.pullRequest]).upNext.isEmpty)
        #expect(order.board(kinds: [.pullRequest]).lanes.isEmpty)
    }

    // MARK: Moving a card, as it is now

    /// A drop acts on the card as the board has it when it lands, never as it was when the drag started: one whose session
    /// finished meanwhile is in Your review already, and dropping it there sets nothing, so nothing says "You set it".
    @Test func aDropActsOnTheCardAsItIsNowNotAsTheDragFoundIt() throws {
        let order = Self.service(MemoryDefaults())
        let started = Date(timeIntervalSince1970: 1_791_999_000)
        Self.tell(order, [4093: StageFacts(role: .author)])
        Self.tellSession(order, on: [4093], state: .running, since: started)
        let drag = BoardDrag(ref: Self.ref(4093))
        let asDragged = try #require(Self.moves(order).card(Self.ref(4093), in: .notInAMission))
        #expect(asDragged.stage == .inProgress)

        Self.tellSession(order, on: [4093], state: .done, since: started.addingTimeInterval(60))
        let moves = Self.moves(order)
        let dropped = try #require(moves.drop(drag.payload, of: drag, on: .yourReview, in: .notInAMission))
        #expect(dropped.card.stage == .yourReview)
        #expect(dropped.move == .stays)
        // As the drag found it, it would have set Your review, which nothing would have ended.
        #expect(moves.move(asDragged, to: .yourReview, in: .notInAMission) == .setStage(.yourReview))
    }

    /// One in Waits whose blocker merged meanwhile can merge already: dropping it on Can merge sets nothing as next.
    @Test func aWaitingCardWhoseBlockerMergedMeanwhileIsntSetAsNext() throws {
        let order = Self.service(try Self.defaults(orders: [[4101, 4102]]))
        let ready = StageFacts(role: .author, isReady: true, othersVoted: true)
        Self.tell(order, [4101: StageFacts(role: .author), 4102: ready])
        let lane = try #require(order.missions.first?.key)
        let drag = BoardDrag(ref: Self.ref(4102))
        let asDragged = try #require(Self.moves(order, missionChanges: true).card(Self.ref(4102), in: .mission(lane)))
        #expect(asDragged.stage == .waits)

        Self.tell(order, [4101: StageFacts(role: .author, state: .merged), 4102: ready], states: [4101: .merged])
        let moves = Self.moves(order, missionChanges: true)
        let dropped = try #require(moves.drop(drag.payload, of: drag, on: .canMerge, in: .mission(lane)))
        #expect(dropped.card.stage == .canMerge)
        #expect(dropped.move == .stays)
        #expect(moves.move(asDragged, to: .canMerge, in: .mission(lane)) == .setAsNext(lane))
    }

    /// Only what a drag from this board carries drops: never text that names a pull request on it, as from another app, nor
    /// with no drag started here, nor another drag's.
    @Test func aDropTakesOnlyThisBoardsDrag() {
        let order = Self.service(MemoryDefaults())
        Self.tell(order, [4093: StageFacts(role: .author)])
        let moves = Self.moves(order)
        let drag = BoardDrag(ref: Self.ref(4093))
        #expect(moves.drop(drag.payload, of: drag, on: .inProgress, in: .notInAMission)?.move == .setStage(.inProgress))
        #expect(moves.drop(Self.ref(4093).description, of: drag, on: .inProgress, in: .notInAMission) == nil)
        #expect(moves.drop(Self.link(4093), of: drag, on: .inProgress, in: .notInAMission) == nil)
        #expect(moves.drop(drag.payload, of: nil, on: .inProgress, in: .notInAMission) == nil)
        #expect(moves.drop(BoardDrag(ref: Self.ref(4093)).payload, of: drag, on: .inProgress, in: .notInAMission) == nil)
        // One that left the board meanwhile.
        let gone = BoardDrag(ref: Self.ref(4999))
        #expect(moves.drop(gone.payload, of: gone, on: .inProgress, in: .notInAMission) == nil)
    }

    /// A card moves in any lane that has it, as a pull request in two missions has a card in each; never into a lane that
    /// doesn't.
    @Test func aCardMovesInALaneThatHasItAndNoOther() throws {
        let order = Self.service(try Self.defaults(orders: [[4101, 4105], [4105, 4106]]))
        Self.tell(order, [4101: StageFacts(role: .author), 4105: StageFacts(role: .author), 4106: StageFacts(role: .author)])
        let lanes = order.missions.map(\.key)
        #expect(lanes.count == 2)
        let moves = Self.moves(order)
        for lane in lanes {
            let card = try #require(moves.card(Self.ref(4105), in: .mission(lane)))
            #expect(card.mission == lane)
            #expect(moves.move(card, to: .inProgress, in: .mission(lane)) == .setStage(.inProgress))
        }
        let elsewhere = try #require(lanes.first { key in order.missions.first { $0.key == key }?.contains(Self.ref(4106)) == false })
        let card = try #require(moves.card(Self.ref(4106), in: .mission(elsewhere)))
        #expect(moves.move(card, to: .inProgress, in: .mission(elsewhere))
            == .refused("A card moves between stages in its own mission's lane"))
    }

    /// Only yours goes to Teammate's review, there, in its menus and in VoiceOver's actions: someone else's says whose it is.
    @Test func onlyYoursGoesToTeammatesReviewAndSomeoneElsesSaysWhose() throws {
        let order = Self.service(MemoryDefaults())
        Self.tell(order, [
            4093: StageFacts(role: .author, failure: "Build failed"),
            4088: StageFacts(role: .reviewer, asksYou: "Priya asked you", author: "Priya"),
        ])
        let moves = Self.moves(order)
        let yours = try #require(moves.card(Self.ref(4093), in: .notInAMission))
        let priyas = try #require(moves.card(Self.ref(4088), in: .notInAMission))
        #expect(moves.move(yours, to: .teammateReview, in: .notInAMission) == .setStage(.teammateReview))
        #expect(moves.move(priyas, to: .teammateReview, in: .notInAMission)
            == .refused("It's Priya's: they ask for its reviews. Finished My Review takes it off your board"))
        #expect(order.whyNotTeammateReview(Self.ref(4088)) == "It's Priya's: they ask for its reviews")
        #expect(order.whyNotTeammateReview(Self.ref(4093)) == nil)
        let offered = StageAction.offered(for: order.stage(of: Self.ref(4088)), canUndo: false, isYours: order.isYours(Self.ref(4088)))
        #expect(offered == [.finishedReview, .move(.inProgress)])
        // Finished My Review still takes it off your board.
        #expect(order.finishedReview(Self.ref(4088)) == .done)
        #expect(order.stage(of: Self.ref(4088))?.isOnBoard == false)
    }

    /// ⌘→ and ⌘← move a card to the next or previous stage you can set, as it is now; from Waits, ⌘← is Can merge, which
    /// refuses until you can change missions yourself.
    @Test func theKeysMoveTheCardAsItIsNow() throws {
        let order = Self.service(try Self.defaults(orders: [[4101, 4102]]))
        Self.tell(order, [4093: StageFacts(role: .author, failure: "Build failed"), 4101: StageFacts(role: .author),
                          4102: StageFacts(role: .author, isReady: true, othersVoted: true)])
        let lane = try #require(order.missions.first?.key)
        let moves = Self.moves(order)
        #expect(moves.key(Self.ref(4093), in: .notInAMission, forward: true)?.move == .setStage(.yourReview))
        #expect(moves.key(Self.ref(4093), in: .notInAMission, forward: false) == nil)
        #expect(moves.key(Self.ref(4102), in: .mission(lane), forward: false)?.move
            == .refused("It waits for !4101: it can merge once BriefBar sees it merge"))
        #expect(Self.moves(order, missionChanges: true).key(Self.ref(4102), in: .mission(lane), forward: false)?.move == .setAsNext(lane))
        #expect(moves.key(Self.ref(4999), in: .notInAMission, forward: true) == nil)

        // Once moved, the next key moves it on from where it is now.
        StageCommand.perform(.move(.yourReview), on: Self.ref(4093), order: order, undo: .lane)
        #expect(Self.moves(order).key(Self.ref(4093), in: .notInAMission, forward: true)?.move == .setStage(.teammateReview))
    }

    /// Why a key couldn't move a pull request while its details covered the Board, which they say under its stage: only for
    /// it, and only while its stage reads as it did then, whether or not a Board is there to see it change.
    @Test func theDetailsSayWhyAKeyCouldntMoveItOnlyWhileItsStageReadsAsThen() throws {
        let order = Self.service(MemoryDefaults())
        Self.tell(order, [4093: StageFacts(role: .author, failure: "Build failed"), 4094: StageFacts(role: .author)])
        #expect(order.setStage(.teammateReview, of: Self.ref(4093)) == .done)
        let reading = try #require(order.stage(of: Self.ref(4093)))
        order.stageRefusal = StageRefusal(ref: Self.ref(4093), why: "Azure DevOps decides when it can merge", reading: reading)
        #expect(order.stageRefusal(of: Self.ref(4093)) == "Azure DevOps decides when it can merge")
        #expect(order.stageRefusal(of: Self.ref(4094)) == nil)

        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        #expect(order.stageRefusal(of: Self.ref(4093)) == nil)
    }

    /// A card a key moved is owed the keyboard's focus until it takes it, drawn anew in its new column, or until that move's
    /// wait for it ends: not when the last move's wait ends just after the next key, which owes it the focus anew.
    @Test func aCardIsOwedTheFocusUntilItTakesItOrItsOwnMovesWaitEnds() {
        var owed = OwedFocus<ItemRef>()
        let first = owed.owe(Self.ref(4093))
        owed.took(Self.ref(4094))
        #expect(owed.spot == Self.ref(4093), "Another card took what this one is owed")
        owed.took(Self.ref(4093))
        #expect(owed.spot == nil)

        // The next key, then the first's wait ends before the card is drawn anew, as on a busy Mac.
        let second = owed.owe(Self.ref(4093))
        owed.waitEnded(first)
        #expect(owed.spot == Self.ref(4093), "The last move's wait let go of what the next one owes")
        owed.waitEnded(second)
        #expect(owed.spot == nil, "Not drawn anew, it was still owed the focus once its wait ended")
    }

    // MARK: Undo, once a card leaves the board

    /// Finished My Review on someone else's card, the only one in no mission, takes it off the board, and its lane with it:
    /// the Board keeps a lane for its Undo, with a lane for each mission or every card in one, and Undo brings it back.
    @Test func undoStaysOnTheBoardOnceTheOnlyCardInItsLaneLeaves() throws {
        let order = Self.service(MemoryDefaults())
        Self.tell(order, [4088: StageFacts(role: .reviewer, asksYou: "Priya asked you", author: "Priya")])
        #expect(order.board(kinds: Self.kinds).lanes.map(\.kind) == [.notInAMission])

        StageCommand.finishedReview(Self.ref(4088), order: order, undo: .lane)
        let changed = order.lastStageChange?.ref
        #expect(changed == Self.ref(4088))
        for (lanes, kind) in [(BoardLanes.missions, BoardLane.Kind.notInAMission), (.none, .all)] {
            let board = order.board(kinds: Self.kinds, lanes: lanes)
            #expect(board.lanes.isEmpty)
            let kept = board.lanes(keepingUndoOf: changed, missions: [])
            #expect(kept.map(\.kind) == [kind])
            let lane = try #require(kept.first)
            #expect(board.undoRefs(of: lane, missions: [], changed: changed).contains(Self.ref(4088)))
        }

        order.undo()
        #expect(order.board(kinds: Self.kinds).refs == [Self.ref(4088)])
    }

    /// One in a mission keeps its Undo in its mission's lane, though it left the board.
    @Test func undoStaysInTheMissionsLaneOnceItsCardLeaves() throws {
        let order = Self.service(try Self.defaults(orders: [[4087, 4088]]))
        Self.tell(order, [4087: StageFacts(role: .author), 4088: StageFacts(role: .reviewer, asksYou: "Priya asked you", author: "Priya")])
        order.finishedReview(Self.ref(4088))
        let missions = MissionsBody.missions(order.missions, kinds: Self.kinds)
        let board = order.board(kinds: Self.kinds)
        let key = try #require(missions.first?.key)
        let lane = try #require(board.lane(for: key))
        #expect(!lane.cards.contains { $0.ref == Self.ref(4088) })
        let undoRefs = board.undoRefs(of: lane, missions: missions, changed: order.lastStageChange?.ref)
        #expect(undoRefs.contains(Self.ref(4088)))
        #expect(board.lanes(keepingUndoOf: order.lastStageChange?.ref, missions: missions) == board.lanes)
    }

    // MARK: The view

    /// GitHub's page shows List where you chose the Board: picking List there saves nothing, so Azure DevOps' page still
    /// shows the Board; picking Map saves it, for both.
    @Test func gitHubsPageNeverSavesListOverYourBoard() {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        order.setView(.board)
        let shown = order.view(offering: OrderView.offered(for: [.gitHubPullRequest]))
        #expect(shown == .list)

        OrderViewPicker.choose(.list, showing: shown, order: order)
        #expect(order.view == .board)
        #expect(defaults.string(forKey: OrderView.defaultsKey) == "board")

        OrderViewPicker.choose(.map, showing: shown, order: order)
        #expect(order.view == .map)
        #expect(defaults.string(forKey: OrderView.defaultsKey) == "map")
    }
}
