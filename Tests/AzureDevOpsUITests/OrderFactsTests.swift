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

    /// Waits for what the main queue delivers, as the facts hear the list change.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A refresh can change what the list read of a pull request without its row, such as when it's retargeted: the order
    /// hears every refresh.
    @Test func everyRefreshTellsTheOrderAgain() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true)
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        facts.start()
        defer { facts.stop() }
        #expect(await Self.eventually { order.describe(DemoPullRequestOrder.retry) != nil })
        order.withdraw(.azureDevOps)
        #expect(order.describe(DemoPullRequestOrder.retry) == nil)

        store.refreshed.send()

        #expect(await Self.eventually { order.describe(DemoPullRequestOrder.retry) != nil })
    }

    /// The demo's story outside the sprint (§7.4): its three pull requests, for its tasks, are its mission, in the tasks'
    /// order, with no order known, and the made-up name Apple Intelligence would give it; with Show Links off, there are no
    /// stories, and they're in no mission.
    @Test func theDemosStoryIsAMissionWithAMadeUpName() async throws {
        let store = await Self.demoStore()
        let settings = AppSettings(defaults: MemoryDefaults())
        let sprint = SprintStore(settings: settings, mode: .demo, client: store.client)
        await sprint.loadOnce()
        let copilot = CopilotTasksStore(settings: settings, mode: .demo, notifier: nil)
        func facts(showLinks: Bool) async -> (PullRequestOrder, PullRequestOrderFacts, WorkLinksStore) {
            let links = Links(defaults: MemoryDefaults(), isDemo: showLinks)
            let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true, now: { store.now })
            let workLinks = WorkLinksStore(
                links: links, stories: ItemStories(links: links), store: store, sprint: sprint, copilot: copilot, settings: settings,
                order: order
            )
            await workLinks.loadOnce()
            let facts = PullRequestOrderFacts(order: order, store: store, settings: settings, details: nil, workLinks: workLinks)
            return (order, facts.loadOnce(), workLinks)
        }

        let (order, held, workLinks) = await facts(showLinks: true)
        let key = MissionKey.story(DemoPullRequestOrder.checkoutRedesign)
        let mission = try #require(order.missions.first { $0.key == key })
        #expect(mission.steps.map(\.ref.id) == ["4113", "4088", "4105"])
        #expect(mission.steps.allSatisfy { $0.standing == .unordered })
        #expect(OrderText.story(of: mission, title: order.title(of: mission)) == "User Story 5180")
        #expect(order.title(of: mission) == "Faster checkout" && order.naming(of: mission) == .appleIntelligence)
        #expect(order.name(of: DemoPullRequestOrder.checkoutRedesign) == "Checkout redesign")
        #expect(order.describe(.workItem(organization: "contoso", id: 5181))?.title == "Speed up the checkout page")
        // Each pull request goes with all its work items, for its mission's name.
        let seen = PullRequestOrderFacts.pullRequests(store.records, items: store.items, showToReview: false, stories: workLinks.storiesRead)
        #expect(seen.first { $0.ref.id == "4091" }?.workItems == [5110, 5112].map { .workItem(organization: "contoso", id: $0) })
        // The orders keep their own: their pull requests aren't a story's mission's.
        #expect(order.missions.first { $0.key == DemoPullRequestOrder.focus }?.steps.count == 5)
        _ = held

        let (withoutLinks, _, _) = await facts(showLinks: false)
        #expect(!withoutLinks.missions.contains { $0.isStory })
        #expect(!withoutLinks.missions.contains { $0.contains(.pullRequest(organization: "contoso", number: 4113)) })
    }

    /// By Mission on a window's Pull Requests page is named only while the window shows that page on screen, as it tells
    /// the source; the Sprint's page, or a popover, says nothing of it.
    @Test func byMissionIsNamedOnlyWhileAWindowShowsItsPageOnScreen() {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = AzureDevOpsSource(services: services, summarizer: .withoutModel)
        let order = services.pullRequestOrder
        let viewer = NSObject()
        let key = MissionKey.story(DemoPullRequestOrder.checkoutRedesign)
        order.showing([key], in: viewer, on: PullRequestOrder.page(.azureDevOpsPullRequests, window: "7"))
        #expect(order.onScreen.isEmpty)
        source.sectionVisibilityChanged(.azureDevOpsPullRequests, isShowing: true, by: SectionViewer(.window, id: "7"))
        #expect(order.onScreen == [key])
        source.sectionVisibilityChanged(.azureDevOpsSprint, isShowing: false, by: SectionViewer(.window, id: "7"))
        source.sectionVisibilityChanged(.azureDevOpsPullRequests, isShowing: false, by: SectionViewer(.popover, id: "7"))
        #expect(order.onScreen == [key])
        source.sectionVisibilityChanged(.azureDevOpsPullRequests, isShowing: false, by: SectionViewer(.window, id: "7"))
        #expect(order.onScreen.isEmpty)
        withExtendedLifetime(viewer) {}
    }

    /// The demo's orders are ones an agent could tell: BriefBar would keep them as they are.
    @Test func theDemosOrdersAreOnesAnAgentCouldTell() throws {
        let demos = DemoPullRequestOrder.orders(now: Date()).plans
        #expect(demos.map(\.declaredBy) == [DemoPullRequestOrder.payments, DemoPullRequestOrder.coordinator])
        for demo in demos {
            var checked = DeclaredOrders()
            let told = try checked.apply(OrderRequest(session: demo.declaredBy?.id, entries: demo.entries.map { entry in
                let review: OrderRequest.Review? = switch entry.review {
                case nil: nil
                case .now?: .now
                case .after(let refs, let reason)?: .after(refs.map(Self.link), reason: reason.rawValue)
                }
                return OrderRequest.Entry(link: Self.link(entry.ref), after: entry.after.map(Self.link), review: review)
            }))
            #expect(told.entries == demo.entries && told.declaredBy == demo.declaredBy)
        }
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

    /// The payments' order, which you focus on: the first merged yesterday, the retry is next, and the coupon rounding,
    /// ready to complete before it, says so in orange.
    @Test func theDemosPaymentsOrderIsFocusedWithOneMerged() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true, now: { store.now })
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        order.tellDemo(
            DemoPullRequestOrder.orders(now: store.now), evidence: DemoPullRequestOrder.evidence(now: store.now),
            focus: DemoPullRequestOrder.focus
        )

        facts.publish()

        let mission = try #require(order.missions.first)
        #expect(mission.key == DemoPullRequestOrder.focus && mission.isFocused)
        #expect(OrderText.progress(mission) == "1 of 5 merged")
        let steps = Dictionary(uniqueKeysWithValues: mission.steps.map { ($0.ref, $0) })
        #expect(steps[DemoPullRequestOrder.retryPolicy]?.status == .merged)
        #expect(steps[DemoPullRequestOrder.retry]?.standing == .next)
        let rounding = try #require(steps[DemoPullRequestOrder.couponRounding])
        #expect(rounding.standing == .waiting(open: [DemoPullRequestOrder.retry], unknown: []))
        let ready = try #require(store.items.first { $0.key.linkRef == DemoPullRequestOrder.couponRounding })
        #expect(ready.group == .ready)
        #expect(OrderText.tone(of: rounding, isReady: ready.group == .ready) == .warning)
        #expect(OrderText.capsule(rounding) == "After !4102")
        #expect(steps[DemoPullRequestOrder.legacyCoupons]?.review == .after([DemoPullRequestOrder.couponRounding], .sameCode))
        #expect(OrderBoard.step(for: DemoPullRequestOrder.retry, in: order.missions)?.mission.key == DemoPullRequestOrder.focus)
    }

    /// Your made-up changes in the demo hold over its orders: the order status rename goes first, the retry waits for it, and
    /// the build agents' upgrade and the slow query log are a mission of your own.
    @Test func theDemosChangesHoldOverItsOrders() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true, now: { store.now })
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        order.tellDemo(
            DemoPullRequestOrder.orders(now: store.now), evidence: DemoPullRequestOrder.evidence(now: store.now),
            focus: DemoPullRequestOrder.focus, changes: DemoPullRequestOrder.changes(now: store.now)
        )

        facts.publish()

        let payments = try #require(order.missions.first { $0.key == DemoPullRequestOrder.focus })
        let steps = Dictionary(uniqueKeysWithValues: payments.steps.map { ($0.ref, $0) })
        let rename = try #require(steps[DemoPullRequestOrder.statusRename])
        #expect(rename.standing == .next && rename.isYours && rename.isChangedByYou)
        let retry = try #require(steps[DemoPullRequestOrder.retry])
        #expect(retry.standing == .waiting(open: [DemoPullRequestOrder.statusRename], unknown: []) && retry.isYours)
        #expect(OrderText.kind(of: payments) == "changed by you")
        let yours = try #require(order.missions.first { $0.key == .mine(DemoPullRequestOrder.mineID) })
        #expect(yours.steps.map(\.ref) == [DemoPullRequestOrder.buildAgents, DemoPullRequestOrder.slowQueries])
        #expect(yours.steps.map(\.standing) == [.next, .waiting(open: [DemoPullRequestOrder.buildAgents], unknown: [])])
        #expect(OrderText.kind(of: yours) == "Your mission")
    }

    /// The pull requests listed only because someone sent them in a chat, which you don't watch.
    @Test func itSaysWhichArentYoursButSentInAChat() async throws {
        let store = await Self.demoStore()
        let sent = PullRequestOrderFacts.sentInChats(store.records, watched: [])
        let linked = store.records.filter { $0.role == .linked }.map(\.id)
        #expect(!sent.isEmpty && sent == Set(linked.map(\.linkRef)))
        #expect(PullRequestOrderFacts.sentInChats(store.records, watched: Set(linked)).isEmpty)
    }
}
