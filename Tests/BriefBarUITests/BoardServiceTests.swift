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

    private static func tell(_ order: PullRequestOrder, _ facts: [Int: StageFacts]) {
        order.publish(
            .azureDevOps, pullRequests: facts.keys.sorted().map(ado),
            stages: Dictionary(uniqueKeysWithValues: facts.map { (ref($0.key), $0.value) }), account: account
        )
    }

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
        #expect(order.lastChange == nil)
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
}
