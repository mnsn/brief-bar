import AppKit
import BriefBarCore
import BriefBarUI
import Foundation
import SwiftUI
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

    private static func service(
        _ defaults: MemoryDefaults, now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_792_000_000) }
    ) -> PullRequestOrder {
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        return PullRequestOrder(defaults: defaults, isDemo: false, now: now)
    }

    /// What Azure DevOps tells, as Robin, with Contoso's lists read in full (`listsRead`), unless said otherwise: one it
    /// doesn't list there has left them. `listed` false is before it has read them since BriefBar started.
    private static func tell(
        _ order: PullRequestOrder, _ facts: [Int: StageFacts], states: [Int: PullRequestState] = [:], account: String = account,
        listed: Bool = true, listsRead: Set<String> = ["contoso"], unreadLinks: Set<ItemRef> = []
    ) {
        order.publish(
            .azureDevOps, pullRequests: facts.keys.sorted().map { number in
                var pullRequest = ado(number)
                pullRequest.state = states[number] ?? .open
                return pullRequest
            },
            stages: Dictionary(uniqueKeysWithValues: facts.map { (ref($0.key), $0.value) }), account: account, listed: listed,
            listsRead: listsRead, unreadLinks: unreadLinks
        )
    }

    /// What BriefBar keeps of what an account chose for Up Next's slots, Robin's unless said otherwise.
    private static func kept(_ defaults: MemoryDefaults, for account: String = account) -> UpNextPicks {
        UpNextPicks.Kept.load(from: defaults).picks(for: account)
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

        // A drop that sets a stage is yours to undo; nothing on the board changed a stage by itself. What needs you shows
        // in Fix next and in its column's slot both.
        #expect(order.lastStageChange == nil)
        #expect(order.setStage(.inProgress, of: Self.ref(4079)) == .done)
        #expect(order.board(kinds: [.pullRequest]).upNext.slots.map(\.card.ref)
            == [Self.ref(4131), Self.ref(4088), Self.ref(4131), Self.ref(4120)])
        order.undo()
        #expect(order.board(kinds: [.pullRequest]).upNext.slots.map(\.card.ref)
            == [Self.ref(4131), Self.ref(4088), Self.ref(4079), Self.ref(4120)])
    }

    @Test func withPullRequestOrderOffTheresNothingNext() {
        let defaults = MemoryDefaults()
        let order = PullRequestOrder(defaults: defaults, isDemo: false)
        Self.tell(order, [4131: StageFacts(role: .author, failure: "Build failed")])
        #expect(order.board(kinds: [.pullRequest]).upNext.isEmpty)
        #expect(order.board(kinds: [.pullRequest]).lanes.isEmpty)
    }

    // MARK: The one you choose

    /// Three to fix: two failed builds and changes Priya wants, which BriefBar's order puts last; all three in Teammate's
    /// review, where BriefBar's order has the oldest first: !4133, !4131, then !4132.
    private static let fixes: [Int: StageFacts] = [
        4131: StageFacts(role: .author, failure: "Build failed", since: Date(timeIntervalSince1970: 1_791_000_000)),
        4132: StageFacts(role: .author, failure: "Merge conflicts", since: Date(timeIntervalSince1970: 1_791_100_000)),
        4133: StageFacts(role: .author, changesWanted: "Priya wants changes", since: Date(timeIntervalSince1970: 1_790_000_000)),
    ]

    private static func fixNext(_ order: PullRequestOrder) -> UpNext.Slot? {
        order.board(kinds: kinds).upNext.slots.first { $0.kind == .fix }
    }

    private static func teammateNext(_ order: PullRequestOrder) -> UpNext.Slot? {
        order.board(kinds: kinds).upNext.slots.first { $0.kind == .teammateReview }
    }

    /// The one you choose is Fix next's, ahead of BriefBar's order, kept in the preferences by reference, with the account,
    /// and still so once BriefBar starts again and Azure DevOps says that account signed in; but only one Fix next has.
    /// Back soon after it moved on, it's still yours; once it's been away for half an hour, the choice goes, and BriefBar's
    /// order chooses again, as it does at once with Let BriefBar Choose.
    @Test func whatYouChooseIsRememberedUntilItMovesOn() throws {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        Self.tell(order, Self.fixes)
        #expect(Self.fixNext(order)?.cards.map(\.ref) == [Self.ref(4131), Self.ref(4132), Self.ref(4133)])
        #expect(Self.fixNext(order)?.isPicked == false)

        #expect(order.pickNext(Self.ref(4133), in: .fix))
        let slot = try #require(Self.fixNext(order))
        #expect(slot.card.ref == Self.ref(4133))
        #expect(slot.isPicked)
        #expect(UpNextView.spoken(slot, mission: "Not in a mission", order: order)
            == "Priya wants changes, in Teammate's review, Not in a mission, you chose it")
        #expect(UpNextView.choice(slot.card, in: .fix, order: order) == "!4133 — Priya wants changes · in Teammate's review")
        #expect(order.board(kinds: Self.kinds).picked == [.fix: Self.ref(4133)])
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4133)]))
        #expect(order.keepsStages)
        #expect(!order.pickNext(Self.ref(4999), in: .fix))
        #expect(!order.pickNext(Self.ref(4131), in: .yourReview))
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4133)]))

        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let again = Self.service(defaults, now: { now })
        #expect(again.picks.isEmpty)
        Self.tell(again, Self.fixes)
        #expect(again.picks == UpNextPicks([.fix: Self.ref(4133)]))
        #expect(Self.fixNext(again)?.card.ref == Self.ref(4133))

        // Priya's changes are made: it waits for her in Teammate's review, and BriefBar's order chooses while it's away.
        var fixed = Self.fixes
        fixed[4133] = StageFacts(role: .author, waitingFor: "Waiting on Priya")
        Self.tell(again, fixed)
        #expect(again.stage(of: Self.ref(4133))?.stage == .teammateReview)
        #expect(Self.fixNext(again)?.card.ref == Self.ref(4131))
        #expect(Self.fixNext(again)?.isPicked == false)
        // She wants more within minutes: it's back, still yours.
        now += 600
        Self.tell(again, Self.fixes)
        #expect(Self.fixNext(again)?.card.ref == Self.ref(4133))
        #expect(Self.fixNext(again)?.isPicked == true)
        // Made again, and still away half an hour later, as the clock finds: the choice goes.
        Self.tell(again, fixed)
        now += UpNextPicks.awayFor
        again.timePassed()
        #expect(again.picks.isEmpty)
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
        #expect(Self.fixNext(again)?.card.ref == Self.ref(4131))
        // Back in Fix next, it's BriefBar's order's again.
        Self.tell(again, Self.fixes)
        #expect(Self.fixNext(again)?.card.ref == Self.ref(4131))

        #expect(again.pickNext(Self.ref(4132), in: .fix))
        again.letBriefBarChoose(.fix)
        #expect(again.picks.isEmpty)
        #expect(Self.fixNext(again)?.card.ref == Self.ref(4131))
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)

        // One that merged, which the lists still read but no longer show, goes half an hour later.
        #expect(again.pickNext(Self.ref(4132), in: .fix))
        var merged = Self.fixes
        merged[4132] = StageFacts(role: .author, state: .merged, isListed: false)
        Self.tell(again, merged, states: [4132: .merged])
        #expect(again.picks == UpNextPicks([.fix: Self.ref(4132)]))
        now += UpNextPicks.awayFor
        again.timePassed()
        #expect(again.picks.isEmpty)
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
    }

    /// What BriefBar reads before it has read everything ends no choice. As Pull Request Order turns on, which pull requests
    /// the Copilot app's sessions are on can come after Azure DevOps' lists, and a pull request a session asks you about
    /// reads, meanwhile, as waiting on a teammate, as it does once the Copilot source stops. Turning Pull Request Order off
    /// forgets since when one was away, as quitting does: once it's on again, each choice has its half hour again. One its
    /// source can't tell where it is, as before Azure DevOps has read its lists, waits however long.
    @Test func aChoiceOutlastsWhatBriefBarReadsBeforeItHasReadEverything() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let order = Self.service(defaults, now: { now })
        var facts = Self.fixes
        facts[4093] = StageFacts(role: .author, waitingFor: "Waiting on Priya", since: Date(timeIntervalSince1970: 1_791_200_000))
        Self.tell(order, facts)
        Self.tellSession(order, on: [4093], state: .needsYou, since: now)
        #expect(order.stage(of: Self.ref(4093))?.stage == .inProgress)
        #expect(order.pickNext(Self.ref(4093), in: .fix))

        order.withdraw(.copilot)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(Self.fixNext(order)?.card.ref == Self.ref(4131))
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4093)]))
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4093)]))

        // Off 20 minutes later, and on again, Azure DevOps' lists first: 40 minutes after it went away, it's still yours.
        now += 1_200
        order.setOn(false)
        order.setOn(true)
        Self.tell(order, facts)
        now += 1_200
        order.timePassed()
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4093)]))
        Self.tellSession(order, on: [4093], state: .needsYou, since: now)
        #expect(Self.fixNext(order)?.card.ref == Self.ref(4093))
        #expect(Self.fixNext(order)?.isPicked == true)

        // BriefBar starts again a day later: for an hour, before Azure DevOps has read its lists, what it tells doesn't have
        // !4093; then its lists have it, before the sessions.
        now += 86_400
        let again = Self.service(defaults, now: { now })
        Self.tell(again, Self.fixes, listed: false)
        now += 3_600
        again.timePassed()
        #expect(again.picks == UpNextPicks([.fix: Self.ref(4093)]))

        Self.tell(again, facts)
        #expect(Self.fixNext(again)?.card.ref == Self.ref(4131))
        Self.tellSession(again, on: [4093], state: .needsYou, since: now)
        #expect(Self.fixNext(again)?.card.ref == Self.ref(4093))
        #expect(Self.fixNext(again)?.isPicked == true)
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4093)]))
    }

    /// Undo of a stage you changed chooses its pull request again where you'd chosen it, however long after, gone by then or
    /// not, but not for a slot you've decided for since, choosing another or letting BriefBar choose, whatever became of that.
    @Test func undoingAStageChangeChoosesItsPullRequestAgain() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let order = Self.service(defaults, now: { now })
        Self.tell(order, Self.fixes)
        #expect(order.pickNext(Self.ref(4132), in: .teammateReview))
        #expect(order.setStage(.inProgress, of: Self.ref(4132)) == .done)
        #expect(Self.teammateNext(order)?.card.ref == Self.ref(4133))
        now += UpNextPicks.awayFor
        order.timePassed()
        #expect(order.picks.isEmpty)

        #expect(order.undo())
        #expect(order.stage(of: Self.ref(4132))?.stage == .teammateReview)
        #expect(Self.teammateNext(order)?.card.ref == Self.ref(4132))
        #expect(Self.teammateNext(order)?.isPicked == true)
        #expect(Self.kept(defaults) == UpNextPicks([.teammateReview: Self.ref(4132)]))

        // Undone half an hour later, before BriefBar looked again.
        #expect(order.setStage(.inProgress, of: Self.ref(4132)) == .done)
        now += UpNextPicks.awayFor
        #expect(order.undo())
        #expect(Self.teammateNext(order)?.isPicked == true)
        #expect(order.picks == UpNextPicks([.teammateReview: Self.ref(4132)]))

        #expect(order.setStage(.inProgress, of: Self.ref(4132)) == .done)
        #expect(order.pickNext(Self.ref(4131), in: .teammateReview))
        #expect(order.undo())
        #expect(order.stage(of: Self.ref(4132))?.stage == .teammateReview)
        #expect(order.picks == UpNextPicks([.teammateReview: Self.ref(4131)]))
        #expect(Self.teammateNext(order)?.card.ref == Self.ref(4131))

        // You let BriefBar choose since: Undo puts the stage back, but chooses nothing.
        #expect(order.pickNext(Self.ref(4132), in: .teammateReview))
        #expect(order.setStage(.inProgress, of: Self.ref(4132)) == .done)
        order.letBriefBarChoose(.teammateReview)
        #expect(order.undo())
        #expect(order.stage(of: Self.ref(4132))?.stage == .teammateReview)
        #expect(order.picks.isEmpty)
        #expect(Self.teammateNext(order)?.card.ref == Self.ref(4133))

        // Nor once the one you chose since moved on, and its choice went: Priya approved it.
        #expect(order.pickNext(Self.ref(4132), in: .teammateReview))
        #expect(order.setStage(.inProgress, of: Self.ref(4132)) == .done)
        #expect(order.pickNext(Self.ref(4131), in: .teammateReview))
        var approved = Self.fixes
        approved[4131] = StageFacts(role: .author, failure: "Build failed", isApproved: true, approvedBy: "Priya")
        Self.tell(order, approved)
        #expect(order.stage(of: Self.ref(4131))?.stage == .approved)
        now += UpNextPicks.awayFor
        order.timePassed()
        #expect(order.picks.isEmpty)
        #expect(order.undo())
        #expect(order.stage(of: Self.ref(4132))?.stage == .teammateReview)
        #expect(order.picks.isEmpty)
        #expect(Self.kept(defaults).isEmpty)
    }

    /// While the one you chose waits, as while its build runs again, the slot shows the next one, and its menu still offers
    /// Let BriefBar Choose, which forgets yours: it doesn't come back once its build fails again.
    @Test func letBriefBarChooseForgetsAChoiceThatWaits() throws {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        Self.tell(order, Self.fixes)
        let unpicked = try #require(Self.fixNext(order))
        #expect(!UpNextView.offersLetBriefBarChoose(unpicked, order: order))
        #expect(order.pickNext(Self.ref(4132), in: .fix))
        let picked = try #require(Self.fixNext(order))
        #expect(picked.isPicked && UpNextView.offersLetBriefBarChoose(picked, order: order))

        var running = Self.fixes
        running[4132] = StageFacts(role: .author)
        Self.tell(order, running)
        let waiting = try #require(Self.fixNext(order))
        #expect(waiting.card.ref == Self.ref(4131) && !waiting.isPicked)
        #expect(UpNextView.offersLetBriefBarChoose(waiting, order: order))

        order.letBriefBarChoose(.fix)
        #expect(order.picks.isEmpty)
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
        let chosenByBriefBar = try #require(Self.fixNext(order))
        #expect(!UpNextView.offersLetBriefBarChoose(chosenByBriefBar, order: order))
        Self.tell(order, Self.fixes)
        #expect(Self.fixNext(order)?.card.ref == Self.ref(4131))
        #expect(Self.fixNext(order)?.isPicked == false)
    }

    /// Fix next's choice waits while its build runs again, not needing you, and comes first once it fails again. It waits
    /// too until Azure DevOps' lists are read, and while Pull Request Order is off, unused.
    @Test func aChoiceWaitsWhileItsPullRequestCantSayWhereItIs() {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        Self.tell(order, Self.fixes)
        #expect(order.pickNext(Self.ref(4132), in: .fix))

        var running = Self.fixes
        running[4132] = StageFacts(role: .author)
        Self.tell(order, running)
        #expect(order.stage(of: Self.ref(4132))?.stage == .teammateReview)
        #expect(Self.fixNext(order)?.card.ref == Self.ref(4131))
        #expect(Self.fixNext(order)?.isPicked == false)
        Self.tell(order, Self.fixes)
        #expect(Self.fixNext(order)?.card.ref == Self.ref(4132))

        order.withdraw(.azureDevOps)
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4132)]))
        order.setOn(false)
        #expect(order.picks.isEmpty)
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4132)]))
        #expect(!order.pickNext(Self.ref(4131), in: .fix))
        order.setOn(true)
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4132)]))
        Self.tell(order, Self.fixes)
        #expect(Self.fixNext(order)?.card.ref == Self.ref(4132))
    }

    /// What you choose of a pull request listed only because someone sent it in a chat stays in memory, Pull Request Order
    /// off or on, until you watch it, as what you change of its mission does; another account forgets it.
    @Test func aChoiceOfOneSentInAChatStaysInMemory() {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        let sent = Self.ref(4150)
        func tell(_ role: StageFacts.Role, account: String = Self.account) {
            order.publish(
                .azureDevOps, pullRequests: [Self.ado(4150), Self.ado(4088)],
                stages: [
                    sent: StageFacts(role: role, asksYou: "Priya sent it in Teams", since: Date(timeIntervalSince1970: 1_791_500_000)),
                    Self.ref(4088): StageFacts(role: .reviewer, asksYou: "Sam asked you", since: Date(timeIntervalSince1970: 1_791_000_000)),
                ],
                account: account, inMemory: role == .sentToYou ? [sent] : []
            )
        }
        tell(.sentToYou)
        #expect(order.board(kinds: Self.kinds).upNext.slots.first?.card.ref == Self.ref(4088))
        #expect(order.pickNext(sent, in: .yourReview))
        #expect(order.board(kinds: Self.kinds).upNext.slots.first?.card.ref == sent)
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
        #expect(order.keepsStages)

        order.setOn(false)
        order.setOn(true)
        #expect(order.picks == UpNextPicks([.yourReview: sent]))
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
        // Merged, it leaves the lists: what you chose of it stays in memory still.
        order.publish(
            .azureDevOps, pullRequests: [Self.ado(4088)],
            stages: [
                Self.ref(4088): StageFacts(role: .reviewer, asksYou: "Sam asked you", since: Date(timeIntervalSince1970: 1_791_000_000)),
            ],
            account: Self.account
        )
        #expect(order.picks == UpNextPicks([.yourReview: sent]))
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)

        // You watch it: it's kept in the preferences.
        tell(.watching)
        #expect(Self.kept(defaults) == UpNextPicks([.yourReview: sent]))

        tell(.sentToYou)
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
        #expect(order.picks == UpNextPicks([.yourReview: sent]))
        tell(.sentToYou, account: "sam@contoso.com")
        #expect(order.picks.isEmpty)
    }

    /// Forget Stages… forgets what you chose too, with every account, also what it kept in memory, which doesn't come back
    /// as Pull Request Order turns on again, or as an account signs in again; and so does turning Azure DevOps off.
    @Test func forgettingStagesOrAzureDevOpsForgetsWhatYouChose() {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults)
        Self.tell(order, Self.fixes)
        #expect(!order.keepsStages)
        #expect(order.pickNext(Self.ref(4133), in: .fix))
        #expect(order.keepsStages)
        Self.tell(order, Self.fixes, account: "sam@contoso.com")
        #expect(order.pickNext(Self.ref(4132), in: .fix))
        order.forgetStages()
        #expect(order.picks.isEmpty)
        #expect(!order.keepsStages)
        #expect(Self.fixNext(order)?.card.ref == Self.ref(4131))
        Self.tell(order, Self.fixes)
        #expect(order.picks.isEmpty)
        #expect(!order.keepsStages)

        // One someone sent you in a chat, kept in memory.
        let sent = Self.ref(4150)
        order.publish(
            .azureDevOps, pullRequests: [Self.ado(4150), Self.ado(4088)],
            stages: [
                sent: StageFacts(role: .sentToYou, asksYou: "Priya sent it in Teams", since: Date(timeIntervalSince1970: 1_791_500_000)),
                Self.ref(4088): StageFacts(role: .reviewer, asksYou: "Sam asked you", since: Date(timeIntervalSince1970: 1_791_000_000)),
            ],
            account: Self.account, inMemory: [sent]
        )
        #expect(order.pickNext(sent, in: .yourReview))
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
        #expect(order.keepsStages)
        order.forgetStages()
        #expect(order.picks.isEmpty)
        #expect(!order.keepsStages)
        order.setOn(false)
        order.setOn(true)
        #expect(order.picks.isEmpty)

        Self.tell(order, Self.fixes)
        #expect(order.pickNext(Self.ref(4133), in: .fix))
        order.forget(.azureDevOps)
        #expect(order.picks.isEmpty)
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
        Self.tell(order, Self.fixes)
        #expect(order.picks.isEmpty)
    }

    /// One you chose before BriefBar knew which account signed in stays in memory, and is kept with that account once it
    /// does, over what the account chose before.
    @Test func aChoiceBeforeBriefBarKnowsTheAccountIsKeptWithItOnceItDoes() {
        let defaults = MemoryDefaults()
        let earlier = Self.service(defaults)
        Self.tell(earlier, Self.fixes)
        #expect(earlier.pickNext(Self.ref(4132), in: .fix))
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4132)]))

        let order = Self.service(defaults)
        order.publish(
            .azureDevOps, pullRequests: Self.fixes.keys.sorted().map(Self.ado),
            stages: Dictionary(uniqueKeysWithValues: Self.fixes.map { (Self.ref($0.key), $0.value) }), listsRead: ["contoso"]
        )
        #expect(order.picks.isEmpty)
        #expect(order.pickNext(Self.ref(4133), in: .fix))
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4133)]))
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4132)]))
        #expect(order.keepsStages)

        Self.tell(order, Self.fixes)
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4133)]))
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4133)]))
    }

    /// Two reviews: Sam's waited longer, so BriefBar's order puts it first.
    private static let reviews: [Int: StageFacts] = [
        4202: StageFacts(role: .reviewer, asksYou: "Sam asked you", since: Date(timeIntervalSince1970: 1_791_000_000)),
        4203: StageFacts(role: .reviewer, asksYou: "Priya asked you", since: Date(timeIntervalSince1970: 1_791_500_000)),
    ]

    private static func yourReview(_ order: PullRequestOrder) -> UpNext.Slot? {
        order.board(kinds: kinds).upNext.slots.first { $0.kind == .yourReview }
    }

    /// One whose pull request left your lists, read in full, is away too. You approve the review you chose, and its author
    /// completes it: the reviewing list has only active pull requests, and Done only yours, so no list has it. Half an
    /// hour later the choice goes, rather than stay for good, and nothing's left to forget; asked to review it again a
    /// month later, it's BriefBar's order's. So with one you're taken off.
    @Test func aChoiceWhosePullRequestLeftYourListsGoesHalfAnHourLater() throws {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let order = Self.service(defaults, now: { now })
        Self.tell(order, Self.reviews)
        #expect(Self.yourReview(order)?.card.ref == Self.ref(4202))
        #expect(order.pickNext(Self.ref(4203), in: .yourReview))

        var approved = Self.reviews
        approved[4203] = StageFacts(role: .reviewer, votes: "10", since: Date(timeIntervalSince1970: 1_791_500_000))
        Self.tell(order, approved)
        #expect(order.stage(of: Self.ref(4203)) == nil)
        now += 300
        Self.tell(order, [4202: Self.reviews[4202]!])
        #expect(order.picks == UpNextPicks([.yourReview: Self.ref(4203)]))
        now += UpNextPicks.awayFor - 300
        order.timePassed()
        #expect(order.picks.isEmpty)
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
        let slot = try #require(Self.yourReview(order))
        #expect(slot.card.ref == Self.ref(4202) && !slot.isPicked)
        #expect(!UpNextView.offersLetBriefBarChoose(slot, order: order))
        #expect(!order.keepsStages)

        now += 31 * 86_400
        Self.tell(order, Self.reviews)
        #expect(Self.yourReview(order)?.card.ref == Self.ref(4202))
        #expect(Self.yourReview(order)?.isPicked == false)

        // Chosen again, and you're taken off it: no list has it, and it goes half an hour later.
        #expect(order.pickNext(Self.ref(4203), in: .yourReview))
        Self.tell(order, [4202: Self.reviews[4202]!])
        now += UpNextPicks.awayFor - 1
        order.timePassed()
        #expect(order.picks == UpNextPicks([.yourReview: Self.ref(4203)]))
        now += 1
        order.timePassed()
        #expect(order.picks.isEmpty)
        #expect(Self.kept(defaults).isEmpty)
    }

    /// The same once BriefBar starts again: the pull request of yours you chose merged while it was closed, and Done no
    /// longer has it by then.
    @Test func aChoiceWhosePullRequestMergedWhileBriefBarWasClosedGoes() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let order = Self.service(defaults, now: { now })
        Self.tell(order, Self.fixes)
        #expect(order.pickNext(Self.ref(4133), in: .fix))

        now += 3 * 86_400
        let again = Self.service(defaults, now: { now })
        var left = Self.fixes
        left[4133] = nil
        Self.tell(again, left)
        #expect(again.picks == UpNextPicks([.fix: Self.ref(4133)]))
        now += UpNextPicks.awayFor
        again.timePassed()
        #expect(again.picks.isEmpty)
        #expect(UpNextPicks.Kept.load(from: defaults).isEmpty)
        #expect(!again.keepsStages)
    }

    /// One BriefBar reads by its link, as one sent to you in a chat that you watch, isn't in its organization's lists, as
    /// you're not on it: while it isn't listed, as when its read failed and waits an hour to be tried again, it waits,
    /// though those lists were read. Once Azure DevOps says it's closed, no list has it, and it goes half an hour later.
    @Test func aChoiceReadByItsLinkWaitsWhileItIsntRead() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        var watched = Self.reviews
        watched[4207] = StageFacts(role: .watching, asksYou: "Priya sent it in Teams", since: Date(timeIntervalSince1970: 1_791_600_000))
        let order = Self.service(defaults, now: { now })
        Self.tell(order, watched)
        #expect(order.pickNext(Self.ref(4207), in: .yourReview))

        // BriefBar starts again: Contoso's lists are read, and its link can't be, for two hours.
        now += 86_400
        let again = Self.service(defaults, now: { now })
        Self.tell(again, Self.reviews, unreadLinks: [Self.ref(4207)])
        now += 2 * 3_600
        again.timePassed()
        #expect(again.picks == UpNextPicks([.yourReview: Self.ref(4207)]))

        // Read by it, it's closed.
        Self.tell(again, Self.reviews)
        now += UpNextPicks.awayFor - 1
        again.timePassed()
        #expect(again.picks == UpNextPicks([.yourReview: Self.ref(4207)]))
        now += 1
        again.timePassed()
        #expect(again.picks.isEmpty)
        #expect(UpNextPicks.Kept.load(from: defaults).isEmpty)
    }

    /// A pull request in another organization, Fabrikam's.
    private static let fabrikam = ItemRef.pullRequest(organization: "Fabrikam", number: 77)

    /// What Azure DevOps tells: the fixes, and Fabrikam's pull request with these facts, or not at all, with the lists of
    /// these organizations read in full.
    private static func tell(
        _ order: PullRequestOrder, fabrikam facts: StageFacts?, account: String = account, listed: Bool = true, listsRead: Set<String>
    ) {
        var stages = Dictionary(uniqueKeysWithValues: Self.fixes.map { (Self.ref($0.key), $0.value) })
        var pullRequests = Self.fixes.keys.sorted().map(Self.ado)
        if let facts {
            stages[fabrikam] = facts
            pullRequests.append(OrderPullRequest(
                ref: fabrikam, repository: "fabrikam/0b4e1c77/api", sourceBranch: "robin/retry", targetBranch: "main",
                author: "robin", createdAt: Date(timeIntervalSince1970: 1_791_300_000)
            ))
        }
        order.publish(
            .azureDevOps, pullRequests: pullRequests, stages: stages, account: account, listed: listed, listsRead: listsRead
        )
    }

    /// One whose source can't tell where it is waits, however long: while the lists of its organization aren't read, as
    /// when the Azure CLI isn't signed in to its directory, and before Azure DevOps has read its lists since BriefBar
    /// started, or after it read nothing, as offline. Once they're read without it, it's away, and goes half an hour later.
    @Test func aChoiceWaitsUntilTheListsOfItsOrganizationAreRead() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let failed = StageFacts(role: .author, failure: "Build failed", since: Date(timeIntervalSince1970: 1_791_300_000))
        let order = Self.service(defaults, now: { now })
        Self.tell(order, fabrikam: failed, listsRead: ["contoso", "Fabrikam"])
        #expect(order.pickNext(Self.fabrikam, in: .fix))

        // BriefBar starts again: only Contoso's lists can be read, for a week.
        now += 86_400
        let again = Self.service(defaults, now: { now })
        Self.tell(again, fabrikam: nil, listsRead: ["contoso"])
        now += 7 * 86_400
        again.timePassed()
        #expect(again.picks == UpNextPicks([.fix: Self.fabrikam]))
        // Offline: what it read before is all it has.
        Self.tell(again, fabrikam: nil, listed: false, listsRead: ["contoso", "Fabrikam"])
        now += UpNextPicks.awayFor
        again.timePassed()
        #expect(again.picks == UpNextPicks([.fix: Self.fabrikam]))

        // Fabrikam's lists are read, without it.
        Self.tell(again, fabrikam: nil, listsRead: ["contoso", "Fabrikam"])
        now += UpNextPicks.awayFor - 1
        again.timePassed()
        #expect(again.picks == UpNextPicks([.fix: Self.fabrikam]))
        now += 1
        again.timePassed()
        #expect(again.picks.isEmpty)
        #expect(UpNextPicks.Kept.load(from: defaults).isEmpty)
    }

    /// What one account chose waits while another is signed in: it isn't the other's choice, and doesn't go, though the
    /// other's lists don't have its pull request. Each account's is kept apart, and once one signs in again, what it chose
    /// is chosen again, BriefBar started again or not.
    @Test func whatAnotherAccountChoseWaitsUntilItSignsInAgain() throws {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let sam = "Sam@contoso.com"
        let order = Self.service(defaults, now: { now })
        Self.tell(order, Self.fixes)
        #expect(order.pickNext(Self.ref(4133), in: .fix))

        Self.tell(order, Self.fixes, account: sam)
        #expect(order.picks.isEmpty)
        let sams = try #require(Self.fixNext(order))
        #expect(sams.card.ref == Self.ref(4131) && !sams.isPicked)
        #expect(!UpNextView.offersLetBriefBarChoose(sams, order: order))
        #expect(order.pickNext(Self.ref(4132), in: .fix))
        var without = Self.fixes
        without[4133] = nil
        Self.tell(order, without, account: sam)
        now += 2 * 3_600
        order.timePassed()
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4132)]))
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4133)]))
        #expect(Self.kept(defaults, for: sam) == UpNextPicks([.fix: Self.ref(4132)]))

        Self.tell(order, Self.fixes)
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4133)]))
        #expect(Self.fixNext(order)?.card.ref == Self.ref(4133))
        #expect(Self.fixNext(order)?.isPicked == true)
        let again = Self.service(defaults, now: { now })
        Self.tell(again, Self.fixes, account: sam)
        #expect(again.picks == UpNextPicks([.fix: Self.ref(4132)]))
    }

    /// How long a choice has been away is as the account signed in saw it: once another signs in, its own choice of the
    /// same pull request for the same slot has its half hour, rather than go on how long the other's was away; and so
    /// does the other's once it signs in again.
    @Test func anotherAccountsChoiceOfTheSamePullRequestHasItsOwnHalfHour() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let sam = "sam@contoso.com"
        let order = Self.service(defaults, now: { now })
        Self.tell(order, Self.reviews, account: sam)
        #expect(order.pickNext(Self.ref(4203), in: .yourReview))
        Self.tell(order, Self.reviews)
        #expect(order.pickNext(Self.ref(4203), in: .yourReview))

        // Robin approves it, and nothing changes for half an hour.
        var approved = Self.reviews
        approved[4203] = StageFacts(role: .reviewer, votes: "10", since: Date(timeIntervalSince1970: 1_791_500_000))
        Self.tell(order, approved)
        now += UpNextPicks.awayFor

        // Sam signs in, still asked to review it.
        Self.tell(order, Self.reviews, account: sam)
        #expect(order.picks == UpNextPicks([.yourReview: Self.ref(4203)]))
        #expect(Self.yourReview(order)?.card.ref == Self.ref(4203))
        #expect(Self.kept(defaults, for: sam) == UpNextPicks([.yourReview: Self.ref(4203)]))

        // Robin signs in again: Robin's goes half an hour later, and Sam's stays.
        Self.tell(order, approved)
        #expect(order.picks == UpNextPicks([.yourReview: Self.ref(4203)]))
        now += UpNextPicks.awayFor - 1
        order.timePassed()
        #expect(order.picks == UpNextPicks([.yourReview: Self.ref(4203)]))
        now += 1
        order.timePassed()
        #expect(order.picks.isEmpty)
        #expect(Self.kept(defaults).isEmpty)
        #expect(Self.kept(defaults, for: sam) == UpNextPicks([.yourReview: Self.ref(4203)]))
    }

    /// What one account chose stays in the preferences though another account's lists had its pull request only because
    /// someone sent it in a chat, as before its own lists are read once it signs in again; it goes to memory, as a stage you
    /// set does, once its own lists have it only from a chat.
    @Test func anotherAccountsChatsDontTakeWhatAnAccountChoseOutOfThePreferences() {
        let defaults = MemoryDefaults()
        let sam = "sam@contoso.com"
        let sent = StageFacts(role: .sentToYou, asksYou: "Priya sent it in Teams", since: Date(timeIntervalSince1970: 1_791_500_000))
        func tellSent(_ order: PullRequestOrder, account: String) {
            order.publish(
                .azureDevOps, pullRequests: [Self.ado(4202), Self.ado(4203)],
                stages: [Self.ref(4202): Self.reviews[4202]!, Self.ref(4203): sent], account: account,
                inMemory: [Self.ref(4203)], listsRead: ["contoso"]
            )
        }
        let order = Self.service(defaults)
        Self.tell(order, Self.reviews, account: sam)
        #expect(order.pickNext(Self.ref(4203), in: .yourReview))

        // Robin's lists have it only because Priya sent it in Teams; then Sam signs in again, whose lists aren't read yet.
        tellSent(order, account: Self.account)
        Self.tell(order, [:], account: sam, listed: false)
        #expect(order.picks == UpNextPicks([.yourReview: Self.ref(4203)]))
        #expect(Self.kept(defaults, for: sam) == UpNextPicks([.yourReview: Self.ref(4203)]))
        let again = Self.service(defaults)
        Self.tell(again, Self.reviews, account: sam)
        #expect(again.picks == UpNextPicks([.yourReview: Self.ref(4203)]))

        // Sam's own lists have it only from a chat now: it stays chosen, in memory only.
        tellSent(again, account: sam)
        #expect(again.picks == UpNextPicks([.yourReview: Self.ref(4203)]))
        #expect(Self.kept(defaults, for: sam).isEmpty)
    }

    /// As a stage you set, what you chose goes once no list has had its pull request for 30 days, with any account: one
    /// another account chose, which never signs in again, and one of the account signed in that waits, as while its
    /// organization's lists can't be read. One a list has stays, noted once a day.
    @Test func aChoiceNoListHasHadFor30DaysGoes() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let sam = "sam@contoso.com"
        let asked = StageFacts(role: .reviewer, asksYou: "Kai asked you", since: Date(timeIntervalSince1970: 1_791_300_000))
        let order = Self.service(defaults, now: { now })
        Self.tell(order, Self.fixes)
        #expect(order.pickNext(Self.ref(4133), in: .fix))
        Self.tell(order, fabrikam: asked, account: sam, listsRead: ["contoso", "fabrikam"])
        #expect(order.pickNext(Self.ref(4131), in: .fix))
        #expect(order.pickNext(Self.fabrikam, in: .yourReview))

        // BriefBar starts again, and only Contoso's lists can be read, for a month.
        let again = Self.service(defaults, now: { now })
        Self.tell(again, fabrikam: nil, account: sam, listsRead: ["contoso"])
        for _ in 1...30 {
            now += 86_400
            again.timePassed()
        }
        #expect(again.picks == UpNextPicks([.fix: Self.ref(4131), .yourReview: Self.fabrikam]))
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4133)]))
        // That a list has 4131 is noted in the preferences too, so the 30 days count from then once BriefBar starts again.
        #expect(UpNextPicks.Kept.load(from: defaults).accounts[sam]?[.fix]?.listedAt == now)
        now += 1
        again.timePassed()
        #expect(again.picks == UpNextPicks([.fix: Self.ref(4131)]))
        #expect(Self.kept(defaults, for: sam) == UpNextPicks([.fix: Self.ref(4131)]))
    }

    /// That's for Azure DevOps as a whole: once it reads some of your lists, what you chose in an organization whose lists
    /// it doesn't read, as one you no longer watch, counts from when a list last had it, across a restart too, so the 30
    /// days still end it, rather than start again each time BriefBar does.
    @Test func aChoiceInAnOrganizationItNoLongerReadsStillGoesAfterAMonthAway() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let failed = StageFacts(role: .author, failure: "Build failed", since: Date(timeIntervalSince1970: 1_791_300_000))
        let order = Self.service(defaults, now: { now })
        Self.tell(order, fabrikam: failed, listsRead: ["contoso", "fabrikam"])
        #expect(order.pickNext(Self.fabrikam, in: .fix))

        now += 35 * 86_400
        let again = Self.service(defaults, now: { now })
        Self.tell(again, fabrikam: nil, listsRead: ["contoso"])
        #expect(again.picks == UpNextPicks([.fix: Self.fabrikam]))
        now += 3_600
        again.timePassed()
        #expect(again.picks.isEmpty)
        #expect(UpNextPicks.Kept.load(from: defaults).isEmpty)
        #expect(Self.kept(defaults).isEmpty)
        Self.tell(again, Self.fixes)
        #expect(again.picks.isEmpty)
    }

    /// Back after five weeks, BriefBar starts while Azure DevOps can't be read yet, as when the Azure CLI wants you to sign
    /// in again: what you chose waits, though the clock looks first, as no list could note yet that it has the pull
    /// request. Once the lists are read, one they have stays, and what another account chose, which they can't have, goes
    /// at the clock's next look, more than 30 days after a list last had it.
    @Test func aChoiceOutlastsAMonthAwayUntilTheListsAreRead() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let sam = "sam@contoso.com"
        let order = Self.service(defaults, now: { now })
        Self.tell(order, Self.fixes, account: sam)
        #expect(order.pickNext(Self.ref(4131), in: .fix))
        Self.tell(order, Self.fixes)
        #expect(order.pickNext(Self.ref(4133), in: .fix))

        now += 35 * 86_400
        let again = Self.service(defaults, now: { now })
        Self.tell(again, [:], listed: false, listsRead: [])
        now += 3_600
        again.timePassed()
        #expect(again.picks == UpNextPicks([.fix: Self.ref(4133)]))
        #expect(Self.kept(defaults, for: sam) == UpNextPicks([.fix: Self.ref(4131)]))

        Self.tell(again, Self.fixes)
        #expect(Self.fixNext(again)?.card.ref == Self.ref(4133))
        now += 3_600
        again.timePassed()
        #expect(again.picks == UpNextPicks([.fix: Self.ref(4133)]))
        #expect(Self.kept(defaults) == UpNextPicks([.fix: Self.ref(4133)]))
        #expect(Self.kept(defaults, for: sam).isEmpty)
    }

    /// What an account chose waits, as it signs in again, until its own lists are read, though another account's were:
    /// those couldn't note that they have its pull request.
    @Test func anAccountsChoiceWaitsForItsOwnListsAsItSignsInAgain() {
        let defaults = MemoryDefaults()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let sam = "sam@contoso.com"
        let order = Self.service(defaults, now: { now })
        Self.tell(order, Self.fixes, account: sam)
        #expect(order.pickNext(Self.ref(4131), in: .fix))
        Self.tell(order, Self.fixes)
        now += 29 * 86_400 + 20 * 3_600
        order.timePassed()
        #expect(Self.kept(defaults, for: sam) == UpNextPicks([.fix: Self.ref(4131)]))

        // Sam signs in again, and the clock looks, 30 days after a list last had it, before Sam's lists are read.
        Self.tell(order, [:], account: sam, listed: false, listsRead: [])
        now += 8 * 3_600
        order.timePassed()
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4131)]))
        Self.tell(order, Self.fixes, account: sam)
        now += 3_600
        order.timePassed()
        #expect(order.picks == UpNextPicks([.fix: Self.ref(4131)]))
        #expect(Self.kept(defaults, for: sam) == UpNextPicks([.fix: Self.ref(4131)]))
    }

    /// What builds from main saved before what you chose was kept for each account, each slot's reference alone, can't be
    /// read: it goes as Pull Request Order reads what it keeps, rather than keep Forget Stages… on with nothing to forget.
    @Test func whatBriefBarCantReadOfWhatYouChoseGoes() {
        let defaults = MemoryDefaults()
        defaults.set(Data(#"{"fix":"pullRequest/contoso/4133"}"#.utf8), forKey: UpNextPicks.Kept.defaultsKey)
        let order = Self.service(defaults)
        #expect(defaults.object(forKey: UpNextPicks.Kept.defaultsKey) == nil)
        #expect(!order.keepsStages)
        Self.tell(order, Self.fixes)
        #expect(order.picks.isEmpty)
        #expect(Self.fixNext(order)?.isPicked == false)
    }

    /// VoiceOver hears how many a slot's ⌄ chooses from, and with one, not "its 1 pull requests".
    @Test func voiceOverHearsHowManyASlotChoosesFrom() throws {
        let order = Self.service(MemoryDefaults())
        Self.tell(order, Self.fixes.merging([4202: Self.reviews[4202]!]) { fix, _ in fix })
        let slots = order.board(kinds: Self.kinds).upNext.slots
        #expect(UpNextView.chooserHint(try #require(slots.first { $0.kind == .fix })) == "Chooses which of its 3 pull requests it shows")
        #expect(UpNextView.chooserHint(try #require(slots.first { $0.kind == .yourReview })) == "Chooses which pull request it shows")
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
            4093: StageFacts(role: .author, state: .draft),
            4088: StageFacts(role: .reviewer, asksYou: "Priya asked you", author: "Priya"),
        ], states: [4093: .draft])
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
    /// refuses until you can change missions yourself; from Teammate's review, ⌘→ is Approved, which Azure DevOps decides.
    @Test func theKeysMoveTheCardAsItIsNow() throws {
        let order = Self.service(try Self.defaults(orders: [[4101, 4102]]))
        Self.tell(order, [4093: StageFacts(role: .author, state: .draft), 4101: StageFacts(role: .author),
                          4102: StageFacts(role: .author, isReady: true, othersVoted: true)], states: [4093: .draft])
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
        StageCommand.perform(.move(.teammateReview), on: Self.ref(4093), order: order, undo: .lane)
        #expect(Self.moves(order).key(Self.ref(4093), in: .notInAMission, forward: true)?.move
            == .refused("Azure DevOps decides when it's approved: once the reviewers it requires approve"))
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
    /// A move owes its card the keyboard's focus only where it takes it to another column of the board: not one it leaves
    /// in its column, as one set as next that still waits, which keeps the focus, nor one it takes off the board.
    @Test func aMoveOwesTheFocusOnlyWhereItTakesTheCardToAnotherColumn() {
        let moved = StageReading(stage: .yourReview, why: .set)
        #expect(OrderBoardView.owesFocus(after: moved, leaving: .inProgress))
        #expect(!OrderBoardView.owesFocus(after: moved, leaving: .yourReview))
        #expect(!OrderBoardView.owesFocus(after: StageReading(stage: .waits, why: .waitsFor([], words: "After !4102")), leaving: .waits))
        #expect(!OrderBoardView.owesFocus(after: StageReading(stage: .teammateReview, why: .finishedReview, isOnBoard: false), leaving: .yourReview))
        #expect(!OrderBoardView.owesFocus(after: nil, leaving: .yourReview))
    }

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

    /// An order of !4087, and a teammate's !4088 for the same story, apart from it, whose review you're asked for.
    private static func orderWithItsStorysOther() throws -> PullRequestOrder {
        let order = service(try defaults(orders: [[4087]]))
        let story = ItemRef.workItem(organization: "contoso", id: 5180)
        let pullRequests = [(4087, 5181), (4088, 5182)].map { number, task in
            var pullRequest = ado(number)
            pullRequest.stories = [OrderStory(ref: story, type: "User Story", task: .workItem(organization: "contoso", id: task))]
            return pullRequest
        }
        order.publish(
            .azureDevOps, pullRequests: pullRequests,
            stages: [ref(4087): StageFacts(role: .author), ref(4088): StageFacts(role: .reviewer, asksYou: "Priya asked you", author: "Priya")],
            account: account, readsStories: true
        )
        return order
    }

    /// Finished My Review on a teammate's card for the story of a mission's order, apart from it, takes it off the board:
    /// the mission's lane keeps its Undo, as for one of the order's own.
    @Test func undoStaysInTheMissionsLaneOnceACardForItsStoryLeaves() throws {
        let order = try Self.orderWithItsStorysOther()
        let key = try #require(MissionsBody.missions(order.missions, kinds: Self.kinds).first?.key)
        #expect(order.board(kinds: Self.kinds).lane(for: key)?.cards.contains { $0.ref == Self.ref(4088) } == true)

        order.finishedReview(Self.ref(4088))
        let missions = MissionsBody.missions(order.missions, kinds: Self.kinds)
        #expect(missions.first?.sameStory.map(\.ref) == [Self.ref(4088)])
        let board = order.board(kinds: Self.kinds)
        let lane = try #require(board.lane(for: key))
        #expect(!lane.cards.contains { $0.ref == Self.ref(4088) })
        let undoRefs = board.undoRefs(of: lane, missions: missions, changed: order.lastStageChange?.ref)
        #expect(undoRefs.contains(Self.ref(4088)))
        #expect(board.lanes(keepingUndoOf: order.lastStageChange?.ref, missions: missions) == board.lanes)
    }

    /// So does the mission's card in List, which lists it apart: the card shows the change's line with Undo, a line taller
    /// than once you dismiss it.
    @Test func aMissionsCardShowsTheUndoOfOneForItsStoryApartFromItsOrder() throws {
        let order = try Self.orderWithItsStorysOther()
        order.finishedReview(Self.ref(4088))
        let mission = try #require(MissionsBody.missions(order.missions, kinds: Self.kinds).first)
        #expect(mission.sameStory.map(\.ref) == [Self.ref(4088)])
        func height() -> CGFloat {
            let card = MissionCard(
                mission: mission, kinds: Self.kinds, place: nil, elsewhere: "GitHub", openElsewhere: nil, order: order
            ) { _ in nil }
            return NSHostingView(rootView: card.frame(width: 480)).fittingSize.height
        }
        let shown = height()
        order.dismissLastChange()
        #expect(order.lastStageChange == nil)
        #expect(shown > height())
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
