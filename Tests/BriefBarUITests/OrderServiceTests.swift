import BriefBarCore
import BriefBarUI
import Combine
import Foundation
import SwiftUI
import Testing

/// The time, as a test moves it on.
@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)

    func advance(days: Double) {
        now = now.addingTimeInterval(days * 86_400)
    }
}

@MainActor
@Suite struct OrderServiceTests {
    private static let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private static let repository = "contoso/7d3f9a12/shop-web"

    private static func ref(_ number: Int) -> ItemRef {
        .pullRequest(organization: "contoso", number: number)
    }

    private static func link(_ number: Int) -> String {
        "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)"
    }

    /// An Azure DevOps pull request from a branch, into another.
    private static func ado(_ number: Int, from source: String, into target: String = "main", state: PullRequestState = .open)
        -> OrderPullRequest {
        OrderPullRequest(
            ref: ref(number), repository: repository, sourceBranch: source, targetBranch: target, author: "robin", state: state,
            createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
        )
    }

    /// The preferences, with an order a session told, of !4101, then !4102 after it.
    private static func defaults(on: Bool, order: [OrderRequest.Entry]? = nil) throws -> MemoryDefaults {
        let defaults = MemoryDefaults()
        if on { defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey) }
        var orders = DeclaredOrders()
        try orders.apply(
            OrderRequest(entries: order ?? [.init(link: link(4101)), .init(link: link(4102), after: ["4101"])]),
            now: Date(timeIntervalSince1970: 1_791_900_000), newID: planID
        )
        orders.save(to: defaults)
        return defaults
    }

    private static func service(_ defaults: MemoryDefaults, isDemo: Bool = false, clock: Clock = Clock()) -> PullRequestOrder {
        PullRequestOrder(defaults: defaults, isDemo: isDemo, now: { clock.now })
    }

    @Test func itsOffUntilTurnedOnAndReadsNothingMeanwhile() throws {
        let defaults = try Self.defaults(on: false)
        let order = Self.service(defaults)

        #expect(!order.isOn)
        #expect(order.orders.plans.isEmpty)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding")])
        #expect(order.missions.isEmpty)

        order.setOn(true)

        #expect(order.isOn && PullRequestOrderSetting.isOn(in: defaults))
        #expect(order.orders.plans.map(\.id) == [Self.planID])
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")])
        let mission = try #require(order.missions.first)
        #expect(mission.key == .plan(Self.planID))
        #expect(mission.steps.map(\.standing) == [.next, .waiting(open: [Self.ref(4101)], unknown: [])])
    }

    /// Off again, it shows nothing and forgets what the sources told, but keeps the orders in the preferences.
    @Test func turnedOffItKeepsTheOrdersUnused() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding")])
        order.setFocus(.plan(Self.planID))
        #expect(!order.missions.isEmpty)

        order.setOn(false)

        #expect(order.missions.isEmpty && order.orders.plans.isEmpty && order.focus == nil)
        #expect(!PullRequestOrderSetting.isOn(in: defaults))
        #expect(DeclaredOrders.load(from: defaults).plans.map(\.id) == [Self.planID])
        #expect(OrderFocus.load(from: defaults) == .plan(Self.planID))
        order.setOn(true)
        #expect(order.focus == .plan(Self.planID))
        // Each source tells it again, as it sees it on.
        #expect(order.missions.first?.steps.first?.status == .unknown(.sourceOff))
    }

    /// What a source shows: a pull request that targets another's branch goes after it, and a source that stopped can't
    /// be seen.
    @Test func missionsFollowWhatTheSourcesShow() throws {
        let order = Self.service(try Self.defaults(on: true, order: [.init(link: Self.link(4110))]))
        order.publish(.azureDevOps, pullRequests: [
            Self.ado(4103, from: "robin/totals"), Self.ado(4104, from: "robin/totals-ui", into: "robin/totals"),
        ])

        let chain = try #require(order.missions.first { $0.key == .chain(Self.ref(4103)) })
        #expect(chain.steps.map(\.ref) == [Self.ref(4103), Self.ref(4104)])
        #expect(order.missions.first { $0.key == .plan(Self.planID) }?.steps.first?.status == .unknown(.notListed))

        order.withdraw(.azureDevOps)

        #expect(order.missions.first { $0.key == .plan(Self.planID) }?.steps.first?.status == .unknown(.sourceOff))
        #expect(!order.missions.contains { $0.key == .chain(Self.ref(4103)) })
    }

    /// Once BriefBar saw a pull request an order names merge, it keeps that after Done stops listing it; of others, it
    /// keeps nothing.
    @Test func whatMergedIsKeptForWhatOrdersName() throws {
        let defaults = try Self.defaults(on: true)
        let clock = Clock()
        let order = Self.service(defaults, clock: clock)
        order.publish(.azureDevOps, pullRequests: [
            Self.ado(4101, from: "robin/rounding", state: .merged), Self.ado(4102, from: "robin/cart"),
            Self.ado(4090, from: "robin/other", state: .merged),
        ])
        let merged = clock.now

        clock.advance(days: 1)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4102, from: "robin/cart")])

        let mission = try #require(order.missions.first { $0.key == .plan(Self.planID) })
        #expect(mission.steps.map(\.status) == [.merged, .open])
        #expect(mission.steps.last?.standing == .next)
        let evidence = OrderEvidence.load(from: defaults)
        #expect(evidence.records == [Self.ref(4101): .init(outcome: .merged, observedAt: merged, witness: .list)])
    }

    /// An order whose every pull request merged or closed goes two weeks after the last, with what was kept of them, and
    /// Focus on it.
    @Test func anOrderThatFinishedGoesTwoWeeksLater() throws {
        let defaults = try Self.defaults(on: true)
        let clock = Clock()
        let order = Self.service(defaults, clock: clock)
        order.setFocus(.plan(Self.planID))
        order.publish(.azureDevOps, pullRequests: [
            Self.ado(4101, from: "robin/rounding", state: .merged), Self.ado(4102, from: "robin/cart", state: .closed),
        ])
        #expect(order.missions.first?.isFinished == true)

        clock.advance(days: 15)
        order.publish(.azureDevOps, pullRequests: [])

        #expect(order.orders.plans.isEmpty && order.missions.isEmpty && order.focus == nil)
        #expect(DeclaredOrders.load(from: defaults).plans.isEmpty)
        #expect(OrderEvidence.load(from: defaults).records.isEmpty)
        #expect(OrderFocus.load(from: defaults) == nil)
    }

    @Test func theMissionYouFocusOnComesFirstUntilItsOrderIsForgotten() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        order.publish(.azureDevOps, pullRequests: [
            Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart"),
            Self.ado(4103, from: "robin/totals"), Self.ado(4104, from: "robin/totals-ui", into: "robin/totals"),
        ])

        order.setFocus(.chain(Self.ref(4103)))

        #expect(order.missions.first?.key == .chain(Self.ref(4103)) && order.missions.first?.isFocused == true)
        #expect(OrderFocus.load(from: defaults) == .chain(Self.ref(4103)))
        order.setFocus(.plan(Self.planID))
        #expect(order.missions.first?.key == .plan(Self.planID))

        order.forget(order: Self.planID)

        #expect(order.focus == nil && OrderFocus.load(from: defaults) == nil)
        #expect(!order.missions.contains { $0.key == .plan(Self.planID) })
        #expect(DeclaredOrders.load(from: defaults).plans.isEmpty)
    }

    /// Turning a source off forgets its pull requests everywhere, though Pull Request Order is off.
    @Test func turningASourceOffForgetsItsPullRequestsEvenWhileOff() throws {
        let gitHub = "https://github.com/octo/storefront/pull/7"
        let defaults = try Self.defaults(on: false, order: [.init(link: Self.link(4101)), .init(link: gitHub, after: ["4101"])])
        OrderEvidence(records: [Self.ref(4101): .init(outcome: .merged, observedAt: Date(), witness: .list)]).save(to: defaults)
        OrderFocus.save(.chain(Self.ref(4101)), to: defaults)
        let order = Self.service(defaults)

        order.forget(.azureDevOps)

        let plan = try #require(DeclaredOrders.load(from: defaults).plans.first)
        #expect(plan.refs == [.gitHubPullRequest(repository: "octo/storefront", number: 7)] && plan.revision == 2)
        #expect(OrderEvidence.load(from: defaults).records.isEmpty)
        #expect(OrderFocus.load(from: defaults) == nil)
        #expect(!order.isOn && order.orders.plans.isEmpty)
    }

    /// Turning Copilot off forgets which sessions told the orders, and the pull requests opened under a session, when
    /// that's what you focus on.
    @Test func turningCopilotOffForgetsItsSessions() throws {
        let coordinator = try #require(ItemRef.session("3c1d7e52-9a40-4b6f-8e21-5f0b2c7d9a10"))
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(session: coordinator.id, entries: [.init(link: Self.link(4101))]), newID: Self.planID)
        orders.save(to: defaults)
        let order = Self.service(defaults)
        order.setFocus(.family(coordinator))
        order.publish(.copilot, sessions: [OrderSession(ref: coordinator, pullRequests: [Self.ref(4101)])])

        order.forget(.copilot)

        #expect(order.orders.plans.map(\.declaredBy) == [nil] && order.focus == nil)
        #expect(DeclaredOrders.load(from: defaults).plans.map(\.declaredBy) == [nil])
        #expect(OrderFocus.load(from: defaults) == nil)
        #expect(order.describe(coordinator) == nil)
    }

    @Test func forgetAllForgetsEveryOrderAndWhatWasKeptOfThem() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding", state: .merged)])
        order.setFocus(.plan(Self.planID))

        order.forgetAll()

        #expect(order.orders.plans.isEmpty && order.focus == nil && order.missions.isEmpty)
        for key in [DeclaredOrders.defaultsKey, OrderEvidence.defaultsKey, OrderFocus.defaultsKey] {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
    }

    /// What an agent tells through `--mcp` shows once the app reads the orders again, as it does when told they changed.
    @Test func anOrderAnAgentToldShowsOnceReadAgain() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        var orders = DeclaredOrders.load(from: defaults)
        let told = try orders.apply(OrderRequest(entries: [.init(link: Self.link(4120))]))
        orders.save(to: defaults)

        order.reloadOrders()

        #expect(order.orders.plans.map(\.id) == [Self.planID, told.id])
        #expect(order.missions.contains { $0.key == .plan(told.id) })
    }

    @Test func itSaysHowTheSourcesThingsLook() throws {
        let order = Self.service(try Self.defaults(on: true))
        let item = LinkedItem(
            ref: Self.ref(4101), label: "!4101", title: "Round coupon totals", symbol: "arrow.triangle.pull", color: .blue
        )

        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding")], items: [item])

        #expect(order.describe(Self.ref(4101)) == item)
        #expect(order.describe(Self.ref(4102)) == nil)
        order.withdraw(.azureDevOps)
        #expect(order.describe(Self.ref(4101)) == nil)
    }

    @Test func theDemoHasItOnWithItsOwnOrders() throws {
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, isDemo: true)
        var demo = DeclaredOrders()
        try demo.apply(OrderRequest(entries: [.init(link: Self.link(4101))]), newID: Self.planID)

        order.tellDemo(demo)
        order.tellDemo(demo)

        #expect(order.isOn && !PullRequestOrderSetting.isOn(in: defaults))
        #expect(order.orders.plans.map(\.id) == [Self.planID])
        // Never outside the demo.
        let real = Self.service(try Self.defaults(on: true, order: [.init(link: Self.link(4120))]))
        real.tellDemo(demo)
        #expect(real.orders.plans.map(\.refs) == [[Self.ref(4120)]])
    }

    // MARK: The pages

    @Test func listOrMapIsOneChoiceBothPagesRemember() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        #expect(order.view == .list)

        order.setView(.map)

        #expect(order.view == .map)
        #expect(defaults.string(forKey: OrderView.defaultsKey) == "map")
        #expect(Self.service(defaults).view == .map)
    }

    @Test func aRowsCapsuleAsksByMissionToShowItsMission() throws {
        let order = Self.service(try Self.defaults(on: true))
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")])
        var shown: [MissionKey] = []
        let context = try #require(OrderRowContext.of(Self.ref(4102), in: order.missions, isReady: true) { key in
            shown.append(key)
            order.reveal(key)
        })

        #expect(context.mission == .plan(Self.planID))
        #expect(context.sentence == "Merge after !4101 · completing it now would go against its order")
        context.open?()
        #expect(shown == [.plan(Self.planID)] && order.revealed == .plan(Self.planID))
        // Where it shows already, it has nothing to open, and one in no mission has no capsule.
        #expect(OrderRowContext.of(Self.ref(4102), in: order.missions, isReady: false)?.open == nil)
        #expect(OrderRowContext.of(Self.ref(4999), in: order.missions, isReady: false) == nil)
    }

    @Test func itSaysWhetherItKeepsAnythingWhileOffAndForgettingRedrawsWhatAsks() throws {
        #expect(!Self.service(MemoryDefaults()).keepsAnything)
        let defaults = try Self.defaults(on: false)
        let order = Self.service(defaults)
        #expect(order.keepsAnything && order.orders.plans.isEmpty)
        var changes = 0
        let watching = order.objectWillChange.sink { changes += 1 }

        order.forgetAll()

        #expect(!order.keepsAnything && changes > 0)
        withExtendedLifetime(watching) {}
        order.setOn(true)
        order.setFocus(.plan(Self.planID))
        #expect(order.keepsAnything)
    }

    @Test func itNamesWhatTheSourcesDescribe() throws {
        let order = Self.service(try Self.defaults(on: true))
        let item = LinkedItem(
            ref: Self.ref(4101), label: "!4101", title: "Round coupon totals", symbol: "arrow.triangle.pull", color: .blue
        )
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding")], items: [item])

        #expect(order.name(of: Self.ref(4101)) == "Round coupon totals")
        #expect(order.name(of: Self.ref(4102)) == nil)
    }

    /// The demo tells what BriefBar saw merge before, and the mission you focus on, once: what's kept stays.
    @Test func theDemoTellsWhatMergedBeforeAndWhatYouFocusOn() throws {
        let clock = Clock()
        let order = Self.service(MemoryDefaults(), isDemo: true, clock: clock)
        var demo = DeclaredOrders()
        try demo.apply(
            OrderRequest(entries: [.init(link: Self.link(4100)), .init(link: Self.link(4101), after: ["4100"])]), newID: Self.planID
        )
        let merged = OrderEvidence(records: [
            Self.ref(4100): OrderEvidence.Record(outcome: .merged, observedAt: clock.now.addingTimeInterval(-3_600), witness: .list),
        ])

        order.tellDemo(demo, evidence: merged, focus: .plan(Self.planID))
        order.tellDemo(demo, evidence: OrderEvidence(), focus: .chain(Self.ref(4101)))
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding")])

        #expect(order.focus == .plan(Self.planID))
        let mission = try #require(order.missions.first)
        #expect(mission.key == .plan(Self.planID) && mission.isFocused)
        #expect(mission.steps.map(\.status) == [.merged, .open])
        #expect(mission.steps.last?.standing == .next)
    }
}
