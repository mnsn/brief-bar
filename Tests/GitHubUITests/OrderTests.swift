import BriefBarCore
import BriefBarUI
import Foundation
import GitHubCore
import Testing
@testable import GitHubUI

/// Pull Request Order on GitHub's side: what its query reads, told to the order while it's on, and the page's own choice.
@MainActor
@Suite struct OrderTests {
    private static func shopAPI(_ number: Int) -> ItemRef { .gitHubPullRequest(repository: "contoso/shop-api", number: number) }

    private static func shopWeb(_ number: Int) -> ItemRef { .gitHubPullRequest(repository: "contoso/shop-web", number: number) }

    /// Waits for what the main queue delivers, as the source hears Pull Request Order turned on or off.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func theStoreReadsWhatAnOrderNeedsOnlyWhileItsOn() {
        var on = false
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.ordersOn = { on }
        store.start()
        defer { store.stop() }
        #expect(!store.items.isEmpty && store.items.allSatisfy { $0.pullRequest.order == nil })

        on = true
        store.orderChanged()

        let order = Dictionary(uniqueKeysWithValues: store.items.map { item in
            (ItemRef.gitHubPullRequest(repository: item.pullRequest.repository, number: item.pullRequest.number), item.pullRequest.order)
        })
        #expect(order.values.allSatisfy { $0?.defaultBranch == "main" && $0?.isFork == false })
        #expect(order[Self.shopAPI(203)]??.baseBranch == "validate-coupons")
        #expect(order[Self.shopAPI(203)]??.stack?.number == 7)
        #expect(order[Self.shopWeb(409)]??.baseBranch == "rename-cart-service")
        #expect(order[Self.shopWeb(409)]??.stack == nil)
    }

    @Test func whileItsOnGitHubTellsTheOrderItsStacksAndReadsAgainWhenTurnedOff() async throws {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = GitHubSource(services: services)
        source.start()
        defer { source.stop() }
        let order = services.pullRequestOrder

        let stack = try #require(order.missions.first { $0.key == .stack(repository: "contoso/shop-api", number: 7) })
        #expect(stack.steps.map(\.ref) == [199, 201, 203].map(Self.shopAPI))
        #expect(stack.steps.map(\.status) == [.merged, .open, .open])
        #expect(stack.steps.compactMap(OrderText.capsule) == ["Merged", "Next to merge", "After #201 · stacked"])
        let chain = try #require(order.missions.first { $0.key == .chain(Self.shopWeb(405)) })
        #expect(chain.steps.map(\.ref) == [405, 409].map(Self.shopWeb))
        #expect(order.name(of: Self.shopWeb(409)) == "Fix the tax rounding")

        order.setOn(false)
        #expect(await eventually { source.store.items.allSatisfy { $0.pullRequest.order == nil } })
        #expect(order.missions.isEmpty)

        order.setOn(true)
        #expect(await eventually { order.missions.contains { $0.key == stack.key } })
        #expect(source.store.items.allSatisfy { $0.pullRequest.order != nil })
    }

    /// When GitHub can't answer the order's query, BriefBar reads the usual one: an order still sees the pull requests it
    /// lists, though not the branches they merge into.
    @Test func withoutTheOrdersQueryAnOrderStillSeesTheListedPullRequests() throws {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = GitHubSource(services: services)
        source.store.ordersOn = { false }
        let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let link = { (number: Int) in "https://github.com/contoso/shop-web/pull/\(number)" }
        var told = DeclaredOrders()
        try told.apply(OrderRequest(entries: [.init(link: link(405)), .init(link: link(409), after: [link(405)])]), newID: planID)
        services.pullRequestOrder.tellDemo(told)
        source.start()
        defer { source.stop() }
        let order = services.pullRequestOrder

        let mission = try #require(order.missions.first { $0.key == .plan(planID) })
        #expect(mission.steps.map(\.status) == [.open, .open])
        #expect(mission.steps.last?.standing == .waiting(open: [Self.shopWeb(405)], unknown: []))
        #expect(!order.missions.contains { $0.key == .stack(repository: "contoso/shop-api", number: 7) })
    }

    /// Pull Request Order turned on or off while a read is under way: that read used the setting as it was, so a new one
    /// starts with it as it is.
    @Test(.timeLimit(.minutes(1)))
    func turningTheOrderOnOrOffDuringAReadReadsAgain() async throws {
        let runner = FakeRunner(ProcessResult(status: 1, stderr: Data(FakeCLI.signedOut.utf8)), delay: .seconds(3_600))
        var on = false
        let store = GitHubStore(
            settings: AppSettings(defaults: MemoryDefaults()), mode: .live, makeTokens: { FakeCLI.signedOut(runner) }
        )
        store.ordersOn = { on }
        store.start()
        defer { store.stop() }
        while runner.calls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try #require(store.lastAttempt)
        try await Task.sleep(for: .milliseconds(20))

        on = true
        store.orderChanged()

        #expect(store.isRefreshing)
        #expect(try #require(store.lastAttempt) > first)
    }

    @Test func itsPicturesListByMissionOnlyWhileTheOrderIsOn() async {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = GitHubSource(services: services)
        await source.loadForRendering()
        #expect(source.extraRenderings().map(\.name) == ["pull-requests-by-mission", "pull-requests-by-mission-map"])

        services.pullRequestOrder.setOn(false)
        #expect(source.extraRenderings().isEmpty)
    }

    @Test func byMissionIsThePagesOwnChoiceAndItsKept() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.listsByMission)

        settings.listsByMission = true

        #expect(defaults.bool(forKey: AppSettings.Key.listsByMission))
        #expect(AppSettings(defaults: defaults).listsByMission)
    }
}
