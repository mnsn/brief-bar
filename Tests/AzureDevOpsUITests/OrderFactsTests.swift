import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

@MainActor
@Suite struct OrderFactsTests {
    private static let me = DemoData.me

    private static func pullRequest(
        _ number: Int, from source: String, into target: String = "main", status: PullRequest.Status = .active, draft: Bool = false,
        author: Person = me
    ) -> PullRequest {
        PullRequest(
            key: PRKey("Contoso", number), title: "Pull request \(number)", status: status, author: author,
            createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number)), projectId: "7A0C4E1D", projectName: "Storefront",
            repositoryId: "Repository-Shop", repositoryName: "shop-web", sourceBranch: source, targetBranch: target, isDraft: draft
        )
    }

    private static func link(_ ref: ItemRef) -> String {
        switch ref.kind {
        case .gitHubPullRequest: return "https://github.com/\(ref.scope)/pull/\(ref.id)"
        default: return "https://dev.azure.com/\(ref.scope)/Storefront/_git/shop-web/pullrequest/\(ref.id)"
        }
    }

    /// Pull Request Order, on, with an order of !4085, then !4093 after it.
    private static func order() throws -> (PullRequestOrder, MemoryDefaults) {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: link(.pullRequest(organization: "contoso", number: 4085))),
            .init(link: link(.pullRequest(organization: "contoso", number: 4093)), after: ["4085"]),
        ]))
        orders.save(to: defaults)
        return (PullRequestOrder(defaults: defaults, isDemo: false), defaults)
    }

    private static func demoStore() async -> PRStore {
        let store = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await store.loadOnce()
        return store
    }

    @Test func aPullRequestIsWhereItsSourceShowsItWithWhatAnOrderNeeds() throws {
        let seen = try #require(PullRequestOrderFacts.pullRequest(Self.pullRequest(4103, from: "robin/totals"), attention: .needsYou))
        #expect(seen == OrderPullRequest(
            ref: .pullRequest(organization: "contoso", number: 4103), repository: "contoso/7a0c4e1d/repository-shop",
            sourceBranch: "robin/totals", targetBranch: "main", author: Self.me.id, state: .open, attention: .needsYou,
            createdAt: Date(timeIntervalSince1970: 1_791_004_103)
        ))
        // Azure DevOps doesn't say, as BriefBar reads it, whether it's a fork's, or which branch is the default.
        #expect(seen.isFork == nil && seen.defaultBranch == nil && seen.stack == nil)
        let states: [(PullRequest.Status, Bool, PullRequestState?)] = [
            (.active, true, .draft), (.completed, false, .merged), (.abandoned, false, .closed), (.other, false, nil),
        ]
        for (status, draft, state) in states {
            let pullRequest = Self.pullRequest(4103, from: "robin/totals", status: status, draft: draft)
            #expect(PullRequestOrderFacts.pullRequest(pullRequest, attention: nil)?.state == state, "\(status)")
        }
    }

    /// What each means for you is what its group counts in the menu bar: To Review only while it counts there.
    @Test func whatEachMeansForYouIsWhatItsGroupCounts() async throws {
        let store = await Self.demoStore()
        func attention(_ number: Int, showToReview: Bool) -> ItemState?? {
            PullRequestOrderFacts.pullRequests(store.records, items: store.items, showToReview: showToReview)
                .first { $0.ref == .pullRequest(organization: "contoso", number: number) }.map(\.attention)
        }
        #expect(attention(4102, showToReview: false) == .some(.needsYou))
        #expect(attention(4091, showToReview: false) == .some(.done))
        #expect(attention(4071, showToReview: false) == .some(nil))
        #expect(attention(4071, showToReview: true) == .some(.needsYou))
        #expect(attention(4085, showToReview: false) == .some(nil))
        let merged = PullRequestOrderFacts.pullRequests(store.records, items: store.items, showToReview: false)
            .first { $0.ref == .pullRequest(organization: "contoso", number: 4085) }
        #expect(merged?.state == .merged)
    }

    /// While Pull Request Order is on, the list's pull requests go to it, with what BriefBar sees in Done; a pull request an
    /// order waits for is next once it merged, and stays merged after Done drops it.
    @Test func itTellsPullRequestOrderWhatTheListShows() async throws {
        let store = await Self.demoStore()
        let (order, defaults) = try Self.order()
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)

        facts.publish()

        let mission = try #require(order.missions.first)
        #expect(mission.steps.map(\.status) == [.merged, .open])
        #expect(mission.steps.last?.standing == .next)
        #expect(OrderEvidence.load(from: defaults).records[.pullRequest(organization: "contoso", number: 4085)]?.outcome == .merged)
        let accountPage = try #require(order.describe(.pullRequest(organization: "contoso", number: 4093)))
        #expect(accountPage.label == "!4093" && accountPage.title == "Add dark mode to the account page")
        #expect(accountPage.status == PRGroup.ready.title && accountPage.open != nil && accountPage.show != nil)
        // Its details show only on a window's Pull Requests page.
        #expect(accountPage.show?() == false)

        facts.stop()

        #expect(order.describe(.pullRequest(organization: "contoso", number: 4093)) == nil)
        #expect(order.missions.first?.steps.map(\.status) == [.merged, .unknown(.sourceOff)])
    }

    /// Off, it tells nothing.
    @Test func whileOffItTellsNothing() async throws {
        let store = await Self.demoStore()
        let defaults = MemoryDefaults()
        let order = PullRequestOrder(defaults: defaults, isDemo: false)
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)

        facts.publish()

        #expect(order.missions.isEmpty && order.describe(.pullRequest(organization: "contoso", number: 4093)) == nil)
        #expect(defaults.object(forKey: OrderEvidence.defaultsKey) == nil)
    }

    /// A pull request that targets another's branch goes after it, only when the same person opened both.
    @Test func aStackIsOnlyOnePersonsBranches() throws {
        let sam = Person(id: "6f1c1a52-0000-4000-8000-00000000b001", name: "Sam Rivera")
        let records = [
            Self.pullRequest(4103, from: "robin/totals"), Self.pullRequest(4104, from: "robin/totals-ui", into: "robin/totals"),
            Self.pullRequest(4105, from: "robin/totals-docs", into: "robin/totals", author: sam),
        ].map { PRRecord(pullRequest: $0, role: .author, me: Self.me.id) }
        let facts = OrderFacts(pullRequests: PullRequestOrderFacts.pullRequests(records, items: [], showToReview: false))

        let missions = OrderBoard.missions(facts: facts, orders: DeclaredOrders(), evidence: OrderEvidence())

        #expect(missions.map(\.key) == [.chain(.pullRequest(organization: "contoso", number: 4103))])
        #expect(missions.first?.steps.map(\.ref.id) == ["4103", "4104"])
    }

    /// The demo's order is one an agent could tell: BriefBar would keep it as it is.
    @Test func theDemosOrderIsOneAnAgentCouldTell() throws {
        let demo = try #require(DemoPullRequestOrder.orders(now: Date()).plans.first)
        var checked = DeclaredOrders()
        let told = try checked.apply(OrderRequest(session: demo.declaredBy?.id, entries: demo.entries.map { entry in
            let review: OrderRequest.Review? = switch entry.review {
            case nil: nil
            case .now?: .now
            case .after(let refs, let reason)?: .after(refs.map(Self.link), reason: reason.rawValue)
            }
            return OrderRequest.Entry(link: Self.link(entry.ref), after: entry.after.map(Self.link), review: review)
        }))
        #expect(told.entries == demo.entries && told.declaredBy == DemoPullRequestOrder.coordinator)
    }

    /// In the demo, it's on, with the demo's order: the account page's next, and the emails' can't be seen.
    @Test func theDemoHasItsOrder() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true)
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        order.tellDemo(DemoPullRequestOrder.orders(now: store.now))

        facts.publish()

        let mission = try #require(order.missions.first { $0.key == .plan(DemoPullRequestOrder.id) })
        let steps = Dictionary(uniqueKeysWithValues: mission.steps.map { ($0.ref, $0) })
        #expect(steps[DemoPullRequestOrder.accountPage]?.standing == .next)
        #expect(steps[DemoPullRequestOrder.emails]?.status == .unknown(.notListed))
        #expect(steps[DemoPullRequestOrder.checkoutPage]?.review == .after([DemoPullRequestOrder.accountPage], .buildsOnChanges))
        #expect(mission.sessions.first == DemoPullRequestOrder.coordinator)
    }
}
