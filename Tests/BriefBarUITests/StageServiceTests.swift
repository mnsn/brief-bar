import BriefBarCore
import BriefBarUI
import Foundation
import SwiftUI
import Testing

/// The time, as a test moves it on.
@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)

    func advance(days: Double = 0, seconds: TimeInterval = 0) {
        now = now.addingTimeInterval(days * 86_400 + seconds)
    }
}

/// Pull Request Order's stages, as the app keeps them: from what Azure DevOps and the Copilot app tell, with what you set,
/// for each account, Undo, Let BriefBar Decide, what ends a stage you set, and what's forgotten when.
@MainActor
@Suite struct StageServiceTests {
    private static let repository = "contoso/7d3f9a12/shop-web"
    private static let account = "robin@contoso.com"
    private static let cart = ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b")!

    private static func ref(_ number: Int) -> ItemRef {
        .pullRequest(organization: "contoso", number: number)
    }

    private static func ado(_ number: Int, from source: String = "robin/work", state: PullRequestState = .open) -> OrderPullRequest {
        OrderPullRequest(
            ref: ref(number), repository: repository, sourceBranch: source + "-\(number)", targetBranch: "main", author: "robin",
            state: state, createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
        )
    }

    private static func defaults(on: Bool = true) -> MemoryDefaults {
        let defaults = MemoryDefaults()
        if on { defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey) }
        return defaults
    }

    private static func service(_ defaults: MemoryDefaults, clock: Clock = Clock()) -> PullRequestOrder {
        PullRequestOrder(defaults: defaults, isDemo: false, now: { clock.now })
    }

    /// What Azure DevOps tells: these pull requests, each with its facts.
    private static func tell(
        _ order: PullRequestOrder, _ facts: [Int: StageFacts], states: [Int: PullRequestState] = [:], account: String? = account
    ) {
        order.publish(
            .azureDevOps, pullRequests: facts.keys.sorted().map { ado($0, state: states[$0] ?? .open) },
            stages: Dictionary(uniqueKeysWithValues: facts.map { (ref($0.key), $0.value) }), account: account
        )
    }

    /// What the Copilot app tells: one session, on these pull requests, in this state since then.
    private static func tellSession(_ order: PullRequestOrder, on numbers: [Int], state: ItemState?, since: Date) {
        order.publish(
            .copilot, sessions: [OrderSession(ref: cart, pullRequests: numbers.map(ref))],
            items: [LinkedItem(ref: cart, label: "Cart", title: "Cart", symbol: "bolt.fill", color: .blue, state: state, date: since)]
        )
    }

    private static func why(_ order: PullRequestOrder, _ number: Int) -> String? {
        order.stage(of: ref(number)).map { StageText.why($0, name: order.name(of:)) }
    }

    @Test func itWorksStagesOutOnlyWhileOn() {
        let defaults = Self.defaults(on: false)
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.stages.isEmpty)

        order.setOn(true)
        Self.tell(order, [4093: StageFacts(role: .author), 4094: StageFacts(role: .reviewer)])
        #expect(order.stages.keys.sorted() == [Self.ref(4093)])
        #expect(Self.why(order, 4093) == "Find a reviewer")

        order.setOn(false)
        #expect(order.stages.isEmpty)
    }

    @Test func aStageYouSetIsKeptForTheAccountAndUndoPutsBackWhatItReplaced() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author, votes: "0", commit: "a1b2c3d")])

        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == true)
        #expect(order.lastChange?.words == "Moved !4093 to Your review")
        let kept = StageMarks.load(from: defaults)
        #expect(kept.mark(of: Self.ref(4093), for: Self.account)?.stage == .yourReview)
        #expect(kept.mark(of: Self.ref(4093), for: Self.account)?.commit == "a1b2c3d")
        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .unchanged)

        #expect(order.finishedReview(Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        order.undo()
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.lastChange == nil)

        order.letBriefBarDecide(Self.ref(4093))
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(order.lastChange?.words == "Let BriefBar decide !4093's stage")
        #expect(StageMarks.load(from: defaults).isEmpty)
        order.undo()
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        order.dismissLastChange()
        #expect(order.lastChange == nil)
    }

    @Test func onlyTheThreeStagesCanBeSetAndOnlyWhereTheSourceTellsStages() {
        let order = Self.service(Self.defaults())
        Self.tell(order, [4093: StageFacts(role: .author, isReady: true)])
        #expect(order.setStage(.canMerge, of: Self.ref(4093)) != .done)
        #expect(order.setStage(.merged, of: Self.ref(4093)) != .done)
        #expect(order.setStage(.yourReview, of: Self.ref(4999)) != .done)
        #expect(order.stage(of: Self.ref(4093))?.stage == .canMerge)
    }

    @Test func eachAccountHasItsOwnStages() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)])
        order.setStage(.inProgress, of: Self.ref(4093))

        Self.tell(order, [4093: StageFacts(role: .author)], account: "robin@fabrikam.com")
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.stage(of: Self.ref(4093))?.stage == .inProgress)
    }

    @Test func oneOnlySentToYouKeepsItsStageInMemoryUntilItsListed() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4120: StageFacts(role: .sentToYou, asksYou: "Priya sent it in Teams")])
        #expect(order.setStage(.inProgress, of: Self.ref(4120)) == .done)
        #expect(order.stage(of: Self.ref(4120))?.stage == .inProgress)
        #expect(defaults.object(forKey: StageMarks.defaultsKey) == nil)
        #expect(order.keepsStages)

        // Asked to review it now, it's kept with the account.
        Self.tell(order, [4120: StageFacts(role: .reviewer, asksYou: "Priya asked you")])
        #expect(order.stage(of: Self.ref(4120))?.stage == .inProgress)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4120), for: Self.account)?.stage == .inProgress)
    }

    @Test func beforeBriefBarKnowsTheAccountItsInMemory() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)], account: nil)
        order.setStage(.yourReview, of: Self.ref(4093))
        #expect(defaults.object(forKey: StageMarks.defaultsKey) == nil)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account)?.stage == .yourReview)
    }

    @Test func aSetInProgressGoesOnceNewCommitsComeAndAnyGoesAsItMerges() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author, commit: "a1b2c3d"), 4094: StageFacts(role: .author)])
        order.setStage(.inProgress, of: Self.ref(4093))
        order.setStage(.yourReview, of: Self.ref(4094))

        Self.tell(order, [4093: StageFacts(role: .author, commit: "e4f5a6b"), 4094: StageFacts(role: .author)])
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account) == nil)

        Self.tell(order, [4093: StageFacts(role: .author), 4094: StageFacts(role: .author, state: .merged)], states: [4094: .merged])
        #expect(order.stage(of: Self.ref(4094))?.stage == .merged)
        #expect(StageMarks.load(from: defaults).isEmpty)
    }

    @Test func aSessionAtWorkThenDoneMovesItAsTheCopilotAppTellsIt() {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author)])
        Self.tellSession(order, on: [4093], state: .running, since: clock.now)
        #expect(order.stage(of: Self.ref(4093))?.stage == .inProgress)
        #expect(Self.why(order, 4093) == "‘Cart’ is writing it")

        clock.advance(seconds: 600)
        Self.tellSession(order, on: [4093], state: .done, since: clock.now)
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(Self.why(order, 4093) == "‘Cart’ finished")

        // Your Finished My Review stands over it, until the session works on it again.
        order.finishedReview(Self.ref(4093))
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        clock.advance(seconds: 60)
        Self.tellSession(order, on: [4093], state: .needsYou, since: clock.now)
        #expect(Self.why(order, 4093) == "‘Cart’ asks you")
    }

    @Test func readyItWaitsForWhatItsOrderPutsFirstUntilBriefBarSeesItMerge() throws {
        let defaults = Self.defaults()
        var orders = DeclaredOrders()
        try orders.apply(
            OrderRequest(entries: [
                .init(link: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/4101"),
                .init(link: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/4102", after: ["4101"]),
            ]),
            now: Date(timeIntervalSince1970: 1_791_900_000)
        )
        orders.save(to: defaults)
        let order = Self.service(defaults)
        let ready = StageFacts(role: .author, isReady: true, othersVoted: true)
        Self.tell(order, [4101: StageFacts(role: .author), 4102: ready])
        #expect(order.stage(of: Self.ref(4102))?.stage == .waits)
        #expect(Self.why(order, 4102) == "After !4101")

        Self.tell(order, [4101: StageFacts(role: .author, state: .merged), 4102: ready], states: [4101: .merged])
        #expect(order.stage(of: Self.ref(4102))?.stage == .canMerge)
    }

    @Test func turningAzureDevOpsOffForgetsItsStagesEvenWhileOrderIsOff() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)])
        order.setStage(.yourReview, of: Self.ref(4093))
        order.setOn(false)
        #expect(defaults.object(forKey: StageMarks.defaultsKey) != nil)

        order.forget(.github)
        #expect(defaults.object(forKey: StageMarks.defaultsKey) != nil)
        order.forget(.azureDevOps)
        #expect(defaults.object(forKey: StageMarks.defaultsKey) == nil)
    }

    @Test func offKeepsThemAndForgetStagesForgetsThem() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)])
        order.setStage(.yourReview, of: Self.ref(4093))
        order.setOn(false)
        #expect(order.keepsStages)
        order.setOn(true)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)

        order.forgetStages()
        #expect(!order.keepsStages)
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
    }

    @Test func oneNoListHasHadFor30DaysGoes() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author), 4094: StageFacts(role: .author)])
        order.setStage(.yourReview, of: Self.ref(4093))
        order.setStage(.yourReview, of: Self.ref(4094))

        // Listed now and then, 4094 stays; no longer listed, 4093 goes after 30 days.
        for _ in 0..<31 {
            clock.advance(days: 1)
            Self.tell(order, [4094: StageFacts(role: .author)])
            order.timePassed()
        }
        let kept = StageMarks.load(from: defaults)
        #expect(kept.mark(of: Self.ref(4093), for: Self.account) == nil)
        #expect(kept.mark(of: Self.ref(4094), for: Self.account) != nil)
    }

    /// Missions draw each pull request in its stage's color, and one BriefBar saw merge in Merged's where its source tells
    /// stages, listed or not; GitHub's, which tells none, as they were.
    @Test func theGraphTakesStagesColorsAndMergedsWhereTheSourceTellsStages() {
        let order = Self.service(Self.defaults())
        let merged = OrderStep(ref: Self.ref(4074), status: .merged, standing: .merged)
        let onGitHub = OrderStep(ref: .gitHubPullRequest(repository: "contoso/shop-web", number: 412), status: .merged, standing: .merged)
        #expect(order.drawnStage(of: merged) == nil)

        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.drawnStage(of: OrderStep(ref: Self.ref(4093), status: .open, standing: .next)) == .teammateReview)
        #expect(order.drawnStage(of: merged) == .merged)
        #expect(order.drawnStage(of: onGitHub) == nil)
        #expect(order.drawnStage(of: OrderStep(ref: Self.ref(4120), status: .open, standing: .anyTime)) == nil)

        order.setOn(false)
        #expect(order.drawnStage(of: merged) == nil)
    }

    /// One you watch keeps the stage you set in the preferences, as what you've seen of it is kept; one only sent to you
    /// keeps it in memory.
    @Test func oneYouWatchKeepsItsStageInThePreferences() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4113: StageFacts(role: .watching), 4114: StageFacts(role: .sentToYou)])

        #expect(order.setStage(.yourReview, of: Self.ref(4113)) == .done)
        #expect(order.setStage(.yourReview, of: Self.ref(4114)) == .done)
        let kept = StageMarks.load(from: defaults)
        #expect(kept.mark(of: Self.ref(4113), for: Self.account)?.stage == .yourReview)
        #expect(kept.mark(of: Self.ref(4114), for: Self.account) == nil)
        #expect(order.stage(of: Self.ref(4114))?.stage == .yourReview)
    }

    /// The demo sets its stages as you would have, once their pull requests are listed, holding as they are now; never
    /// outside the demo, and not over one you set.
    @Test func theDemoSetsItsStagesOnceTheirPullRequestsAreListed() {
        let clock = Clock()
        let demo = PullRequestOrder(defaults: Self.defaults(), isDemo: true, now: { clock.now })
        let earlier = clock.now.addingTimeInterval(-2 * 3_600)
        let stages = [Self.ref(4105): StageMark(stage: .teammateReview, at: earlier), Self.ref(4106): StageMark(stage: .yourReview, at: earlier)]
        demo.tellDemo(stages: stages)
        #expect(demo.stages.isEmpty)

        Self.tell(demo, [4105: StageFacts(role: .author, votes: "0", commit: "c4105"), 4106: StageFacts(role: .author)])
        demo.setStage(.inProgress, of: Self.ref(4106))
        demo.tellDemo(stages: stages)
        let reading = demo.stage(of: Self.ref(4105))
        #expect(reading?.stage == .teammateReview && reading?.why == .findReviewer)
        #expect(reading?.mark?.at == earlier && reading?.mark?.votes == "0" && reading?.mark?.commit == "c4105")
        #expect(demo.stage(of: Self.ref(4106))?.stage == .inProgress)

        let real = Self.service(Self.defaults())
        Self.tell(real, [4105: StageFacts(role: .author)])
        real.tellDemo(stages: stages)
        #expect(real.stage(of: Self.ref(4105))?.mark == nil)
    }
}
