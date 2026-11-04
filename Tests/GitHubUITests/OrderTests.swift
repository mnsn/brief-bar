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
