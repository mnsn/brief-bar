import BriefBarCore
import BriefBarUI
import CopilotCore
import Foundation
import Testing
@testable import CopilotUI

/// What Copilot tells Pull Request Order: the sessions that opened pull requests, as the app records them, and the sessions
/// that coordinate them, only while it's on.
@MainActor
@Suite struct CopilotOrderTests {
    private static let coordinator = "3c1d7e52-9a40-4b6f-8e21-5f0b2c7d9a10"
    private static let cart = "a7e4c901-2b5d-4f38-9c16-0d8e3f7b2a11"
    private static let rounding = "b2f9d613-4c7a-4e05-8b3d-1a6c9e0f4b12"

    private static func link(_ number: Int) -> RecordedPullRequest {
        RecordedPullRequest(
            repository: nil, number: nil, url: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/\(number)",
            role: .opened
        )
    }

    /// A coordinator, and the two sessions it started, which each opened a pull request; as the engine reads them with
    /// where their work goes, or without.
    private static func state(withLinks: Bool) -> EngineSnapshot {
        func session(_ id: String, _ name: String, coordinator: String? = nil, _ links: [RecordedPullRequest] = []) -> SessionRecord {
            SessionRecord(meta: SessionMeta(
                id: id, name: name, updatedAt: Date(timeIntervalSince1970: 1_792_000_000), coordinatorSessionId: coordinator,
                parentSessionId: coordinator, workspaceId: id, links: withLinks && !links.isEmpty ? SessionLinks(pullRequests: links) : nil
            ), log: nil)
        }
        return EngineSnapshot(records: [
            session(coordinator, "Ship the cart"),
            session(cart, "Show the cart's total", coordinator: coordinator, [link(4101)]),
            session(rounding, "Round coupon totals", coordinator: coordinator, [link(4102)]),
        ])
    }

    private static func ref(_ id: String) -> ItemRef {
        ItemRef.session(id)!
    }

    private static func pullRequest(_ number: Int) -> OrderPullRequest {
        OrderPullRequest(
            ref: .pullRequest(organization: "contoso", number: number), repository: "contoso/7a0c4e1d/shop-web",
            sourceBranch: "robin/\(number)", targetBranch: "main", author: "robin", state: .open
        )
    }

    @Test func theStoreSaysWhichSessionsOpenedPullRequestsOnceItReadsWhereTheirWorkGoes() {
        let store = SessionStore(settings: AppSettings(defaults: MemoryDefaults()), paths: nil)

        store.receive(Self.state(withLinks: false))
        #expect(store.orderSessions.isEmpty)

        store.receive(Self.state(withLinks: true))
        #expect(store.orderSessions == [
            OrderSession(ref: Self.ref(Self.cart), parent: Self.ref(Self.coordinator), coordinator: Self.ref(Self.coordinator),
                         pullRequests: [.pullRequest(organization: "contoso", number: 4101)]),
            OrderSession(ref: Self.ref(Self.rounding), parent: Self.ref(Self.coordinator), coordinator: Self.ref(Self.coordinator),
                         pullRequests: [.pullRequest(organization: "contoso", number: 4102)]),
        ])

        store.stop()
        #expect(store.orderSessions.isEmpty)
    }

    /// While Pull Request Order is on, the pull requests sessions opened under the same coordinator go together, and the
    /// coordinator is named by what Copilot says it is; once Copilot stops, nothing of it is left.
    @Test func itTellsPullRequestOrderWhichSessionsOpenedWhat() throws {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let services = AppServices(defaults: defaults, isDemo: false)
        services.links.setOn(false)
        let source = CopilotSource(services: services, paths: nil)
        let order = services.pullRequestOrder
        order.publish(.azureDevOps, pullRequests: [Self.pullRequest(4101), Self.pullRequest(4102)])
        source.start()

        source.store.receive(Self.state(withLinks: true))

        let mission = try #require(order.missions.first)
        #expect(mission.key == .family(Self.ref(Self.coordinator)))
        #expect(mission.steps.map(\.session) == [Self.ref(Self.cart), Self.ref(Self.rounding)])
        #expect(mission.sessions.first == Self.ref(Self.coordinator))
        #expect(order.describe(Self.ref(Self.coordinator))?.title == "Ship the cart")

        source.stop()

        #expect(order.missions.isEmpty)
        #expect(order.describe(Self.ref(Self.coordinator)) == nil)
    }

    /// Off, it tells nothing.
    @Test func whileOffItTellsNothing() {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: false)
        let source = CopilotSource(services: services, paths: nil)
        source.start()

        source.store.receive(Self.state(withLinks: true))

        #expect(!services.pullRequestOrder.isOn)
        #expect(services.pullRequestOrder.describe(Self.ref(Self.coordinator)) == nil)
        source.stop()
    }
}
