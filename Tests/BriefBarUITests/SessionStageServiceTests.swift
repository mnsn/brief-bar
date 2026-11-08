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
        #expect(reading.flatMap { StageText.who($0, now: clock.now, name: order.name(of:)) } == "‘Cart’ set it just now, after you")
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
