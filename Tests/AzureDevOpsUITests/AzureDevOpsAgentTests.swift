import AzureDevOpsCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// `--mcp`'s Azure DevOps tools, on the demo's made-up pull requests, pipelines, sprint and Copilot tasks: what agents
/// read, and the settings they change, which the demo keeps in memory.
@Suite struct AzureDevOpsAgentTests {
    private let defaults = MemoryDefaults()
    private var agent: AzureDevOpsAgent {
        AzureDevOpsAgent(reader: AzureDevOpsReader(demo: true, organizations: [], defaults: defaults))
    }

    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> String {
        let tool = try #require(agent.tools.first { $0.name == name })
        return try await tool.run(.object(arguments))
    }

    @Test func namesItsToolsTheWayAgentsCallThem() {
        #expect(agent.tools.map(\.name) == [
            "pull_requests", "pull_request", "pull_request_prompt", "pipelines", "sprint", "copilot_tasks",
            "watch_pull_request", "stop_watching_pull_request", "pin_pipeline", "unpin_pipeline",
        ])
        #expect(agent.tools.filter { !$0.readOnly }.map(\.name) == [
            "watch_pull_request", "stop_watching_pull_request", "pin_pipeline", "unpin_pipeline",
        ])
        #expect(PRGroup.allCases.map(\.agentName) == ["needs_you", "answered", "failing", "ready", "to_review", "waiting", "done", "idle"])
        #expect(PullRequestAction.allCases.map(\.agentName) == ["fix_comments", "fix_build", "resolve_conflicts", "review", "push_and_reply"])
        #expect(PRGroup.named("toReview") == .toReview)
        #expect(PullRequestAction.named("FIX_BUILD") == .fixBuild)
    }

    @Test func needsYouHasWhatTheMenuBarCounts() async throws {
        let text = try #require(try await agent.needsYou())
        #expect(text.contains("Needs You (4):"))
        #expect(text.contains("Failing (2):"))
        #expect(text.contains("Ready to Complete (2):"))
        #expect(text.contains("Pinned pipelines that failed (1):\n- “shop-web CI” failed in Test."))
        // What you've seen and haven't answered says so.
        #expect(text.contains("(yours): Sam Rivera replied, 12m ago (seen, still waiting on you). Could we cap"))
        #expect(text.contains("Alex Kim mentioned you, 25m ago. @Robin Diaz"))
        // Not what waits on others, or what's idle.
        #expect(!text.contains("Waiting"))
        #expect(!text.contains("!3990"))
        #expect(text.contains("""
            - !4088 “Show delivery estimates on the product page” in shop-web (yours): Build failed, 1h 5m ago. shop-web CI · \
            Run unit tests: 2 tests failed in DeliveryEstimateTests.
              https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4088
            """))
    }

    @Test func listsPullRequestsByGroup() async throws {
        let all = try await call("pull_requests")
        #expect(all.hasPrefix("4 need you · 1 answered · 2 failing · 2 ready to complete · 1 to review · 2 waiting · 1 done · 2 idle"))
        #expect(all.contains("## Idle (2)"))
        let toReview = try await call("pull_requests", ["group": .string("to_review")])
        #expect(toReview.contains("## To Review (1)\n- !4071 “Cache product search results” in search (by Chen Wei, you review it): Optional review"))
        // Its detail only said who wrote it, as whose it is does.
        #expect(!toReview.contains("By Chen Wei"))
        #expect(!toReview.contains("## Needs You"))
        await #expect(throws: MCPToolError.self) { try await call("pull_requests", ["group": .string("later")]) }
    }

    @Test func describesOnePullRequest() async throws {
        let text = try await call("pull_request", ["pull_request": .string("!4088")])
        #expect(text.hasPrefix("# !4088 “Show delivery estimates on the product page”\nhttps://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4088"))
        #expect(text.contains("- shop-web, in Storefront (contoso), from delivery-estimates into main"))
        #expect(text.contains("- In BriefBar: Failing, Build failed"))
        #expect(text.contains("  - shop-web CI: failed, at Test › Run unit tests: 2 tests failed in DeliveryEstimateTests."))
        #expect(text.contains("pull_request_prompt has the prompt to: fix_build. Once you've changed it, push_and_reply's prompt"))
        #expect(text.contains("- Fix the Build on !4088 in shop-web: working"))

        // By its link, and with its comment threads, word for word. You've opened it since Sam replied: his reply still
        // waits on you, but isn't new.
        let linked = try await call("pull_request", ["pull_request": .string("https://dev.azure.com/contoso/Storefront/_git/payments-api/pullrequest/4102?discussionId=11")])
        #expect(linked.contains("## Unresolved comment threads (1)"))
        #expect(linked.contains("Could we cap the backoff at 30 seconds?"))
        #expect(linked.contains("## Seen, still waiting on you\n- Sam Rivera replied"))
        #expect(!linked.contains("## New for you"))
        #expect(linked.contains("fix_comments"))
        let mentioned = try await call("pull_request", ["pull_request": .int(4097)])
        #expect(mentioned.contains("## New for you\n- Alex Kim mentioned you"))
        #expect(!mentioned.contains("## Seen"))

        let merged = try await call("pull_request", ["pull_request": .int(4085)])
        #expect(merged.contains("- After it merged into main"))
        #expect(merged.contains("Waiting for approval to Production"))
        #expect(!merged.contains("hasn't read its comments"))
        #expect(merged.contains("Nothing for Copilot to do with it now."))

        do {
            _ = try await call("pull_request", ["pull_request": .int(1)])
            Issue.record("Found a pull request the demo doesn't have")
        } catch let error as MCPToolError {
            #expect(error.description.contains("watch_pull_request"))
        }
        await #expect(throws: MCPToolError.self) { try await call("pull_request", ["pull_request": .string("the big one")]) }
    }

    @Test func writesThePromptForAnAgentsOwnCheckout() async throws {
        let prompt = try await call("pull_request_prompt", ["pull_request": .int(4088), "action": .string("fix_build")])
        #expect(prompt.hasPrefix("Pull request !4088 “Show delivery estimates on the product page” in shop-web, from delivery-estimates into main:"))
        #expect(prompt.contains("Work on its branch in a clone of shop-web: fetch origin/delivery-estimates"))
        #expect(!prompt.contains("worktree"))
        #expect(prompt.contains("   - 2 tests failed in DeliveryEstimateTests."))

        let review = try await call("pull_request_prompt", ["pull_request": .int(4071), "action": .string("review")])
        #expect(review.contains("Review it for me."))

        // Ships only what was made for it, from where it should be.
        let ship = try await call("pull_request_prompt", ["pull_request": .int(4091), "action": .string("push_and_reply")])
        #expect(ship.contains("git merge-base --is-ancestor origin/"))
        #expect(ship.contains("don't rebase, merge or force"))
        await #expect(throws: MCPToolError.self) {
            try await call("pull_request_prompt", ["pull_request": .int(4071), "action": .string("push_and_reply")])
        }

        do {
            _ = try await call("pull_request_prompt", ["pull_request": .int(4091), "action": .string("fix_build")])
            Issue.record("Wrote a prompt that doesn't apply")
        } catch let error as MCPToolError {
            #expect(error.description == "fix_build doesn't apply to !4091: no build that blocks it failed.")
        }
        do {
            _ = try await call("pull_request_prompt", ["pull_request": .int(4088), "action": .string("review")])
            Issue.record("Reviewed your own pull request")
        } catch let error as MCPToolError {
            #expect(error.description.hasPrefix("review doesn't apply to !4088: it's yours."))
        }
        await #expect(throws: MCPToolError.self) {
            try await call("pull_request_prompt", ["pull_request": .int(4088), "action": .string("merge")])
        }
    }

    @Test func showsPipelinesTheSprintAndCopilotTasks() async throws {
        let pipelines = try await call("pipelines")
        #expect(pipelines.contains("## Pinned (4)\n- shop-web CI (Storefront › CI)  Failed in Test"))
        #expect(pipelines.contains("## After your merges (1)\n- !4085 “Update the README badges” into main"))
        #expect(pipelines.contains("https://dev.azure.com/contoso/Storefront/_build/results?buildId="))

        let sprint = try await call("sprint", ["mine": .bool(true)])
        #expect(sprint.hasPrefix("Sprint 42 · Storefront Team"))
        #expect(sprint.components(separatedBy: "(you)").count - 1 == 5 + 1)

        let tasks = try await call("copilot_tasks")
        #expect(tasks.contains("- Work item 5112 “Round half up in the coupon service” in Storefront: finished"))
        #expect(tasks.contains("- Fix the Build on !4088 “Show delivery estimates on the product page” in shop-web: working"))
    }

    @Test func watchesAndStopsWatchingInMemoryInTheDemo() async throws {
        let link = "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/5000"
        #expect(try await call("watch_pull_request", ["link": .string(link)]).hasPrefix("BriefBar watches !5000 in contoso now."))
        #expect(try await call("watch_pull_request", ["link": .string(link)]) == "BriefBar watches !5000 already.")
        let stored = try #require(defaults.data(forKey: SettingsKey.watchedPullRequests))
        #expect(try JSONDecoder().decode([PullRequestLink].self, from: stored).map(\.number) == [5000])

        // One that's listed already isn't watched.
        let mine = "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4088"
        #expect(try await call("watch_pull_request", ["link": .string(mine)]) == "BriefBar lists !4088 already, as yours.")

        #expect(try await call("stop_watching_pull_request", ["pull_request": .string("!5000")]) == "BriefBar stopped watching !5000.")
        await #expect(throws: MCPToolError("BriefBar doesn't watch !5000.")) {
            try await call("stop_watching_pull_request", ["pull_request": .int(5000)])
        }
        await #expect(throws: MCPToolError.self) { try await call("watch_pull_request", ["link": .string("shop-web 5000")]) }
    }

    @Test func unpinsByNameButTheDemoPinsNothing() async throws {
        let pinned = DemoData.pipelines().map(\.pipeline)
        defaults.set(try JSONEncoder().encode(pinned), forKey: SettingsKey.pinnedPipelines)
        #expect(try await call("unpin_pipeline", ["pipeline": .string("shop-web ci")]) == "Unpinned “shop-web CI”.")
        let left = try JSONDecoder().decode([PipelineRef].self, from: try #require(defaults.data(forKey: SettingsKey.pinnedPipelines)))
        #expect(left.map(\.name) == pinned.dropFirst().map(\.name))
        await #expect(throws: MCPToolError("No pinned pipeline is “shop-web CI”.")) {
            try await call("unpin_pipeline", ["pipeline": .string("shop-web CI")])
        }
        await #expect(throws: MCPToolError("The demo reads no pipelines: it has only its own.")) {
            try await call("pin_pipeline", ["link": .string("https://dev.azure.com/contoso/Storefront/_build?definitionId=12")])
        }
    }

    @Test func readsPullRequestsByNumberOrLink() throws {
        #expect(try AzureDevOpsAgent.reference(.int(4088)) == (4088, nil))
        #expect(try AzureDevOpsAgent.reference(.string("!4088")) == (4088, nil))
        #expect(try AzureDevOpsAgent.reference(.string(" 4088 ")) == (4088, nil))
        #expect(try AzureDevOpsAgent.reference(.string("https://contoso.visualstudio.com/Shop/_git/web/pullrequest/12")) == (12, "contoso"))
        #expect(throws: MCPToolError.self) { try AzureDevOpsAgent.reference(.int(0)) }
        #expect(throws: MCPToolError.self) { try AzureDevOpsAgent.reference(nil) }
    }
}
