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

    /// Time alone changes missions, which its hourly clock looks at: a quiet order shows as stale after 30 days, and a
    /// finished one goes two weeks later, though the sources show nothing new.
    @Test func timeAloneMarksAQuietOrderStaleAndAFinishedOneGoes() throws {
        let defaults = try Self.defaults(on: true)
        let clock = Clock()
        let order = Self.service(defaults, clock: clock)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")])
        #expect(order.missions.first?.isStale == false)

        clock.advance(days: 31)
        order.timePassed()

        #expect(order.missions.first?.isStale == true)
        order.publish(.azureDevOps, pullRequests: [
            Self.ado(4101, from: "robin/rounding", state: .merged), Self.ado(4102, from: "robin/cart", state: .closed),
        ])
        #expect(order.missions.first?.isFinished == true)
        clock.advance(days: 15)
        order.timePassed()
        #expect(order.orders.plans.isEmpty && order.missions.isEmpty)
    }

    /// A mission's bar stays within its width, however many pull requests it has: its parts narrow, then it's one bar.
    @Test func aMissionsBarFitsItsWidthWhateverItsCount() throws {
        #expect(try #require(OrderProgressBar.parts(5)) == (width: 9, gap: 2))
        for count in 1...DeclaredOrders.mostPullRequests {
            guard let parts = OrderProgressBar.parts(count) else {
                #expect(count > 30)
                continue
            }
            let total = CGFloat(count) * parts.width + CGFloat(count - 1) * parts.gap
            #expect(total <= OrderProgressBar.widest + 0.001, "\(count) parts: \(total)")
        }
        #expect(OrderProgressBar.parts(DeclaredOrders.mostPullRequests) == nil)
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
            order.reveal(key, kinds: [.pullRequest])
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

    // MARK: Your changes

    /// A change from a Mission menu is saved, says what it did, and Undo puts back exactly what it touched.
    @Test func aChangeIsSavedSaysWhatItDidAndUndoPutsItBack() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")])

        let done = try #require(order.change(.setNext(Self.ref(4102), in: .plan(Self.planID), true)))

        #expect(done.said == "You set !4102 as next to merge" && done.canUndo && done.mission == .plan(Self.planID))
        #expect(order.lastOrderChange == done)
        #expect(OrderChanges.load(from: defaults)[Self.ref(4102)]?.isFirst == true)
        let mission = try #require(order.missions.first { $0.key == .plan(Self.planID) })
        #expect(mission.steps.map(\.ref) == [Self.ref(4102), Self.ref(4101)] && mission.steps[0].isYours)
        #expect(order.changes(in: mission) == 1)

        #expect(order.undo())
        #expect(order.changes.isEmpty && order.lastOrderChange == nil)
        #expect(defaults.object(forKey: OrderChanges.defaultsKey) == nil)
        #expect(order.missions.first { $0.key == .plan(Self.planID) }?.steps.map(\.ref) == [Self.ref(4101), Self.ref(4102)])
        #expect(!order.undo())
    }

    /// What the menu doesn't offer is refused, with why, and changes nothing.
    @Test func aRefusedChangeSaysWhyAndChangesNothing() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart", into: "robin/rounding")])

        let refused = try #require(order.change(.setNext(Self.ref(4102), in: .plan(Self.planID), true)))

        #expect(!refused.canUndo && refused.said == "Stacked on !4101: it can't merge before it unless you retarget it")
        #expect(order.changes.isEmpty && defaults.object(forKey: OrderChanges.defaultsKey) == nil)
        #expect(order.refusal == refused && order.lastOrderChange == nil)
        #expect(!order.undo())
        order.dismissRefusal()
        #expect(order.refusal == nil && order.said.isEmpty)
    }

    /// A change BriefBar refuses says why beside your last change's Undo, which stays.
    @Test func aRefusedChangeKeepsYourLastChangesUndo() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")])
        let done = try #require(order.change(.setNext(Self.ref(4102), in: .plan(Self.planID), true)))

        let refused = try #require(order.change(.setNext(Self.ref(4130), in: .plan(Self.planID), true)))

        #expect(!refused.canUndo && refused.said == "It isn't in a mission: move it to one first")
        #expect(order.lastOrderChange == done && order.refusal == refused && order.said == [refused, done])
        #expect(order.undo())
        #expect(order.changes.isEmpty && order.lastOrderChange == nil && order.refusal == nil)
    }

    /// A change to your own pull request is saved though its order puts it after one only sent to you in a chat: the order
    /// keeps that one's reference already.
    @Test func aChangeToYourOwnIsSavedThoughItsOrderNamesOneSentInAChat() throws {
        let defaults = try Self.defaults(on: true, order: [.init(link: Self.link(4102)), .init(link: Self.link(4079), after: ["4102"])])
        let order = Self.service(defaults)
        order.publish(
            .azureDevOps, pullRequests: [Self.ado(4079, from: "robin/coupons"), Self.ado(4102, from: "priya/cart")], inMemory: [Self.ref(4102)]
        )

        order.change(.setNext(Self.ref(4079), in: .plan(Self.planID), true))

        #expect(OrderChanges.load(from: defaults)[Self.ref(4079)]?.isFirst == true)
        #expect(Self.service(defaults).changes[Self.ref(4079)]?.isFirst == true)
    }

    /// An order an agent tells that goes against your change shows instead once BriefBar reads it again, and still does after
    /// BriefBar starts again, with Put Yours Back.
    @Test func anOrderAnAgentToldAgainstYoursShowsInsteadForGood() throws {
        let defaults = try Self.defaults(on: true)
        let clock = Clock()
        let order = Self.service(defaults, clock: clock)
        let pullRequests = [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart"), Self.ado(4103, from: "robin/tax")]
        order.publish(.azureDevOps, pullRequests: pullRequests)
        order.change(.setNext(Self.ref(4102), in: .plan(Self.planID), true))

        clock.advance(days: 1)
        var orders = DeclaredOrders.load(from: defaults)
        _ = try orders.apply(
            OrderRequest(plan: Self.planID.uuidString, revision: 1, entries: [
                .init(link: Self.link(4101)), .init(link: Self.link(4103)), .init(link: Self.link(4102), after: ["4101", "4103"]),
            ]),
            now: clock.now
        )
        orders.save(to: defaults)
        order.reloadOrders()

        #expect(OrderChanges.load(from: defaults)[Self.ref(4102)]?.overridden?.by == Self.planID)
        let relaunched = Self.service(defaults, clock: clock)
        relaunched.publish(.azureDevOps, pullRequests: pullRequests)
        let step = try #require(relaunched.missions.first { $0.key == .plan(Self.planID) }?.steps.first { $0.ref == Self.ref(4102) })
        #expect(Set(step.prerequisites.map(\.ref)) == [Self.ref(4101), Self.ref(4103)] && !step.isYours)
        #expect(step.notes.contains { if case .orderChangedIt = $0 { return true } else { return false } })
        #expect(relaunched.choices(for: Self.ref(4102)).canPutBack)
    }

    /// What you change of a pull request listed only because someone sent it in a chat stays in memory, until it's listed
    /// otherwise.
    @Test func changesAboutAPullRequestSentInAChatStayInMemory() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        let pullRequests = [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart"), Self.ado(4130, from: "sam/search")]
        order.publish(.azureDevOps, pullRequests: pullRequests, inMemory: [Self.ref(4130)])

        order.change(.move([Self.ref(4130)], to: .into(.plan(Self.planID)), from: nil))
        order.change(.mergeAfter(Self.ref(4101), Self.ref(4130), in: .plan(Self.planID), true))

        #expect(order.changes.count == 2)
        #expect(defaults.object(forKey: OrderChanges.defaultsKey) == nil)
        #expect(order.missions.first { $0.key == .plan(Self.planID) }?.contains(Self.ref(4130)) == true)
        // Off and on again, they're still there: only quitting BriefBar forgets them.
        order.setOn(false)
        order.setOn(true)
        #expect(order.changes.count == 2)
        // Watched now, or yours: they go to the preferences.
        order.publish(.azureDevOps, pullRequests: pullRequests)
        #expect(OrderChanges.load(from: defaults).count == 2)
        // Sent in a chat again only: back to memory.
        order.publish(.azureDevOps, pullRequests: pullRequests, inMemory: [Self.ref(4130)])
        #expect(defaults.object(forKey: OrderChanges.defaultsKey) == nil && order.changes.count == 2)
    }

    /// Off keeps your changes, unused; Forget All Orders forgets them, and says so in its words.
    @Test func turnedOffItKeepsYourChangesAndForgetAllOrdersForgetsThem() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")])
        order.change(.setNext(Self.ref(4102), in: .plan(Self.planID), true))

        order.setOn(false)
        #expect(order.changes.isEmpty && order.lastOrderChange == nil && OrderChanges.load(from: defaults).count == 1)
        #expect(order.keepsAnything)
        order.setOn(true)
        #expect(order.changes.count == 1)

        order.forgetAll()
        #expect(order.changes.isEmpty && defaults.object(forKey: OrderChanges.defaultsKey) == nil)
        #expect(PullRequestOrderSettingView.explanation.contains("change a mission yourself"))
    }

    /// Turning a source off forgets your changes to its pull requests, though Pull Request Order is off.
    @Test func turningASourceOffForgetsYourChangesToItsPullRequests() throws {
        let defaults = try Self.defaults(on: false)
        OrderChanges([
            OrderChange(ref: Self.ref(4102), first: .plan(Self.planID), changedAt: Date()),
            OrderChange(ref: .gitHubPullRequest(repository: "octo/storefront", number: 7), placement: .outside, changedAt: Date()),
        ]).save(to: defaults)
        let order = Self.service(defaults)

        order.forget(.azureDevOps)

        #expect(OrderChanges.load(from: defaults).all.map(\.ref) == [.gitHubPullRequest(repository: "octo/storefront", number: 7)])
    }

    /// A change goes two weeks after BriefBar saw its pull requests end, though no order names them; and Focus on a mission
    /// of yours goes with it.
    @Test func aChangeGoesTwoWeeksAfterItsPullRequestsEndAndFocusOnItsMissionWithIt() throws {
        let clock = Clock()
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults, clock: clock)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4140, from: "robin/estimates"), Self.ado(4141, from: "robin/one-click")])
        let mine = MissionKey.mine(UUID(uuidString: "33333333-4444-4555-8666-777777777777")!)
        order.change(.move([Self.ref(4140), Self.ref(4141)], to: .into(mine), from: nil))
        #expect(order.lastOrderChange?.said == "You made a mission of !4140 and !4141")
        order.setFocus(mine)
        #expect(order.missions.first?.key == mine && order.missions.first?.isFocused == true)

        order.publish(.azureDevOps, pullRequests: [
            Self.ado(4140, from: "robin/estimates", state: .merged), Self.ado(4141, from: "robin/one-click", state: .closed),
        ])
        order.withdraw(.azureDevOps)
        clock.advance(days: 13)
        order.timePassed()
        #expect(order.changes.count == 2)
        clock.advance(days: 2)
        order.timePassed()
        #expect(order.changes.isEmpty && defaults.object(forKey: OrderChanges.defaultsKey) == nil)
        #expect(order.focus == nil && OrderFocus.load(from: defaults) == nil)
    }

    /// The demo's changes, once, in its own memory.
    @Test func theDemoTellsYourChangesOnce() throws {
        let order = Self.service(MemoryDefaults(), isDemo: true)
        var demo = DeclaredOrders()
        try demo.apply(OrderRequest(entries: [.init(link: Self.link(4101)), .init(link: Self.link(4102), after: ["4101"])]), newID: Self.planID)
        let changes = OrderChanges([
            OrderChange(ref: Self.ref(4102), first: .plan(Self.planID), changedAt: Date(), replaced: OrderPlace(of: Self.ref(4102), in: demo)),
        ])

        order.tellDemo(demo, changes: changes)
        order.change(.setNext(Self.ref(4102), in: .plan(Self.planID), false))
        order.tellDemo(demo, changes: changes)

        #expect(order.changes.isEmpty)
    }

    /// One sent in a chat that's left the lists, merged say, is still one that was: a change that names it later, or Undo
    /// putting one back, stays in memory.
    @Test func oneSentInAChatThatLeftTheListsStillKeepsItsChangesInMemory() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        let yours = [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")]
        order.publish(.azureDevOps, pullRequests: yours + [Self.ado(4130, from: "sam/search")], inMemory: [Self.ref(4130)])
        order.change(.move([Self.ref(4130)], to: .into(.plan(Self.planID)), from: nil))
        order.change(.undo(Self.ref(4130)))

        order.publish(.azureDevOps, pullRequests: yours)
        #expect(order.undo())
        order.change(.mergeAfter(Self.ref(4101), Self.ref(4130), in: .plan(Self.planID), true))

        #expect(order.changes.count == 2)
        #expect(defaults.object(forKey: OrderChanges.defaultsKey) == nil)
    }

    /// What BriefBar sees become of one sent in a chat that only a change kept in memory names stays in memory too.
    @Test func whatMergedOfOneSentInAChatIsKeptInMemoryOnly() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        let yours = [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")]
        order.publish(.azureDevOps, pullRequests: yours + [Self.ado(4130, from: "sam/search")], inMemory: [Self.ref(4130)])
        order.change(.move([Self.ref(4130)], to: .into(.mine(UUID())), from: nil))

        order.publish(.azureDevOps, pullRequests: yours + [Self.ado(4130, from: "sam/search", state: .merged)], inMemory: [Self.ref(4130)])

        #expect(OrderEvidence.load(from: defaults).records[Self.ref(4130)] == nil)
        // Off and on again, BriefBar still knows it merged.
        order.setOn(false)
        order.setOn(true)
        order.publish(.azureDevOps, pullRequests: yours)
        #expect(order.missions.first { $0.contains(Self.ref(4130)) }?.steps.first?.status == .merged)
    }

    /// What you did shows in the card you did it from, for a pull request in two missions.
    @Test func theUndoLineIsInTheCardYouChangedItFrom() throws {
        let defaults = try Self.defaults(on: true, order: [.init(link: Self.link(4101)), .init(link: Self.link(4102))])
        let otherID = UUID(uuidString: "22222222-3333-4444-8555-666666666666")!
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [.init(link: Self.link(4102)), .init(link: Self.link(4103))]),
            now: Date(timeIntervalSince1970: 1_791_900_100), newID: otherID
        )
        orders.save(to: defaults)
        let order = Self.service(defaults)
        order.publish(.azureDevOps, pullRequests: [4101, 4102, 4103].map { Self.ado($0, from: "robin/part-\($0)") })
        let first = try #require(OrderBoard.mission(of: Self.ref(4102), in: order.missions)?.key)
        let other: MissionKey = first == .plan(Self.planID) ? .plan(otherID) : .plan(Self.planID)

        order.change(.setNext(Self.ref(4102), in: other, true))

        #expect(order.lastOrderChange?.mission == other && order.lastOrderChange?.canUndo == true)

        // A Move's shows in the card you moved it from, where you are, not in the one it went to, which can be out of sight.
        order.change(.move([Self.ref(4103)], to: .into(.mine(UUID())), from: .plan(otherID)))
        #expect(order.lastOrderChange?.mission == .plan(otherID) && order.lastOrderChange?.canUndo == true)
    }

    /// A change is made against the orders as agents last saved them, though BriefBar hasn't heard yet: what it replaced is
    /// the latest, so it holds once BriefBar hears.
    @Test func aChangeIsMadeAgainstTheOrdersAsAgentsLastSavedThem() throws {
        let defaults = try Self.defaults(on: true)
        let clock = Clock()
        let order = Self.service(defaults, clock: clock)
        order.publish(.azureDevOps, pullRequests: [4101, 4102, 4103].map { Self.ado($0, from: "robin/part-\($0)") })
        var saved = DeclaredOrders.load(from: defaults)
        try saved.apply(
            OrderRequest(
                plan: Self.planID.uuidString, revision: saved.plan(Self.planID)?.revision,
                entries: [.init(link: Self.link(4101)), .init(link: Self.link(4103)), .init(link: Self.link(4102), after: ["4101", "4103"])]
            ),
            now: clock.now.addingTimeInterval(-1), newID: Self.planID
        )
        saved.save(to: defaults)

        order.change(.setNext(Self.ref(4102), in: .plan(Self.planID), true))
        #expect(order.changes[Self.ref(4102)]?.replaced == OrderPlace(orders: [Self.planID: [Self.ref(4101), Self.ref(4103)]]))
        order.reloadOrders()
        #expect(order.changes[Self.ref(4102)]?.holds(in: order.orders) == true)
    }

    /// What BriefBar saw become of a pull request goes with the changes it's kept for: to memory once it's listed only
    /// because someone sent it in a chat, and back to the preferences once it's listed otherwise.
    @Test func whatMergedGoesWithTheChangesItsKeptFor() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        let yours = [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")]
        order.publish(.azureDevOps, pullRequests: yours + [Self.ado(4130, from: "sam/search")])
        order.change(.move([Self.ref(4130)], to: .into(.mine(UUID())), from: nil))
        let merged = yours + [Self.ado(4130, from: "sam/search", state: .merged)]
        order.publish(.azureDevOps, pullRequests: merged)
        #expect(OrderEvidence.load(from: defaults).records[Self.ref(4130)] != nil)

        order.publish(.azureDevOps, pullRequests: merged, inMemory: [Self.ref(4130)])
        #expect(OrderEvidence.load(from: defaults).records[Self.ref(4130)] == nil)
        #expect(OrderChanges.load(from: defaults)[Self.ref(4130)] == nil && order.changes[Self.ref(4130)] != nil)

        order.publish(.azureDevOps, pullRequests: merged)
        #expect(OrderEvidence.load(from: defaults).records[Self.ref(4130)] != nil)
        #expect(OrderChanges.load(from: defaults)[Self.ref(4130)] != nil)
    }

    /// Undo after a chain's anchor moved on puts back what you changed as the chain is named now: the pull request you put
    /// in it stays with the chain's others.
    @Test func undoFollowsAChainNamedByAnotherOfItsPullRequests() throws {
        let defaults = try Self.defaults(on: true, order: [.init(link: Self.link(4200))])
        let order = Self.service(defaults)
        let (first, second) = (Self.ado(4101, from: "robin/a"), Self.ado(4102, from: "robin/b", into: "robin/a"))
        let search = Self.ado(4130, from: "sam/search")
        order.publish(.azureDevOps, pullRequests: [first, second, search])
        let chain = MissionKey.chain(Self.ref(4101))
        order.change(.move([Self.ref(4130)], to: .into(chain), from: nil))
        order.change(.setNext(Self.ref(4130), in: chain, true))

        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/a", state: .merged), second, search])
        #expect(order.lastOrderChange?.touched[Self.ref(4130)]??.placement == .into(.chain(Self.ref(4102))))
        order.publish(.azureDevOps, pullRequests: [second, search])
        #expect(order.undo())

        #expect(order.changes[Self.ref(4130)]?.placement == .into(.chain(Self.ref(4102))) && order.changes[Self.ref(4130)]?.first == nil)
        #expect(OrderBoard.mission(of: Self.ref(4130), in: order.missions)?.contains(Self.ref(4102)) == true)
    }

    /// Undo puts back what BriefBar saw become of the pull requests your change was about, with it: one that merged and left
    /// the lists is still merged.
    @Test func undoPutsBackWhatBriefBarSawBecomeOfItsPullRequests() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        let yours = [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")]
        order.publish(.azureDevOps, pullRequests: yours + [Self.ado(4130, from: "sam/search")])
        let mine = MissionKey.mine(UUID())
        order.change(.move([Self.ref(4130)], to: .into(mine), from: nil))
        order.publish(.azureDevOps, pullRequests: yours + [Self.ado(4130, from: "sam/search", state: .merged)])
        order.publish(.azureDevOps, pullRequests: yours)
        #expect(OrderEvidence.load(from: defaults).records[Self.ref(4130)] != nil)

        order.change(.undoMission(mine))
        #expect(OrderEvidence.load(from: defaults).records[Self.ref(4130)] == nil)
        #expect(order.undo())

        #expect(OrderEvidence.load(from: defaults).records[Self.ref(4130)] != nil)
        let step = OrderBoard.mission(of: Self.ref(4130), in: order.missions)?.steps.first { $0.ref == Self.ref(4130) }
        #expect(step?.status == .merged)
    }

    /// Undo follows a chain named by another of its pull requests though no change of yours names it anymore, only what Undo
    /// would put back.
    @Test func undoFollowsAChainOnlyItNames() throws {
        let defaults = try Self.defaults(on: true, order: [.init(link: Self.link(4200))])
        let order = Self.service(defaults)
        let second = Self.ado(4102, from: "robin/b", into: "robin/a")
        let search = Self.ado(4130, from: "sam/search")
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/a"), second, search])
        order.change(.move([Self.ref(4130)], to: .into(.chain(Self.ref(4101))), from: nil))
        order.change(.undo(Self.ref(4130)))
        #expect(order.changes.isEmpty)

        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/a", state: .merged), second, search])
        #expect(order.lastOrderChange?.touched[Self.ref(4130)]??.placement == .into(.chain(Self.ref(4102))))
        order.publish(.azureDevOps, pullRequests: [second, search])
        #expect(order.undo())

        #expect(order.changes[Self.ref(4130)]?.placement == .into(.chain(Self.ref(4102))))
        #expect(OrderBoard.mission(of: Self.ref(4130), in: order.missions)?.contains(Self.ref(4102)) == true)
    }

    /// Turning a source off forgets your changes to its pull requests, and what BriefBar saw become of them, for good: the
    /// rebuild that follows, though one of those changes finished meanwhile, saves none of them back.
    @Test func aSourceTurnedOffForgetsItsChangesForGoodThoughOneFinishesMeanwhile() throws {
        let defaults = try Self.defaults(on: true)
        let clock = Clock()
        let order = Self.service(defaults, clock: clock)
        let gitHub = OrderPullRequest(
            ref: .gitHubPullRequest(repository: "octo/storefront", number: 7), repository: "octo/storefront", sourceBranch: "robin/shelf",
            targetBranch: "main", author: "robin", state: .open, createdAt: Date(timeIntervalSince1970: 1_791_000_007)
        )
        order.publish(.azureDevOps, pullRequests: [
            Self.ado(4101, from: "robin/rounding", state: .merged), Self.ado(4102, from: "robin/cart"),
            Self.ado(4130, from: "sam/search", state: .merged),
        ])
        order.publish(.github, pullRequests: [gitHub])
        order.change(.setNext(Self.ref(4102), in: .plan(Self.planID), true))
        order.change(.move([Self.ref(4130)], to: .into(.mine(UUID())), from: nil))
        order.change(.move([gitHub.ref], to: .into(.mine(UUID())), from: nil))
        #expect(OrderChanges.load(from: defaults).all.count == 3 && OrderEvidence.load(from: defaults).records.count == 2)

        clock.advance(days: 15)
        order.forget(.azureDevOps)

        #expect(OrderChanges.load(from: defaults).all.map(\.ref) == [gitHub.ref])
        #expect(OrderEvidence.load(from: defaults).records.isEmpty)
        #expect(order.changes.all.map(\.ref) == [gitHub.ref])
    }

    /// What BriefBar sees become of a pull request only what Undo would put back names goes with it until you click Undo:
    /// abandoned, reactivated, then merged, before it left the lists, it's merged once Undo puts your change back.
    @Test func undoPutsBackWhatBriefBarSawBecomeOfItsPullRequestsMeanwhile() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.service(defaults)
        let yours = [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")]
        let search = { (state: PullRequestState) in Self.ado(4130, from: "sam/search", state: state) }
        order.publish(.azureDevOps, pullRequests: yours + [search(.open)])
        order.change(.move([Self.ref(4130)], to: .into(.mine(UUID())), from: nil))
        order.change(.undo(Self.ref(4130)))
        #expect(order.changes.isEmpty && order.lastOrderChange?.canUndo == true)

        for state in [PullRequestState.closed, .open, .merged] {
            order.publish(.azureDevOps, pullRequests: yours + [search(state)])
        }
        order.publish(.azureDevOps, pullRequests: yours)
        #expect(order.undo())

        let step = OrderBoard.mission(of: Self.ref(4130), in: order.missions)?.steps.first { $0.ref == Self.ref(4130) }
        #expect(step?.status == .merged && step?.standing == .merged)
        #expect(OrderEvidence.load(from: defaults).records[Self.ref(4130)]?.outcome == .merged)
    }

    /// Focus on a chain follows its pull requests as the chain is named by another of them: when you move the one it's named
    /// by out of missions, and back with Undo.
    @Test func focusOnAChainFollowsItAsItsNamedByAnother() throws {
        let defaults = try Self.defaults(on: true, order: [.init(link: Self.link(4200))])
        let order = Self.service(defaults)
        let chain = [Self.ado(4101, from: "robin/a"), Self.ado(4102, from: "robin/b", into: "robin/a"), Self.ado(4103, from: "robin/c", into: "robin/b")]
        order.publish(.azureDevOps, pullRequests: chain + [Self.ado(4130, from: "sam/search")])
        order.setFocus(.chain(Self.ref(4101)))
        order.change(.move([Self.ref(4130)], to: .into(.chain(Self.ref(4101))), from: nil))
        order.change(.move([Self.ref(4101)], to: .outside, from: nil))

        #expect(order.focus == .chain(Self.ref(4102)) && OrderFocus.load(from: defaults) == .chain(Self.ref(4102)))
        #expect(order.missions.first?.key == .chain(Self.ref(4102)) && order.missions.first?.isFocused == true)
        #expect(order.missions.first?.contains(Self.ref(4130)) == true)

        #expect(order.undo())
        #expect(order.focus == .chain(Self.ref(4101)) && OrderFocus.load(from: defaults) == .chain(Self.ref(4101)))
        #expect(order.missions.first?.key == .chain(Self.ref(4101)) && order.missions.first?.isFocused == true)
    }

    /// Focus on a chain stays with its own pull requests as you move the one it's named by into another chain, which shows
    /// before them: it never goes along with that one. Undo brings it back.
    @Test func focusOnAChainStaysWithItsOwnAsYouMoveTheOneItsNamedByIntoAnother() throws {
        let defaults = try Self.defaults(on: true, order: [.init(link: Self.link(4200))])
        let order = Self.service(defaults)
        let chain = [Self.ado(4101, from: "robin/a"), Self.ado(4102, from: "robin/b", into: "robin/a"), Self.ado(4103, from: "robin/c", into: "robin/b")]
        let other = [Self.ado(4120, from: "sam/x"), Self.ado(4121, from: "sam/y", into: "sam/x")]
        order.publish(.azureDevOps, pullRequests: chain + other)
        order.setFocus(.chain(Self.ref(4101)))
        order.change(.move([Self.ref(4101)], to: .into(.chain(Self.ref(4120))), from: .chain(Self.ref(4101))))

        let date = { (key: MissionKey) in order.missions.first { $0.key == key }?.date ?? .distantPast }
        #expect(date(.chain(Self.ref(4120))) > date(.chain(Self.ref(4102))))
        #expect(order.missions.first { $0.key == .chain(Self.ref(4120)) }?.contains(Self.ref(4101)) == true)
        #expect(order.focus == .chain(Self.ref(4102)) && OrderFocus.load(from: defaults) == .chain(Self.ref(4102)))
        #expect(order.missions.first?.key == .chain(Self.ref(4102)) && order.missions.first?.isFocused == true)

        #expect(order.undo())
        #expect(order.focus == .chain(Self.ref(4101)) && OrderFocus.load(from: defaults) == .chain(Self.ref(4101)))
        #expect(order.missions.first?.key == .chain(Self.ref(4101)) && order.missions.first?.isFocused == true)
    }

    /// A Move's Undo line is in the card you moved it from, where you are: also once the chain that card was named by goes on
    /// by another of its own; and at the top of the list once that card is gone, never in the card it went to, which can be
    /// out of sight. (Moved into an order, the one a chain is named by takes the rest with it, stacked on it: that card's
    /// gone too.)
    @Test func aMovesUndoLineIsWhereYouMovedItFromOrAtTheTop() throws {
        let defaults = try Self.defaults(on: true, order: [.init(link: Self.link(4101)), .init(link: Self.link(4102))])
        let order = Self.service(defaults)
        let chain = [Self.ado(4110, from: "robin/a"), Self.ado(4111, from: "robin/b", into: "robin/a"), Self.ado(4112, from: "robin/c", into: "robin/b")]
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/x"), Self.ado(4102, from: "robin/y")] + chain)

        order.change(.move([Self.ref(4110)], to: .outside, from: .chain(Self.ref(4110))))
        #expect(order.missions.contains { $0.key == .chain(Self.ref(4111)) })
        #expect(order.lastOrderChange?.mission == .chain(Self.ref(4111)) && order.lastOrderChange?.canUndo == true)

        let mine = MissionKey.mine(UUID())
        order.change(.move([Self.ref(4112)], to: .into(mine), from: .chain(Self.ref(4111))))
        #expect(order.missions.first { $0.key == mine }?.steps.map(\.ref) == [Self.ref(4112)])
        order.change(.move([Self.ref(4112)], to: .into(.plan(Self.planID)), from: mine))
        #expect(!order.missions.contains { $0.key == mine })
        #expect(order.lastOrderChange?.mission == nil && order.lastOrderChange?.canUndo == true)
    }

    /// The ages it says go on as the time does, between changes: the names are worked out again only once the sources or the
    /// missions change, the time on every read.
    @Test func theTimeGoesOnInWhatItSaysBetweenChanges() throws {
        let defaults = try Self.defaults(on: true)
        let clock = Clock()
        let order = Self.service(defaults, clock: clock)
        order.publish(.azureDevOps, pullRequests: [Self.ado(4101, from: "robin/a"), Self.ado(4102, from: "robin/b")])
        #expect(order.names.now == clock.now)
        clock.now = clock.now.addingTimeInterval(300)
        #expect(order.names.now == clock.now)
    }

    // MARK: One Undo, for a stage or a mission

    /// The account the stages you set are kept for.
    private static let account = "robin@contoso.com"

    /// !4101, then !4102 after it, as the session's order says, each with its stage's facts: !4102 can complete, so it waits
    /// for !4101.
    private static func staged(_ defaults: MemoryDefaults) -> PullRequestOrder {
        let order = Self.service(defaults)
        order.publish(
            .azureDevOps, pullRequests: [Self.ado(4101, from: "robin/rounding"), Self.ado(4102, from: "robin/cart")],
            stages: [
                Self.ref(4101): StageFacts(role: .author, votes: "0", commit: "a1b2c3d"),
                Self.ref(4102): StageFacts(role: .author, isReady: true, votes: "0", commit: "b2c3d4e"),
            ],
            account: Self.account
        )
        return order
    }

    /// Undo puts back your last change, whichever it was: after a stage, then a mission, the mission's, and the stage
    /// stays; after a mission, then a stage, the stage, and the mission stays. Why BriefBar refused a change keeps your
    /// last change's Undo, whichever it is, until your next change, of either kind, or Undo.
    @Test func undoPutsBackYourLastChangeOfEitherKind() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.staged(defaults)
        let plan = MissionKey.plan(Self.planID)

        #expect(order.setStage(.inProgress, of: Self.ref(4101)) == .done)
        #expect(order.lastStageChange?.ref == Self.ref(4101) && order.said.isEmpty)
        let next = try #require(order.change(.setNext(Self.ref(4102), in: plan, true)))
        #expect(order.lastOrderChange == next && order.lastStageChange == nil)
        #expect(order.undo())
        #expect(order.changes.isEmpty && order.lastChange == nil)
        #expect(order.stage(of: Self.ref(4101))?.stage == .inProgress && order.stage(of: Self.ref(4101))?.mark != nil)
        #expect(!order.undo())

        let again = try #require(order.change(.setNext(Self.ref(4102), in: plan, true)))
        let refusedFirst = try #require(order.change(.setNext(Self.ref(4130), in: plan, true)))
        #expect(order.lastOrderChange == again && order.said == [refusedFirst, again])
        #expect(order.setStage(.yourReview, of: Self.ref(4101)) == .done)
        #expect(order.lastStageChange?.ref == Self.ref(4101) && order.lastOrderChange == nil && order.said.isEmpty)
        let refused = try #require(order.change(.setNext(Self.ref(4130), in: plan, true)))
        #expect(!refused.canUndo && order.refusal == refused && order.lastStageChange?.ref == Self.ref(4101))
        #expect(order.undo())
        #expect(order.stage(of: Self.ref(4101))?.stage == .inProgress && order.refusal == nil && order.lastChange == nil)
        #expect(OrderChanges.load(from: defaults)[Self.ref(4102)]?.isFirst == true)
        #expect(order.missions.first { $0.key == plan }?.steps.map(\.ref) == [Self.ref(4102), Self.ref(4101)])
    }

    /// Forgetting one kind of change forgets Undo of it, not of the other: Forget Stages… keeps Undo of a change to a
    /// mission, and Forget All Orders… Undo of a stage.
    @Test func forgettingOneKindKeepsTheOthersUndo() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.staged(defaults)

        let next = try #require(order.change(.setNext(Self.ref(4102), in: .plan(Self.planID), true)))
        order.forgetStages()
        #expect(order.lastOrderChange == next)

        #expect(order.setStage(.inProgress, of: Self.ref(4101)) == .done)
        order.forgetAll()
        #expect(order.changes.isEmpty && order.lastStageChange?.ref == Self.ref(4101))
        #expect(order.undo())
        #expect(order.stage(of: Self.ref(4101))?.mark == nil && order.lastChange == nil)
    }

    /// On the Board, a card dropped from Waits onto Can merge, or moved there with ⌘←, is set as next to merge in the
    /// mission whose lane it's in, as VoiceOver's action does; one that doesn't wait isn't, and where you can't change
    /// missions, neither is. The mission's lane then has its Undo line, and only what has no lane shows at the top of the
    /// page: with Lanes: None, everything does.
    @Test func aCardThatWaitsDroppedOnCanMergeIsSetAsNextInItsLanesMission() throws {
        let defaults = try Self.defaults(on: true)
        let order = Self.staged(defaults)
        let plan = MissionKey.plan(Self.planID)
        let board = order.board(kinds: [.pullRequest], lanes: .missions)
        let lane = try #require(board.lanes.first { $0.mission == plan })
        let waits = try #require(lane.cards.first { $0.ref == Self.ref(4102) })
        let first = try #require(lane.cards.first { $0.ref == Self.ref(4101) })
        #expect(waits.stage == .waits && waits.mission == plan && first.stage != .waits)
        let missions = order.missions.filter { $0.contains(waits.ref) }
        #expect(BoardRules.move(waits, to: .canMerge, isYours: true, missionChanges: true, missions: missions) == .setAsNext)
        let moves = BoardMoves(board: board, missions: order.missions, order: order, missionChanges: true)
        let drag = BoardDrag(ref: waits.ref)
        let dropped = try #require(moves.drop(drag.payload, of: drag, on: .canMerge, in: .mission(plan)))
        let keyed = try #require(moves.key(waits.ref, in: .mission(plan), forward: false))
        #expect(dropped.move == .setAsNext && dropped.card.mission == plan)
        #expect(keyed.move == .setAsNext && keyed.card.mission == plan)
        let unchangeable = BoardMoves(board: board, missions: order.missions, order: order, missionChanges: false)
        #expect(unchangeable.key(waits.ref, in: .mission(plan), forward: false)?.move != .setAsNext)

        var asked: [ItemRef: MissionKey] = [:]
        let tell = { (ref: ItemRef, mission: MissionKey) in asked[ref] = mission }
        #expect(OrderBoardView.setAsNext(first, with: tell) == nil)
        #expect(OrderBoardView.setAsNext(waits, with: nil) == nil)
        let set = try #require(OrderBoardView.setAsNext(waits, with: tell))
        set()
        #expect(asked == [Self.ref(4102): plan])

        MissionMenuContext.setAsNext(Self.ref(4102), in: plan, order: order)
        #expect(order.lastOrderChange?.said == "You set !4102 as next to merge" && order.lastOrderChange?.mission == plan)
        let after = order.board(kinds: [.pullRequest], lanes: .missions)
        #expect(after.lanes.first { $0.mission == plan }?.cards.first { $0.ref == Self.ref(4102) }?.stage == .canMerge)

        #expect(MissionsBody.showingTheirChanges(order.missions, board: after).contains(plan))
        #expect(MissionsBody.showingTheirChanges(order.missions, board: order.board(kinds: [.pullRequest], lanes: BoardLanes.none)).isEmpty)
        #expect(MissionsBody.showingTheirChanges(order.missions, board: nil) == Set(order.missions.map(\.key)))
    }
}
