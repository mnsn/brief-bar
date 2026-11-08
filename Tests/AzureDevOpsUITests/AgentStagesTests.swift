import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Pull requests' stages, as agents are told them, while Pull Request Order is on: `needs_me`'s Stages, the Board in
/// words, and `pull_request`'s stage, as the app works them out, with what you and the sessions the Copilot app lists set.
@Suite struct AgentStagesTests {
    private let defaults = MemoryDefaults()
    private var agent: AzureDevOpsAgent {
        AzureDevOpsAgent(reader: AzureDevOpsReader(demo: true, organizations: [], defaults: defaults))
    }

    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> String {
        let tool = try #require(agent.tools.first { $0.name == name })
        return try await tool.run(.object(arguments))
    }

    /// The Copilot app, as its source tells pull requests' stages: "Retry backoff", finished a day ago.
    private static let copilot = MCPRelated.Teller(title: "Copilot sessions", tell: { _ in [] }, stageSessions: {
        MCPRelated.StageSessions(listed: [
            DemoPullRequestOrder.retryBackoff: MCPRelated.StageSessions.Session(
                activity: .finished, since: Date().addingTimeInterval(-26 * 3_600), name: "Retry backoff"
            ),
        ])
    })

    @Test func needsMeTellsTheBoardInWords() async throws {
        let text = try #require(try await MCPRelated.$tellers.withValue([Self.copilot]) { try await agent.needsYou() })
        #expect(text.contains("""

            Stages, as BriefBar's Board shows them, what's next first:
            - In progress (
            """))
        #expect(text.contains("""
            - Your review (5):
              - !4102 “Add retry with backoff to the payments client” in payments-api: ‘Retry backoff’ says it's ready (set 1d ago)
            """))
        #expect(text.contains("""
            - Teammate's review (2):
              - !4105 “Prototype one-click checkout” in shop-web: Nobody's asked to review it yet (You set it 2h ago)
              - !4099 “Log slow database queries” in infra: 0 of 2 approvals
            - Can merge (1):
              - !4093 “Add dark mode to the account page” in shop-web: Completing automatically
            - Waits (1):
              - !4091 “Fix the coupon rounding error” in payments-api: After !4102

            Pinned pipelines that failed (1):
            """))
        // Merged pull requests aren't among them.
        #expect(!text.contains("- Merged ("))

        // What a session set counts only while the Copilot app lists it.
        let unlisted = try #require(try await agent.needsYou())
        #expect(unlisted.contains("  - !4102 “Add retry with backoff to the payments client” in payments-api: Waiting on Sam\n"))
    }

    @Test func pullRequestSaysItsStage() async throws {
        let details = try await call("pull_request", ["pull_request": .int(4105)])
        #expect(details.contains("\n- Its stage: Teammate's review: Nobody's asked to review it yet (You set it 2h ago).\n"))
        let retry = try await MCPRelated.$tellers.withValue([Self.copilot]) {
            try await call("pull_request", ["pull_request": .int(4102)])
        }
        #expect(retry.contains("\n- Its stage: Your review: ‘Retry backoff’ says it's ready (set 1d ago).\n"))
    }

    /// Nothing of stages while Pull Request Order is off.
    @Test func noStagesWhilePullRequestOrderIsOff() async throws {
        let off = AzureDevOpsReader(demo: false, organizations: [], defaults: MemoryDefaults())
        #expect(await off.orderKept(now: Date()) == nil)
        let on = AzureDevOpsReader(demo: false, organizations: [], defaults: {
            let defaults = MemoryDefaults()
            defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
            return defaults
        }())
        #expect(await on.orderKept(now: Date()) != nil)
    }

    /// As the app works them out: yours while it stands, with the account the lists read; the latest of yours and the listed
    /// sessions', saying what it replaced; none for a session the Copilot app doesn't list; and none of yours saved for one
    /// only sent to you in a chat, which the app keeps in memory.
    @Test func theLatestOfWhatYouAndListedSessionsSetCounts() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        func ref(_ number: Int) -> ItemRef { .pullRequest(organization: "contoso", number: number) }
        let cart = try #require(ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b"))
        let archived = try #require(ItemRef.session("2b8d4f60-9a1c-4e3b-b7d5-6f8e9a0b1c2d"))
        var marks = StageMarks()
        for number in [4093, 4094, 4095] {
            _ = marks.set(StageMark(stage: .teammateReview, at: now - 7_200, votes: ""), of: ref(number), for: "robin@contoso.com", at: now)
        }
        var sessionStages = SessionStages()
        var cartStage = SessionStage(session: cart)
        cartStage.set(StageMark(stage: .inProgress, at: now - 60), of: ref(4093))
        sessionStages.replace(cartStage)
        var archivedStage = SessionStage(session: archived)
        archivedStage.set(StageMark(stage: .yourReview, at: now - 30), of: ref(4094))
        sessionStages.replace(archivedStage)
        let kept = OrderKept(
            orders: DeclaredOrders(), evidence: OrderEvidence(), focus: nil, changes: OrderChanges(), marks: marks,
            sessionStages: sessionStages
        )
        let facts: [ItemRef: StageFacts] = [
            ref(4093): StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: ""),
            ref(4094): StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: ""),
            ref(4095): StageFacts(role: .sentToYou, asksYou: "Priya sent it in Teams"),
        ]
        let copilot = MCPRelated.StageSessions(listed: [cart: .init(activity: .finished, since: now - 3_600, name: "Cart")])
        let stages = AzureDevOpsAgent.stages(
            facts: facts, pullRequests: [], copilot: copilot, kept: kept, account: "Robin@contoso.com", now: now
        )

        let replaced = try #require(stages.readings[ref(4093)])
        #expect(replaced.stage == .inProgress && replaced.mark?.by == cart)
        #expect(AgentText.stage(replaced, stages: stages) == """
            Its stage: In progress: ‘Cart’ is on it (set 1m ago, after you). You'd set Teammate's review 2h ago, which a \
            session's later change replaced: you can put yours back.
            """)
        #expect(AgentText.stage(try #require(stages.readings[ref(4094)]), stages: stages)
            == "Its stage: Teammate's review: Waiting on Priya (You set it 2h ago).")
        #expect(stages.readings[ref(4095)]?.stage == .yourReview)
        #expect(stages.readings[ref(4095)]?.mark == nil)
        #expect(stages.columns[.inProgress] == [ref(4093)])
    }
}
