import BriefBarCore
import BriefBarUI
import CopilotCore
import Foundation
import SwiftUI
import Testing
@testable import CopilotUI

/// What Copilot tells Pull Request Order: the sessions that opened pull requests, as the app records them, and the sessions
/// that coordinate them, only while it's on.
@MainActor
@Suite struct CopilotOrderTests {
    private static let coordinator = "3c1d7e52-9a40-4b6f-8e21-5f0b2c7d9a10"
    private static let cart = "a7e4c901-2b5d-4f38-9c16-0d8e3f7b2a11"
    private static let rounding = "b2f9d613-4c7a-4e05-8b3d-1a6c9e0f4b12"
    private static let task = "c5a8e2d4-6f1b-4c97-a3e0-8b2d7f9c1e13"

    private static func link(_ number: Int) -> RecordedPullRequest {
        RecordedPullRequest(
            repository: nil, number: nil, url: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/\(number)",
            role: .opened
        )
    }

    /// A coordinator, and the two sessions it started, which each opened a pull request; as the engine reads them with
    /// where their work goes, or without.
    private static func state(withLinks: Bool, readsLinks: Bool? = nil) -> EngineSnapshot {
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
        ], readsLinks: readsLinks ?? withLinks)
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
        #expect(store.orderSessions.isEmpty && !store.hasReadLinks)

        store.receive(Self.state(withLinks: true))
        #expect(store.hasReadLinks)
        #expect(store.orderSessions == [
            OrderSession(ref: Self.ref(Self.cart), parent: Self.ref(Self.coordinator), coordinator: Self.ref(Self.coordinator),
                         pullRequests: [.pullRequest(organization: "contoso", number: 4101)]),
            OrderSession(ref: Self.ref(Self.rounding), parent: Self.ref(Self.coordinator), coordinator: Self.ref(Self.coordinator),
                         pullRequests: [.pullRequest(organization: "contoso", number: 4102)]),
        ])

        store.stop()
        #expect(store.orderSessions.isEmpty && !store.hasReadLinks)
    }

    /// Till what Copilot lists was read with where each session's work goes, Pull Request Order can't tell what a mission
    /// is made of, as its sessions may have opened more of its pull requests: it waits, and isn't asked about a split.
    @Test func whatAMissionIsMadeOfWaitsTillTheSessionsAreReadWithWhereTheirWorkGoes() async throws {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let services = AppServices(defaults: defaults, isDemo: false)
        let source = CopilotSource(services: services, paths: nil)
        let order = services.pullRequestOrder
        let story = ItemRef.workItem(organization: "contoso", id: 5100)
        let pullRequests = [4101, 4102, 4103].map { number in
            var pullRequest = Self.pullRequest(number)
            pullRequest.stories = [OrderStory(ref: story, type: "User Story", task: .workItem(organization: "contoso", id: number + 1_000))]
            pullRequest.workItems = []
            return pullRequest
        }
        order.publish(.azureDevOps, pullRequests: pullRequests, readsStories: true)
        source.start()
        func makeup() throws -> MissionSplitQuestion.Makeup? {
            let mission = try #require(order.missions.first { $0.key == .story(story) })
            return try #require(order.splitQuestion(for: mission)).makeup
        }
        // What starting tells, once.
        try await Task.sleep(for: .milliseconds(50))

        source.store.receive(Self.state(withLinks: false))
        #expect(try makeup() == nil)
        try await Task.sleep(for: .milliseconds(50))
        // Read with where their work goes, though none changed: it tells that too, as the main queue delivers it, for as
        // long as a busy machine could need (`waitLimit`).
        source.store.receive(Self.state(withLinks: false, readsLinks: true))
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while try makeup() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try makeup()?.tells == .init(stories: true, sessions: true))
        source.stop()
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

    /// A task BriefBar sent shows with the sessions before you open it in the Copilot app, with no row of the app's: what it
    /// does, and since when, still go to Pull Request Order, so that the In progress it set ends as it finishes, though
    /// nothing puts it on that pull request.
    @Test func aSentTasksInProgressEndsAsItFinishes() throws {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let services = AppServices(defaults: defaults, isDemo: false)
        services.links.setOn(false)
        let source = CopilotSource(services: services, paths: nil)
        let order = services.pullRequestOrder
        let pr = ItemRef.pullRequest(organization: "contoso", number: 4101)
        order.publish(
            .azureDevOps, pullRequests: [Self.pullRequest(4101)],
            stages: [pr: StageFacts(role: .author, waitingFor: "Waiting on Priya")], account: "robin@contoso.com"
        )
        source.start()
        let started = Date().addingTimeInterval(-600)
        func send(_ stage: SentTask.Stage, since: Date) {
            services.sentTasks.publish(.azureDevOps, tasks: [SentTask(
                id: Self.task, name: "Fix Comments: !4100 Show the cart's total", place: nil, stage: stage, detail: nil,
                since: since, opens: "Pull Request", open: {}, menu: { AnyView(EmptyView()) }
            )])
            source.store.receive(EngineSnapshot())
        }

        send(.working, since: started)
        SessionStages.change(Self.ref(Self.task), in: defaults, now: started + 60) {
            $0.set(StageMark(stage: .inProgress, at: started + 60), of: pr)
        }
        order.agentChanged()
        #expect(order.stage(of: pr)?.stage == .inProgress)
        #expect(order.stage(of: pr)?.mark?.by == Self.ref(Self.task))

        send(.finished, since: started + 120)
        #expect(order.stage(of: pr)?.stage == .teammateReview)
        #expect(order.stage(of: pr)?.mark == nil)
        source.stop()
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
