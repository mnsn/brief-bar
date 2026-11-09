import BriefBarCore
import BriefBarUI
import Foundation
import Testing

/// The time, as a test moves it on.
@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)

    func advance(days: Double = 0, seconds: TimeInterval = 0) {
        now = now.addingTimeInterval(days * 86_400 + seconds)
    }
}

/// The stages Copilot sessions set, as the app reads them from what their `--mcp` kept: shown while the Copilot app lists
/// the session, the latest winning over yours or another session's, Put Yours Back, what ends them, and what forgets them.
@MainActor
@Suite struct SessionStageServiceTests {
    private static let repository = "contoso/7d3f9a12/shop-web"
    private static let account = "robin@contoso.com"
    private static let cart = ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b")!
    private static let backoff = ItemRef.session("2b8d4f60-9a1c-4e3b-b7d5-6f8e9a0b1c2d")!

    private static func ref(_ number: Int) -> ItemRef {
        .pullRequest(organization: "contoso", number: number)
    }

    private static func defaults(on: Bool = true) -> MemoryDefaults {
        let defaults = MemoryDefaults()
        if on { defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey) }
        return defaults
    }

    private static func service(_ defaults: MemoryDefaults, clock: Clock, demo: Bool = false) -> PullRequestOrder {
        PullRequestOrder(defaults: defaults, isDemo: demo, now: { clock.now })
    }

    /// What Azure DevOps tells: these pull requests, each with its facts.
    private static func tell(_ order: PullRequestOrder, _ facts: [Int: StageFacts], states: [Int: PullRequestState] = [:]) {
        order.publish(
            .azureDevOps,
            pullRequests: facts.keys.sorted().map { number in
                OrderPullRequest(
                    ref: ref(number), repository: repository, sourceBranch: "robin/work-\(number)", targetBranch: "main",
                    author: "robin", state: states[number] ?? .open, createdAt: Date(timeIntervalSince1970: 1_791_000_000)
                )
            },
            stages: Dictionary(uniqueKeysWithValues: facts.map { (ref($0.key), $0.value) }), account: account
        )
    }

    /// What the Copilot app lists: these sessions, each doing this, on these pull requests, as the app records them.
    private static func list(
        _ order: PullRequestOrder, _ sessions: [ItemRef: StageSession.Activity], since: Date, on numbers: [Int] = []
    ) {
        order.publish(
            .copilot, sessions: sessions.keys.sorted().map { OrderSession(ref: $0, pullRequests: numbers.map(ref)) },
            items: sessions.keys.sorted().map { session in
                let name = session == cart ? "Cart" : "Retry backoff"
                return LinkedItem(ref: session, label: name, title: name, symbol: "bolt.fill", color: .blue, state: .done, date: since)
            },
            sessionActivities: sessions
        )
    }

    /// What a session's `--mcp` keeps when it sets a stage, then tells the app.
    private static func set(
        _ stage: PullRequestStage, of number: Int, by session: ItemRef, at date: Date, votes: String? = nil, commit: String? = nil,
        in defaults: MemoryDefaults, _ order: PullRequestOrder
    ) {
        SessionStages.change(session, in: defaults, now: date) {
            $0.set(StageMark(stage: stage, at: date, votes: votes, commit: commit), of: ref(number))
        }
        order.agentChanged()
    }

    private static func why(_ order: PullRequestOrder, _ number: Int) -> String? {
        order.stage(of: ref(number)).map { StageText.why($0, name: order.name(of:)) }
    }

    // MARK: What shows

    /// A session's stage shows while the Copilot app lists the session; the latest wins, yours or a session's, and says
    /// who set it; Put Yours Back makes yours the latest again.
    @Test func theLatestWinsYoursOrASessionsWhileItsSessionIsListed() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "", readAt: clock.now)])
        Self.list(order, [Self.cart: .finished], since: clock.now - 3_600)

        clock.advance(seconds: 60)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.cart)
        #expect(Self.why(order, 4093) == "‘Cart’ says it's ready")

        // You and the session finished the review: you said so first.
        clock.advance(seconds: 60)
        #expect(order.finishedReview(Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == true)

        // Later, the session says it's back on it: it shows, and yours waits to be put back.
        clock.advance(seconds: 60)
        Self.set(.inProgress, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        let reading = order.stage(of: Self.ref(4093))
        #expect(reading?.stage == .inProgress)
        #expect(reading?.replaced?.stage == .teammateReview)
        // Its words name the session: who set it says only when, and after you.
        #expect(Self.why(order, 4093) == "‘Cart’ is on it")
        #expect(reading.flatMap { StageText.who($0, now: clock.now, name: order.name(of:)) } == "set just now, after you")
        clock.advance(seconds: 60)
        #expect(order.putYoursBack(Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == true)
        #expect(order.stage(of: Self.ref(4093))?.replaced == nil)

        // Archived, it's no longer listed: what it set doesn't count, though it's kept.
        clock.advance(seconds: 60)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.cart)
        Self.list(order, [:], since: clock.now)
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == true)
        #expect(SessionStages.load(Self.cart, from: defaults) != nil)
    }

    /// Between two sessions, the later one shows.
    @Test func betweenSessionsTheLaterWins() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4102: StageFacts(role: .author, readAt: clock.now)])
        Self.list(order, [Self.cart: .finished, Self.backoff: .finished], since: clock.now - 3_600)
        Self.set(.yourReview, of: 4102, by: Self.backoff, at: clock.now + 120, in: defaults, order)
        Self.set(.teammateReview, of: 4102, by: Self.cart, at: clock.now + 60, in: defaults, order)
        #expect(order.stage(of: Self.ref(4102))?.mark?.by == Self.backoff)
        #expect(Self.why(order, 4102) == "‘Retry backoff’ says it's ready")
    }

    // MARK: How what sessions set ends

    /// Once the latest no longer stands, none of them counts: BriefBar works the stage out again, and what you and the
    /// sessions set goes, from what each keeps too, rather than come back.
    @Test func onceTheLatestEndsWhatYouAndSessionsSetGoes() throws {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "", readAt: clock.now)])
        Self.list(order, [Self.cart: .finished, Self.backoff: .finished], since: clock.now - 3_600)
        Self.set(.yourReview, of: 4093, by: Self.backoff, at: clock.now + 10, in: defaults, order)
        clock.advance(seconds: 20)
        order.setStage(.yourReview, of: Self.ref(4093))
        Self.set(.teammateReview, of: 4093, by: Self.cart, at: clock.now + 10, votes: "", in: defaults, order)
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.cart)

        // Priya approves, as the list reads after: the session's Teammate's review ends, and none counts.
        clock.advance(seconds: 60)
        Self.tell(order, [4093: StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10", readAt: clock.now)])
        #expect(order.stage(of: Self.ref(4093))?.stage == .canMerge)
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(StageMarks.load(from: defaults).isEmpty)
        #expect(!SessionStages.keepsAny(in: defaults))
    }

    /// What the list read before a session set its stage ends nothing by its votes or commit: the session read the pull
    /// request itself, just now. The list's next read does.
    @Test func aListReadBeforeASessionSetItsStageDoesntEndIt() throws {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        let read = clock.now
        Self.tell(order, [4093: StageFacts(role: .author, commit: "a1b2c3d", readAt: read)])
        Self.list(order, [Self.cart: .working], since: read - 600)
        clock.advance(seconds: 30)
        Self.set(.inProgress, of: 4093, by: Self.cart, at: clock.now, commit: "e4f5a6b", in: defaults, order)
        #expect(Self.why(order, 4093) == "‘Cart’ is on it")

        // Read again since, with the session's commit: it stands; with a newer one, it ends.
        clock.advance(seconds: 30)
        Self.tell(order, [4093: StageFacts(role: .author, commit: "e4f5a6b", readAt: clock.now)])
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.cart)
        clock.advance(seconds: 30)
        Self.tell(order, [4093: StageFacts(role: .author, commit: "c7d8e9f", readAt: clock.now)])
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(SessionStages.load(Self.cart, from: defaults) == nil)
    }

    /// A session's In progress ends as a session writing it finishes, as yours does: BriefBar works it out again.
    @Test func aSessionsInProgressEndsAsItFinishes() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, waitingFor: "Waiting on Priya", readAt: clock.now)])
        Self.list(order, [Self.cart: .working], since: clock.now - 600, on: [4093])
        clock.advance(seconds: 1)
        Self.set(.inProgress, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        #expect(order.stage(of: Self.ref(4093))?.stage == .inProgress)
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.cart)

        clock.advance(seconds: 120)
        Self.list(order, [Self.cart: .finished], since: clock.now, on: [4093])
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(Self.why(order, 4093) == "‘Cart’ finished")
        #expect(!SessionStages.keepsAny(in: defaults))
    }

    /// A session's In progress ends as it finishes, though the Copilot app doesn't record it on the pull request, nor did it
    /// say it works on it; as it works on afterwards, it doesn't put the pull request in progress.
    @Test func aSessionsInProgressEndsAsItFinishesThoughItIsntOnThePullRequest() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, waitingFor: "Waiting on Priya", readAt: clock.now)])
        Self.list(order, [Self.cart: .working], since: clock.now - 600)
        clock.advance(seconds: 1)
        Self.set(.inProgress, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        #expect(Self.why(order, 4093) == "‘Cart’ is on it")

        clock.advance(seconds: 120)
        Self.list(order, [Self.cart: .finished], since: clock.now)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(!SessionStages.keepsAny(in: defaults))

        clock.advance(seconds: 60)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        clock.advance(seconds: 60)
        Self.list(order, [Self.cart: .working], since: clock.now)
        #expect(Self.why(order, 4093) == "‘Cart’ says it's ready")
    }

    /// A session's Your review moves on as a teammate approves, as read since it was set, to Can merge once Azure DevOps
    /// says it's ready; it keeps the votes as the session read them as it set it, after its push reset Priya's, so the
    /// list's read from before ends nothing. One you set yourself stays.
    @Test func aSessionsYourReviewMovesOnAsATeammateApprovesAndYoursStays() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [
            4093: StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10", readAt: clock.now),
            4094: StageFacts(role: .author, waitingFor: "Waiting on Priya", readAt: clock.now),
        ])
        Self.list(order, [Self.cart: .finished], since: clock.now - 3_600)
        clock.advance(seconds: 60)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, votes: "", in: defaults, order)
        order.setStage(.yourReview, of: Self.ref(4094))
        #expect(Self.why(order, 4093) == "‘Cart’ says it's ready")

        clock.advance(seconds: 60)
        Self.tell(order, [
            4093: StageFacts(role: .author, waitingFor: "Waiting on Priya", readAt: clock.now),
            4094: StageFacts(role: .author, waitingFor: "Waiting on Priya", readAt: clock.now),
        ])
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.cart)

        clock.advance(seconds: 60)
        let approved = StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10", readAt: clock.now)
        Self.tell(order, [4093: approved, 4094: approved])
        #expect(order.stage(of: Self.ref(4093))?.stage == .canMerge)
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(SessionStages.load(Self.cart, from: defaults) == nil)
        #expect(order.stage(of: Self.ref(4094))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4094))?.isSetByYou == true)
    }

    /// A Your review you set lasts until you change it, also once a session that pushed says the same, as BriefBar's
    /// prompts ask: what the session says shows at once, over its own work since yours, and lasts as yours does as a
    /// teammate approves, with yours kept, and Let BriefBar Decide forgets both, as it would yours alone. Where the
    /// session's other stage replaced yours first, what it says later counts as any stage does, and once that ends, none
    /// does: yours doesn't come back.
    @Test func aSessionsYourReviewAfterYoursShowsAndLastsAsYoursDoes() async throws {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        let waiting = StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "", readAt: clock.now)
        Self.tell(order, [4093: waiting, 4094: waiting])
        Self.list(order, [Self.cart: .finished], since: clock.now - 3_600)
        clock.advance(seconds: 60)
        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        #expect(order.setStage(.yourReview, of: Self.ref(4094)) == .done)

        // You and ‘Cart’ reviewed !4094 together: it's your teammates' turn there.
        clock.advance(seconds: 60)
        let facts = [Self.ref(4093): waiting, Self.ref(4094): waiting]
        _ = try await Self.setStage("teammate_review", of: [4094], in: defaults, facts: facts, at: clock.now)
        order.agentChanged()
        #expect(order.stage(of: Self.ref(4094))?.replaced?.stage == .yourReview)

        // You sent ‘Cart’ your comments, and it's writing both.
        clock.advance(seconds: 60)
        Self.list(order, [Self.cart: .working], since: clock.now, on: [4093, 4094])
        #expect(order.stage(of: Self.ref(4093))?.stage == .inProgress)

        // It pushed to both, and says each is ready for your review, before it ends its turn.
        clock.advance(seconds: 60)
        let answer = try await Self.setStage("user_review", of: [4093, 4094], in: defaults, facts: facts, at: clock.now)
        order.agentChanged()
        #expect(answer == """
            BriefBar shows !4093 and !4094 in contoso in Your review now, set by this session; the user sees who set it, \
            and can change it.
            The user had set Your review on !4093 in contoso 3m ago already; yours lasts as theirs does, until it's \
            changed, rather than end once someone else votes.
            """)
        for number in [4093, 4094] {
            #expect(order.stage(of: Self.ref(number))?.stage == .yourReview)
            #expect(order.stage(of: Self.ref(number))?.mark?.by == Self.cart)
        }

        // It finished, and Priya approves.
        clock.advance(seconds: 60)
        Self.list(order, [Self.cart: .finished], since: clock.now, on: [4093, 4094])
        clock.advance(seconds: 60)
        let approved = StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10", readAt: clock.now)
        Self.tell(order, [4093: approved, 4094: approved])
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.cart)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account)?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4094))?.stage == .canMerge)
        #expect(order.stage(of: Self.ref(4094))?.mark == nil)

        // Let BriefBar Decide is one click away, as with yours alone, and forgets both: Azure DevOps says it's ready.
        let offered = StageAction.offered(for: order.stage(of: Self.ref(4093)), canUndo: false)
        #expect(offered.contains(.letBriefBarDecide) && !offered.contains(.putYoursBack))
        #expect(order.letBriefBarDecide(Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.stage == .canMerge)
        #expect(!SessionStages.keepsAny(in: defaults))
    }

    /// Let BriefBar Decide, where a session's Your review followed yours, forgets both, so BriefBar works the stage out
    /// again: Waits, while its order puts it after one not yet merged. Undo puts yours back.
    @Test func letBriefBarDecideForgetsTheSessionsYourReviewThatFollowedYours() async throws {
        let clock = Clock()
        let defaults = Self.defaults()
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [.init(link: Self.link(4102)), .init(link: Self.link(4093), after: ["4102"])]), now: clock.now)
        orders.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        let waiting = StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "", readAt: clock.now)
        Self.tell(order, [4093: waiting, 4102: waiting])
        Self.list(order, [Self.cart: .finished], since: clock.now - 3_600)
        clock.advance(seconds: 60)
        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        clock.advance(seconds: 60)
        _ = try await Self.setStage("user_review", of: [4093], in: defaults, facts: [Self.ref(4093): waiting], at: clock.now)
        order.agentChanged()
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.cart)

        clock.advance(seconds: 60)
        let approved = StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10", readAt: clock.now)
        Self.tell(order, [4093: approved, 4102: waiting])
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.letBriefBarDecide(Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.stage == .waits)
        #expect(Self.why(order, 4093) == "After !4102")
        #expect(!SessionStages.keepsAny(in: defaults))

        #expect(order.undo())
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == true)
    }

    /// Undo of the Your review you set takes a session's that followed it with it, rather than leave it lasting on its own;
    /// what another session set before yours, which yours replaced, is the latest again, as Undo puts it back anywhere, and
    /// it moves on as a teammate approves.
    @Test func undoTakesASessionsYourReviewThatFollowedYoursWithIt() async throws {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        let waiting = StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "", readAt: clock.now)
        Self.tell(order, [4093: waiting])
        Self.list(order, [Self.cart: .finished, Self.backoff: .finished], since: clock.now - 3_600, on: [4093])
        Self.set(.teammateReview, of: 4093, by: Self.backoff, at: clock.now, votes: "", in: defaults, order)
        clock.advance(seconds: 60)
        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        clock.advance(seconds: 60)
        _ = try await Self.setStage("user_review", of: [4093], in: defaults, facts: [Self.ref(4093): waiting], at: clock.now)
        order.agentChanged()
        #expect(Self.why(order, 4093) == "‘Cart’ says it's ready")

        #expect(order.undo())
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.backoff)
        #expect(SessionStages.load(Self.cart, from: defaults) == nil)

        clock.advance(seconds: 60)
        Self.tell(order, [4093: StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10", readAt: clock.now)])
        #expect(order.stage(of: Self.ref(4093))?.stage == .canMerge)
    }

    /// A session's Your review after its own Teammate's review replaced yours is its own report, which keeps its votes:
    /// it follows nothing, so Let BriefBar Decide isn't offered for it, and Undo of yours leaves it, to end as the votes
    /// change.
    @Test func aSessionsYourReviewAfterItReplacedYoursIsItsOwn() async throws {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        let waiting = StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "", readAt: clock.now)
        Self.tell(order, [4093: waiting])
        Self.list(order, [Self.cart: .finished], since: clock.now - 3_600, on: [4093])
        clock.advance(seconds: 60)
        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        let facts = [Self.ref(4093): waiting]
        clock.advance(seconds: 60)
        _ = try await Self.setStage("teammate_review", of: [4093], in: defaults, facts: facts, at: clock.now)
        order.agentChanged()
        #expect(order.stage(of: Self.ref(4093))?.replaced?.stage == .yourReview)
        clock.advance(seconds: 60)
        _ = try await Self.setStage("user_review", of: [4093], in: defaults, facts: facts, at: clock.now)
        order.agentChanged()
        let reading = order.stage(of: Self.ref(4093))
        #expect(reading?.mark?.by == Self.cart && reading?.mark?.votes == "" && reading?.followed == nil)
        #expect(!StageAction.offered(for: reading, canUndo: false).contains(.letBriefBarDecide))

        #expect(order.undo())
        #expect(order.stage(of: Self.ref(4093))?.mark?.by == Self.cart)

        clock.advance(seconds: 60)
        Self.tell(order, [4093: StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10", readAt: clock.now)])
        #expect(order.stage(of: Self.ref(4093))?.stage == .canMerge)
    }

    private static func link(_ number: Int) -> String {
        "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)"
    }

    /// ‘Cart’ sets these pull requests' stage with `pull_request_stage`, as its `--mcp` does, with the Copilot app listing
    /// it, as Azure DevOps reads them at `date`.
    private static func setStage(
        _ stage: String, of numbers: [Int], in defaults: MemoryDefaults, facts: [ItemRef: StageFacts], at date: Date
    ) async throws -> String {
        let (cart, account) = (Self.cart, Self.account)
        let tools = PullRequestOrderMCP.tools(
            defaults: defaults, demo: false, sourcesOn: { [.pullRequest] }, session: cart.id,
            stages: MCPStages(
                read: { refs in MCPStages.Read(account: account, facts: facts.filter { refs.contains($0.key) }) },
                sessions: { MCPStages.Sessions(listed: [cart]) }
            ),
            announce: {}, now: { date }
        )
        let tool = try #require(tools.first { $0.name == "pull_request_stage" })
        let json = #"{"pull_requests": \#(numbers), "organization": "contoso", "stage": "\#(stage)"}"#
        return try await tool.run(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    @Test func mergedOrClosedEndsWhatSessionsSet() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, readAt: clock.now), 4094: StageFacts(role: .author, readAt: clock.now)])
        Self.list(order, [Self.cart: .finished], since: clock.now - 600)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now + 1, in: defaults, order)
        Self.set(.yourReview, of: 4094, by: Self.cart, at: clock.now + 2, in: defaults, order)

        Self.tell(
            order, [4093: StageFacts(role: .author, state: .merged), 4094: StageFacts(role: .author, state: .closed)],
            states: [4093: .merged, 4094: .closed]
        )
        #expect(order.stage(of: Self.ref(4093))?.stage == .merged)
        #expect(!SessionStages.keepsAny(in: defaults))
    }

    /// What an archived session set before the latest stage that ended goes with it, rather than come back once the
    /// Copilot app lists the session again; what one set later stays; and as a pull request closes, all of it goes.
    @Test func whatAnArchivedSessionSetGoesWithTheLatestThatEnded() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        let open = StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "", readAt: clock.now)
        Self.tell(order, [4093: open, 4094: open])
        Self.list(order, [Self.cart: .finished, Self.backoff: .finished], since: clock.now - 3_600)
        clock.advance(seconds: 60)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        Self.set(.yourReview, of: 4094, by: Self.cart, at: clock.now, in: defaults, order)
        // Archived: what it set doesn't count. You finished the review; and later, another archived session says it's on it.
        Self.list(order, [Self.backoff: .finished], since: clock.now - 3_600)
        clock.advance(seconds: 60)
        #expect(order.finishedReview(Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == true)
        clock.advance(seconds: 60)
        Self.set(.inProgress, of: 4093, by: Self.backoff, at: clock.now, in: defaults, order)
        Self.list(order, [:], since: clock.now)

        // Priya approves: yours ends, and what Cart set before it goes too; what Retry backoff set later stays.
        clock.advance(seconds: 60)
        let approved = StageFacts(role: .author, waitingFor: "Waiting on Priya", othersVoted: true, votes: "10", readAt: clock.now)
        Self.tell(order, [4093: approved, 4094: open])
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(SessionStages.load(Self.cart, from: defaults)?.marks.keys.sorted() == [Self.ref(4094)])
        #expect(SessionStages.load(Self.backoff, from: defaults)?.marks.keys.sorted() == [Self.ref(4093)])
        Self.list(order, [Self.cart: .finished], since: clock.now - 3_600)
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)

        // Archived again, as 4094 closes: what it set there goes all the same.
        Self.list(order, [:], since: clock.now)
        Self.tell(order, [4093: approved, 4094: StageFacts(role: .author, state: .closed)], states: [4094: .closed])
        #expect(SessionStages.load(Self.cart, from: defaults) == nil)
    }

    /// Let BriefBar Decide takes away what sessions set before yours, which yours replaced, rather than show it again.
    @Test func letBriefBarDecideDoesntBringBackWhatASessionSetBefore() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, waitingFor: "Waiting on Priya", readAt: clock.now)])
        Self.list(order, [Self.cart: .finished], since: clock.now - 600)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now + 1, in: defaults, order)
        clock.advance(seconds: 60)
        order.setStage(.inProgress, of: Self.ref(4093))

        #expect(order.letBriefBarDecide(Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(Self.why(order, 4093) == "Waiting on Priya")
        #expect(!SessionStages.keepsAny(in: defaults))

        // Also what a session the Copilot app doesn't list now set before yours, should it list it again.
        clock.advance(seconds: 60)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        Self.list(order, [:], since: clock.now)
        clock.advance(seconds: 60)
        order.setStage(.inProgress, of: Self.ref(4093))
        #expect(order.letBriefBarDecide(Self.ref(4093)) == .done)
        #expect(!SessionStages.keepsAny(in: defaults))
    }

    /// Thirty days after a session set it, it goes.
    @Test func whatASessionSetGoesThirtyDaysLater() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, readAt: clock.now)])
        Self.list(order, [Self.cart: .finished], since: clock.now - 600)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        clock.advance(days: 31)
        order.timePassed()
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(!SessionStages.keepsAny(in: defaults))
    }

    // MARK: Forgetting

    /// Forget Stages… forgets what sessions set too; Pull Request Order off keeps it; GitHub Copilot off forgets it, and
    /// so does Azure DevOps off, of its pull requests.
    @Test func whatForgetsWhatSessionsSet() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, readAt: clock.now)])
        Self.list(order, [Self.cart: .finished], since: clock.now - 600)
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        #expect(order.keepsStages)

        order.setOn(false)
        #expect(SessionStages.keepsAny(in: defaults))
        #expect(order.keepsStages)
        order.setOn(true)
        order.forgetStages()
        #expect(!SessionStages.keepsAny(in: defaults))
        #expect(!order.keepsStages)

        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        order.forget(.azureDevOps)
        #expect(!SessionStages.keepsAny(in: defaults))
        Self.set(.yourReview, of: 4093, by: Self.cart, at: clock.now, in: defaults, order)
        order.forget(.github)
        #expect(SessionStages.keepsAny(in: defaults))
        order.forget(.copilot)
        #expect(!SessionStages.keepsAny(in: defaults))
    }

    /// The demo's sessions set their stages in memory, and its agents keep theirs in their own.
    @Test func theDemoKeepsWhatItsSessionsSetInMemory() {
        let clock = Clock()
        let defaults = Self.defaults(on: false)
        let order = Self.service(defaults, clock: clock, demo: true)
        Self.tell(order, [4093: StageFacts(role: .author, readAt: clock.now)])
        Self.list(order, [Self.cart: .finished], since: clock.now - 600)
        order.tellDemo(sessionStages: [Self.ref(4093): StageMark(stage: .yourReview, at: clock.now - 300, by: Self.cart)])
        #expect(Self.why(order, 4093) == "‘Cart’ says it's ready")
        #expect(!SessionStages.keepsAny(in: defaults))
        #expect(order.keepsStages)
        // What an agent keeps elsewhere isn't read in the demo.
        SessionStages.change(Self.cart, in: defaults, now: clock.now) {
            $0.set(StageMark(stage: .inProgress, at: clock.now), of: Self.ref(4093))
        }
        order.agentChanged()
        #expect(Self.why(order, 4093) == "‘Cart’ says it's ready")
    }
}
