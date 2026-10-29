import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Synchronization
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
            "pull_requests", "pull_request", "pull_request_prompt", "pipelines", "sprint", "work_item", "copilot_tasks",
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

    @Test func tellsAWorkItemAndWhatGoesWithIt() async throws {
        let story = try await call("work_item", ["work_item": .string("5101")])
        let lines = story.components(separatedBy: "\n")
        #expect(Array(lines.prefix(3)) == [
            "# User Story 5101 “Save items for later from the cart”",
            "https://dev.azure.com/contoso/Storefront/_workitems/edit/5101",
            "- State: Active (work started), changed 1h ago · assigned to you (Robin Diaz)",
        ])
        #expect(lines[3].hasPrefix("- Sprint 42 ends ") && lines[3].hasSuffix(" (5 days left) · 1 of 4 tasks done · 6 h left"))
        #expect(lines[4] == "- Waiting on: reviewers of Sam Rivera's !4120 · Copilot, on task 5103")
        // Your task that isn't started; not 5103, which Copilot works on.
        #expect(lines[5] == "- You can: start task 5104")
        // Its tasks in work order, each with its state, who has it and its hours, and the work sent to Copilot for one.
        #expect(story.contains("""
            ## Tasks
            - 5103 Show saved items under the cart: Active · you · 3 h left · Copilot working (started 6m ago): Run the cart tests
            - 5104 Move a saved item back to the cart: New · you · 2 h left
            """))
        #expect(story.contains("- 5102 Add a saved items table to the cart service: Closed · you\n"))
        #expect(!story.contains("◐") && !story.contains("Type:") && !story.contains("## Sent to Copilot"))
        // A teammate's pull request, as it says itself, and what BriefBar doesn't read of it.
        #expect(story.contains("""
            ### !4120 “Save items for later in the cart service”
            https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4120
            - Waiting for reviewers · saved-items → main, in shop-web
            - Author: Sam Rivera
            - Not read: builds and comment threads (you're not on it)
            """))
        #expect(!story.contains("pull_request 4120"))
        // What people wrote, quoted.
        #expect(story.contains("""
            ## Description
            > As a shopper, I want to save items for later from my cart, so I can buy them another time without looking for them again.
            >
            > Saved items belong to the account, not the device:
            """))
        #expect(story.contains("> Design: Cart › Saved for later\n\n### Acceptance Criteria\n> 1. A signed-in shopper can save any item in the cart"))
        #expect(story.contains("""
            ## Latest comments (newest first)
            - You, 3h ago:
              > Only signed-in shoppers for now. Guests get a prompt to sign in when they try.
            - Priya Shah, 20h ago:
            """))
        // Run on its own, there's no other source to ask, and it points to no other tool.
        #expect(!story.contains("## Copilot sessions") && !story.contains("copilot_sessions"))

        // A task, by its link: its bug, one of your pull requests with its pipeline, and the work sent to Copilot for it.
        let task = try await call("work_item", ["work_item": .string("https://dev.azure.com/contoso/Storefront/_workitems/edit/5112")])
        #expect(task.contains("""
            - Under bug 5110 “Coupon totals round down instead of to the nearest cent”
            - State: Active (work started), changed 1h 30m ago · assigned to you (Robin Diaz)
            """))
        #expect(task.contains(" (5 days left) · 2 h left\n- Waiting on: you, to complete !4091\n- You can: complete !4091\n"))
        #expect(!task.contains("## Tasks"))
        #expect(task.contains("""
            ### !4091 “Fix the coupon rounding error”
            https://dev.azure.com/contoso/Storefront/_git/payments-api/pullrequest/4091
            - Ready to complete: Approved by Priya Shah, Chen Wei · coupon-rounding → main, in payments-api
            """))
        // Its threads are all resolved, so nothing points to them.
        #expect(task.contains("- Author: you\n- Pipelines:\n  - payments-api CI: Passed\n\n"))
        #expect(!task.contains("- Threads:"))
        #expect(task.contains("""
            ## Sent to Copilot
            - This task: Copilot finished 12m ago. Coupon totals now round half up, with tests for every currency. Opened pull request 4091.
              session 1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01
              https://dev.azure.com/contoso/Storefront/_git/payments-api/pullrequest/4091
            """))
        #expect(!task.contains("Claude") && !task.contains("BriefBar's Ready to Complete"))

        // Its bug: the work sent for the task goes on the task's line, and its repro steps are under their name.
        let bug = try await call("work_item", ["work_item": .int(5110)])
        #expect(bug.contains("- State: Active (work started), changed 1h ago · assigned to Priya Shah\n"))
        #expect(bug.contains("- Waiting on: you, to complete !4091\n- You can: complete !4091\n"))
        #expect(bug.contains("""
            - 5112 Round half up in the coupon service: Active · you · 2 h left · Copilot finished 12m ago. Coupon totals now round \
            half up, with tests for every currency. Opened pull request 4091.
            """))
        #expect(!bug.contains("## Sent to Copilot"))
        #expect(bug.contains("## Description\n\n### Repro Steps\n> 1. Add a $19.99 item to the cart"))
        #expect(bug.contains("### System Info\n> Storefront web 3.42.0 · Safari 26 · macOS 26.1"))

        await #expect(throws: MCPToolError("The demo's sprint has no work item 1.")) { try await call("work_item", ["work_item": .int(1)]) }
    }

    /// What the other sources know of its pull requests, such as the Copilot sessions on them: asked about with the pull
    /// requests' branches while the tool runs among the sources (`MCPRelated`), and told under their title, the first few
    /// in full and the rest by name.
    @Test func tellsWhatTheOtherSourcesKnowOfItsPullRequests() async throws {
        let asked = Mutex<[MCPRelated.Query]>([])
        let savedItems = ItemRef.pullRequest(organization: "contoso", number: 4120)
        @Sendable func session(_ number: Int, _ name: String, state: ItemState? = nil, status: String = "idle") -> MCPRelated.Item {
            let id = String(format: "0b6c1f44-6a1e-4c55-9d0e-%012d", number)
            return MCPRelated.Item(
                ref: ItemRef.session(id)!, title: name, status: status, state: state, url: URL(string: "ghapp://sessions/\(id)"),
                links: [MCPRelated.Link(item: savedItems, reason: "on !4120's branch")], lines: ["Did: Saved items", "Next: Push"]
            )
        }
        let copilot = MCPRelated.Teller(title: "Copilot sessions") { query in
            asked.withLock { $0.append(query) }
            return [
                session(1, "Show the saved items", state: .needsYou, status: "waiting for your answer since 4m ago"),
                // The session the task sent for 5103 works in: that task tells of it.
                MCPRelated.Item(ref: ItemRef.session("1D6B2C7E-4F0A-4B8E-9C31-5A2E7D8F6B02")!, title: "Sent for 5103", status: "working"),
                session(2, "Save items for later", status: "finished 2h ago"),
            ] + (3...7).map { session($0, "Earlier \($0)") }
        }
        let off = MCPRelated.Teller(title: "GitHub pull requests") { _ in throw MCPToolError("GitHub is off in BriefBar.") }
        let story = try await MCPRelated.$tellers.withValue([copilot, off]) {
            try await call("work_item", ["work_item": .string("5101")])
        }

        let query = try #require(asked.withLock { $0.first })
        #expect(query.items == [.workItem(organization: "contoso", id: 5101), savedItems])
        #expect(query.branches == [savedItems: BranchHint(branch: "saved-items", target: "main", repositories: ["shop-web"])])
        #expect(query.limit == AgentText.relatedShown)
        #expect(story.contains("""
            - Waiting on: you, to answer in session “Show the saved items” · reviewers of Sam Rivera's !4120 · Copilot, on task 5103
            - You can: answer in session “Show the saved items” · start task 5104

            """))
        #expect(story.contains("""
            ## Copilot sessions

            ### “Show the saved items”: waiting for your answer since 4m ago, on !4120's branch
            ghapp://sessions/0b6c1f44-6a1e-4c55-9d0e-000000000001
            - Did: Saved items
            - Next: Push

            ### “Save items for later”: finished 2h ago, on !4120's branch
            """))
        #expect(!story.contains("Sent for 5103"))
        #expect(story.contains("### “Earlier 5”: idle, on !4120's branch"))
        #expect(story.contains("\n\nAnd 2 more: “Earlier 6” (idle), “Earlier 7” (idle).\n\n## GitHub pull requests\nGitHub is off in BriefBar.\n"))
        // After its pull requests, and before what people wrote.
        let sections = story.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(sections == [
            "## Tasks", "## Pull requests", "## Copilot sessions", "## GitHub pull requests", "## Description",
            "## Latest comments (newest first)",
        ])

        // A work item without pull requests asks nothing.
        asked.withLock { $0.removeAll() }
        _ = try await MCPRelated.$tellers.withValue([copilot]) { try await call("work_item", ["work_item": .int(5104)]) }
        #expect(asked.withLock { $0.isEmpty })
    }

    /// Who each of your lists' pull requests waits on, by why it's where it is, and one that isn't in your lists, by its
    /// votes.
    @Test func saysWhoAPullRequestWaitsOn() async throws {
        let read = await AzureDevOpsReader(demo: true, organizations: [], defaults: defaults).pullRequests()
        var waits: [Int: ItemStory.Wait] = [:]
        for item in read.items {
            waits[item.key.number] = PullRequestWait.waiting(on: item, record: read.records.first { $0.id == item.key })
        }
        #expect(waits == [
            4113: .you("you, to look at !4113"),
            4102: .you("you, to answer on !4102"),
            4097: .you("you, to answer on !4097"),
            4110: .you("you, to review Jordan Lee's !4110"),
            4088: .you("you, to fix !4088's build"),
            4079: .you("you, to resolve !4079's conflicts"),
            4091: .you("you, to complete !4091"),
            4071: .you("you, to review Chen Wei's !4071"),
            4099: .people("Alex Kim and Jordan Lee, to review your !4099"),
            4060: .people("Sam Rivera, to update !4060"),
            4085: .people("an approval for the pipeline after !4085 merged"),
        ])

        let me = Person(id: "me", name: "Robin Diaz")
        let sam = Person(id: "sam", name: "Sam Rivera")
        let priya = Person(id: "priya", name: "Priya Shah")
        func pullRequest(by author: Person = sam, _ reviewers: [Reviewer] = [], draft: Bool = false, merge: String = "succeeded") -> PullRequest {
            PullRequest(
                key: PRKey("contoso", 4120), title: "Save items for later", author: author, createdAt: Date(), projectId: "p",
                projectName: "Storefront", repositoryId: "r", repositoryName: "shop-web", isDraft: draft, mergeStatus: merge,
                reviewers: reviewers
            )
        }
        #expect(PullRequestWait.waiting(on: pullRequest(), me: "me") == .people("reviewers of Sam Rivera's !4120"))
        #expect(PullRequestWait.waiting(on: pullRequest([Reviewer(person: priya, vote: .none)]), me: "me")
            == .people("Priya Shah, to review Sam Rivera's !4120"))
        #expect(PullRequestWait.waiting(on: pullRequest([Reviewer(person: me, vote: .none)]), me: "me") == .you("you, to review Sam Rivera's !4120"))
        #expect(PullRequestWait.waiting(on: pullRequest([Reviewer(person: priya, vote: .approved)]), me: "me")
            == .people("Sam Rivera, author of !4120 (approved; its checks aren't read)"))
        #expect(PullRequestWait.waiting(on: pullRequest(by: me, [Reviewer(person: priya, vote: .waitingForAuthor)]), me: "me")
            == .you("you, to make the changes asked for on !4120"))
        #expect(PullRequestWait.waiting(on: pullRequest(draft: true), me: "me") == .people("Sam Rivera, to publish !4120, a draft"))
        #expect(PullRequestWait.waiting(on: pullRequest(merge: "conflicts"), me: "me") == .people("Sam Rivera, to resolve !4120's conflicts"))
        var merged = pullRequest()
        merged.status = .completed
        #expect(PullRequestWait.waiting(on: merged, me: "me") == nil)
    }

    /// The demo's work item 5101, whose teammate's pull request, !4120, isn't in your lists, with these reviewers.
    private func readWithTeammatesReviewers(_ reviewers: [Reviewer]) async throws -> AzureDevOpsReader.WorkItemRead {
        var read = try await AzureDevOpsReader(demo: true, organizations: [], defaults: defaults).workItem(5101, organization: nil)
        let key = try #require(read.others.read.keys.first { $0.number == 4120 })
        #expect(read.pullRequests.map(\.number) == [4120])
        #expect(!read.lists.items.contains { $0.key.number == 4120 })
        read.others.read[key]?.reviewers = reviewers
        return read
    }

    /// A required group, such as a team a policy adds, holds a teammate's pull request up as a required person does,
    /// however many others approved.
    @Test func aRequiredGroupThatHasntApprovedHoldsUpATeammatesPullRequest() async throws {
        let read = try await readWithTeammatesReviewers([
            Reviewer(person: Person(id: "priya", name: "Priya Shah"), vote: .approved),
            Reviewer(person: Person(id: "team", name: "[Storefront]\\Storefront Team"), vote: .none, isRequired: true, isGroup: true),
        ])
        #expect(AgentText.waitingOn(read, tasks: [], related: [], me: read.me) == ["reviewers of Sam Rivera's !4120"])
        #expect(AgentText.workItem(read, tasks: [], now: Date()).contains("\n- Waiting on: reviewers of Sam Rivera's !4120\n"))
    }

    /// Once every required reviewer approved one, it waits on its author, but whether it's ready to complete is up to its
    /// policies and checks, which BriefBar doesn't read for a pull request that isn't in your lists.
    @Test func aTeammatesPullRequestThatsApprovedIsntSaidToBeReady() async throws {
        let read = try await readWithTeammatesReviewers([
            Reviewer(person: Person(id: "priya", name: "Priya Shah"), vote: .approved, isRequired: true),
            Reviewer(person: Person(id: "team", name: "[Storefront]\\Storefront Team"), vote: .approved, isRequired: true, isGroup: true),
            Reviewer(person: Person(id: "chen", name: "Chen Wei"), vote: .none),
        ])
        #expect(AgentText.waitingOn(read, tasks: [], related: [], me: read.me)
            == ["Sam Rivera, author of !4120 (approved; its checks aren't read)"])
    }

    /// Work sent to Copilot that failed waits on you, as the details say: while it's the one sent last for its work item
    /// or pull request, and that isn't done.
    @Test func failedWorkSentToCopilotWaitsOnYou() async throws {
        let read = try await AzureDevOpsReader(demo: true, organizations: [], defaults: defaults).workItem(5112, organization: nil)
        func sent(_ phase: RunPhase, minutesAgo: Double, session: Int) -> CopilotTaskEntry {
            CopilotTaskEntry(
                id: String(format: "1d6b2c7e-4f0a-4b8e-9c31-%012d", session),
                workItem: WorkItemReference(organization: "contoso", project: "Storefront", id: 5112), options: CopilotModel.standard,
                startedAt: Date().addingTimeInterval(-minutesAgo * 60), status: RunStatus(phase: phase)
            )
        }
        let failed = sent(.failed, minutesAgo: 5, session: 1)
        // On 5112 itself, it's "it".
        let story = AgentText.workItem(read, tasks: [failed], now: Date())
        #expect(story.contains("- Waiting on: you, to complete !4091 · you, to look at Copilot's work on it, which failed\n"))
        #expect(story.contains("- You can: complete !4091 · look at Copilot's work on it, which failed\n"))
        // On its bug, it's the task, by its type.
        let bug = try await AzureDevOpsReader(demo: true, organizations: [], defaults: defaults).workItem(5110, organization: nil)
        #expect(AgentText.waitingOn(bug, tasks: [failed], related: [], me: bug.me)
            == ["you, to complete !4091", "you, to look at Copilot's work on task 5112, which failed"])
        // Sent again since, the one sent last says.
        let again = sent(.finished, minutesAgo: 1, session: 2)
        #expect(AgentText.waitingOn(read, tasks: [again, failed], related: [], me: read.me) == ["you, to complete !4091"])
        // Done since, it waits on nobody.
        var done = read
        done.item.state = "Closed"
        done.item.category = .completed
        #expect(AgentText.waitingOn(done, tasks: [failed], related: [], me: done.me) == ["you, to complete !4091"])
    }

    /// A pull request with a thread that's open points to `pull_request` for it.
    @Test func pointsToTheThreadsOfAPullRequestWithOneOpen() async throws {
        var read = try await AzureDevOpsReader(demo: true, organizations: [], defaults: defaults).workItem(5112, organization: nil)
        let index = try #require(read.lists.records.firstIndex { $0.id.number == 4091 })
        read.lists.records[index].details?.threads.append(ReviewThread(id: 63, comments: [
            ReviewComment(id: 1, author: Person(id: "priya", name: "Priya Shah"), text: "A test for a negative total?", publishedAt: Date()),
        ]))
        #expect(AgentText.workItem(read, tasks: [], now: Date()).contains("- payments-api CI: Passed\n- Threads: pull_request 4091\n"))
    }

    /// What you can do: what waits on you, then your tasks that aren't started, unless Copilot works on one; or nothing.
    @Test func saysWhatYouCanDo() async throws {
        let read = try await AzureDevOpsReader(demo: true, organizations: [], defaults: defaults).workItem(5101, organization: nil)
        let waits = [ItemStory.Wait(.people, "Priya Shah, to review !1"), ItemStory.Wait(.you, "you, to fix !2's build")]
        #expect(AgentText.youCan(waits, read: read, tasks: [], me: read.me) == "fix !2's build · start task 5104")
        let working = CopilotTaskEntry(
            id: "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b09", workItem: WorkItemReference(organization: "contoso", project: "Storefront", id: 5104),
            options: CopilotModel.standard, startedAt: Date(), status: RunStatus(phase: .working)
        )
        #expect(AgentText.youCan(waits, read: read, tasks: [working], me: read.me) == "fix !2's build")
        var done = read
        done.tasks = done.tasks.filter { $0.isDone }
        #expect(AgentText.youCan([], read: done, tasks: [], me: read.me) == "nothing waits on you")
    }

    /// One of your pull requests in your lists waits on you to complete it once it's ready by its policies, as the
    /// classifier has it, rather than by its votes.
    @Test func yourReadyPullRequestWaitsOnYouToCompleteIt() async throws {
        let read = try await AzureDevOpsReader(demo: true, organizations: [], defaults: defaults).workItem(5112, organization: nil)
        let snapshot = try #require(read.lists.items.first { $0.key.number == 4091 })
        #expect(snapshot.role == .author && snapshot.group == .ready && snapshot.reason == .readyToComplete)
        #expect(AgentText.waitingOn(read, tasks: [], related: [], me: read.me) == ["you, to complete !4091"])
        // Read by its votes alone, as one that isn't in your lists is, it's only approved.
        let pullRequest = try #require(read.pullRequest(snapshot.key))
        let me = read.lists.records.first { $0.id == snapshot.key }?.me
        #expect(PullRequestWait.waiting(on: pullRequest, me: me) == .you("you, to complete !4091 once its checks pass"))
    }

    @Test func saysWhenItsSprintEnds() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        func day(_ month: Int, _ day: Int, hour: Int = 0) throws -> Date {
            try #require(utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
        }
        let now = try day(10, 29, hour: 10)
        let sprint = Sprint(id: "s42", name: "Sprint 42", path: "Storefront\\Sprint 42", start: try day(10, 28), finish: try day(11, 10))
        #expect(AgentText.iteration("Storefront\\Sprint 42", sprint: sprint, now: now, calendar: utc) == "Sprint 42 ends 10 Nov (13 days left)")
        #expect(AgentText.iteration("storefront\\sprint 42", sprint: sprint, now: try day(11, 10, hour: 10), calendar: utc)
            == "Sprint 42 ends today, 10 Nov")
        #expect(AgentText.iteration("Storefront\\Sprint 41", sprint: sprint, now: now, calendar: utc) == "In Sprint 41")
        #expect(AgentText.iteration("Storefront\\Sprint 42", sprint: nil, now: now, calendar: utc) == "In Sprint 42")
        // The project's own iteration is the backlog.
        #expect(AgentText.iteration("Storefront", sprint: sprint, now: now, calendar: utc) == nil)
        #expect(AgentText.iteration(nil, sprint: sprint, now: now, calendar: utc) == nil)

        #expect(AgentText.lowercasingFirst("Work started") == "work started")
        #expect(AgentText.lowercasingFirst("PR merged") == "PR merged")
        #expect(AgentText.names(["Alex Kim", "Priya Shah", "Chen Wei", "Sam Rivera", "Jordan Lee"]) == "Alex Kim, Priya Shah, Chen Wei and 2 more")
    }

    @Test func quotesCommentsAndSaysWhenTheyCouldntBeRead() throws {
        let now = Date()
        let item = WorkItem(id: 7, organization: "contoso", project: "Storefront", type: "Bug", title: "Totals", state: "New", category: .proposed)
        let comments = (1...7).map { index in
            WorkItemDetails.Comment(
                id: index, author: Person(id: index == 1 ? "me" : "sam", name: index == 1 ? "Robin Diaz" : "Sam Rivera"),
                createdAt: now.addingTimeInterval(-Double(index) * 3_600), text: RichText(html: "<div>Line \(index)</div><div>More</div>")
            )
        }
        let details = WorkItemDetails(item: item, comments: comments, commentCount: 9, readAt: now)
        #expect(AgentText.comments(details, me: "me", now: now) == [
            "", "## Latest comments (newest first, 5 of 9)",
            "- You, 1h ago:", "  > Line 1", "  > More",
            "- Sam Rivera, 2h ago:", "  > Line 2", "  > More",
            "- Sam Rivera, 3h ago:", "  > Line 3", "  > More",
            "- Sam Rivera, 4h ago:", "  > Line 4", "  > More",
            "- Sam Rivera, 5h ago:", "  > Line 5", "  > More",
        ])
        let unread = WorkItemDetails(item: item, commentsProblem: "Azure DevOps didn't answer.", readAt: now)
        #expect(AgentText.comments(unread, me: "me", now: now) == ["", "## Latest comments", "BriefBar couldn't read them: Azure DevOps didn't answer."])
        #expect(AgentText.comments(WorkItemDetails(item: item, readAt: now), me: "me", now: now).isEmpty)
    }

    @Test func findsTheWorkSentForAWorkItemOrOnItsPullRequests() throws {
        let bug = try #require(DemoData.sprintBoard().item(WorkItemKey("contoso", 5110)))
        let tasks = try #require(DemoData.sprintBoard().rows.first { $0.parent?.id == 5110 }).tasks
        func entry(_ id: String, workItem: Int?, on pullRequest: Int? = nil) -> CopilotTaskEntry {
            CopilotTaskEntry(
                id: id, workItem: workItem.map { WorkItemReference(organization: "Contoso", project: "Storefront", id: $0) },
                onPullRequest: pullRequest.map { PullRequestReference(
                    organization: "contoso", project: "Storefront", repository: "payments-api", id: $0, sourceBranch: "coupon-rounding"
                ) },
                options: CopilotModel.standard, startedAt: Date(), status: RunStatus(phase: .working)
            )
        }
        let all = [
            entry("its own", workItem: 5110), entry("its task's", workItem: 5112), entry("another's", workItem: 5101),
            // Sent from another work item, then on to the bug's pull request.
            entry("on its pull request", workItem: 5101, on: 4091), entry("on another", workItem: nil, on: 4088),
        ]
        let found = AzureDevOpsAgent.tasks(all, for: bug, tasks: tasks, pullRequests: [PRKey("contoso", 4091)])
        #expect(found.map(\.id) == ["its own", "its task's", "on its pull request"])
    }

    @Test func readsWorkItemsByNumberOrLink() throws {
        #expect(try AzureDevOpsAgent.workItemReference(.int(5101)) == (5101, nil))
        #expect(try AzureDevOpsAgent.workItemReference(.string("#5101")) == (5101, nil))
        #expect(try AzureDevOpsAgent.workItemReference(.string(" 5101 ")) == (5101, nil))
        #expect(try AzureDevOpsAgent.workItemReference(.string("https://contoso.visualstudio.com/Shop/_workitems/edit/12")) == (12, "contoso"))
        #expect(try AzureDevOpsAgent.workItemReference(.string("https://dev.azure.com/Fabrikam/Shop/_workitems/edit/7/")) == (7, "fabrikam"))
        #expect(throws: MCPToolError.self) {
            try AzureDevOpsAgent.workItemReference(.string("https://dev.azure.com/contoso/Shop/_git/web/pullrequest/12"))
        }
        #expect(throws: MCPToolError.self) { try AzureDevOpsAgent.workItemReference(.string("!5101")) }
        #expect(throws: MCPToolError.self) { try AzureDevOpsAgent.workItemReference(nil) }
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
