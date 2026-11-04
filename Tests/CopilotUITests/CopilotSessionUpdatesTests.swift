import BriefBarCore
import BriefBarUI
import CopilotCore
import Foundation
import Testing
@testable import CopilotUI

/// What the Copilot source shows of what sessions told BriefBar, with Updates from Copilot Sessions on: to Show Links,
/// what each listed session works on, until it's been idle for a day, and the pull requests it opened; to Pull Request
/// Order, those pull requests as its own, and what it works on.
@MainActor
@Suite struct CopilotSessionUpdatesTests {
    private static let cart = "a7e4c901-2b5d-4f38-9c16-0d8e3f7b2a11"
    private static let archived = "b2f9d613-4c7a-4e05-8b3d-1a6c9e0f4b12"
    private static let task = ItemRef.workItem(organization: "contoso", id: 5124)
    private static let opened = ItemRef.pullRequest(organization: "contoso", number: 4102)

    private static func ref(_ id: String) -> ItemRef {
        ItemRef.session(id)!
    }

    /// The app lists only the cart's session, last active at `updatedAt`.
    private static func state(updatedAt: Date) -> EngineSnapshot {
        EngineSnapshot(records: [
            SessionRecord(meta: SessionMeta(id: cart, name: "Show the cart's total", updatedAt: updatedAt, workspaceId: cart), log: nil),
        ])
    }

    /// With Show Links, Pull Request Order and Updates from Copilot Sessions on, and what the cart's session, and one the
    /// app no longer lists, told.
    private static func services(updatesOn: Bool = true) -> AppServices {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        defaults.set(updatesOn, forKey: SessionUpdatesSetting.defaultsKey)
        let now = Date()
        for id in [cart, archived] {
            SessionReports.change(ref(id), in: defaults, now: now) {
                $0.setWorkingOn([task], at: now)
                $0.addOpened([opened], at: now)
            }
        }
        let services = AppServices(defaults: defaults, isDemo: false)
        services.links.setOn(true)
        return services
    }

    private static func pullRequest(_ ref: ItemRef) -> OrderPullRequest {
        OrderPullRequest(
            ref: ref, repository: "contoso/7a0c4e1d/shop-web", sourceBranch: "robin/\(ref.id)", targetBranch: "main",
            author: "robin", state: .open
        )
    }

    @Test func itShowsWhatListedSessionsTold() async throws {
        let services = Self.services()
        let source = CopilotSource(services: services, paths: nil)
        source.start()
        source.store.receive(Self.state(updatedAt: Date()))
        // What the source hears of what sessions told arrives on the main queue.
        try await Task.sleep(for: .milliseconds(50))

        let graph = services.links.graph
        #expect(graph.origins(Self.ref(Self.cart), Self.task) == [.session])
        #expect(graph.origins(Self.ref(Self.cart), Self.opened) == [.copilot])
        #expect(!graph.isLinked(Self.ref(Self.archived), Self.task))
        #expect(services.pullRequestOrder.workingOn(Self.ref(Self.cart)) == [Self.task])
        #expect(source.store.orderSessions.map(\.ref) == [Self.ref(Self.cart)])
        #expect(source.store.orderSessions.first?.pullRequests == [Self.opened])
        source.stop()
    }

    @Test func aSessionIdleForADayWorksOnNothing() async throws {
        let services = Self.services()
        let source = CopilotSource(services: services, paths: nil)
        source.start()
        source.store.receive(Self.state(updatedAt: Date().addingTimeInterval(-2 * 86_400)))
        try await Task.sleep(for: .milliseconds(50))

        let graph = services.links.graph
        #expect(!graph.isLinked(Self.ref(Self.cart), Self.task))
        #expect(graph.isLinked(Self.ref(Self.cart), Self.opened))
        #expect(services.pullRequestOrder.workingOn(Self.ref(Self.cart)).isEmpty)
        source.stop()
    }

    @Test func offItShowsNothingSessionsTold() async throws {
        let services = Self.services(updatesOn: false)
        let source = CopilotSource(services: services, paths: nil)
        services.pullRequestOrder.publish(.azureDevOps, pullRequests: [Self.pullRequest(Self.opened)])
        source.start()
        source.store.receive(Self.state(updatedAt: Date()))
        try await Task.sleep(for: .milliseconds(50))

        #expect(services.links.graph.items.isEmpty)
        #expect(source.store.orderSessions.isEmpty)
        #expect(services.pullRequestOrder.workingOn(Self.ref(Self.cart)).isEmpty)
        source.stop()
    }
}
