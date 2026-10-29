import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// What Azure DevOps tells Show Links: the made-up links, pull requests, work items and tasks of the demo, which never use
/// the Azure CLI or Azure DevOps.
@MainActor
@Suite struct WorkLinksStoreTests {
    private let organization = DemoData.organization
    private let session = ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01")!

    @Test func aTaskSentToCopilotLinksItsSessionToWhatItCameFromAndWhatItOpened() {
        let workItem = ItemRef.workItem(organization: "contoso", id: 5112)
        let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4091)
        let sent = CopilotTaskEntry(
            id: session.id, workItem: WorkItemReference(organization: "Contoso", project: "Storefront", id: 5112),
            options: CopilotModel.standard, startedAt: Date(), status: RunStatus(phase: .finished),
            pullRequest: URL(string: "https://dev.azure.com/contoso/Storefront/_git/payments-api/pullrequest/4091")
        )
        #expect(Set(WorkLinksStore.links(of: sent, session: session).map(\.pair))
            == [LinkPair(session, workItem)!, LinkPair(session, pullRequest)!, LinkPair(workItem, pullRequest)!])
        #expect(WorkLinksStore.links(of: sent, session: session).allSatisfy { $0.origin == .copilot })

        let fixing = CopilotTaskEntry(
            id: session.id, workItem: nil,
            onPullRequest: PullRequestReference(organization: "contoso", project: "Storefront", repository: "shop-web", id: 4088,
                                                sourceBranch: "delivery-estimates"),
            action: .fixBuild, options: CopilotModel.standard, startedAt: Date(), status: RunStatus(phase: .working),
            pullRequest: URL(string: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4088")
        )
        #expect(Set(WorkLinksStore.links(of: fixing, session: session).map(\.pair))
            == [LinkPair(session, .pullRequest(organization: "contoso", number: 4088))!])
    }

    @Test func theDemoLinksItsPullRequestsWorkItemsAndTasks() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        let sprint = SprintStore(settings: settings, mode: .demo, client: store.client)
        let copilot = CopilotTasksStore(settings: settings, mode: .demo, notifier: nil)
        let links = Links(defaults: MemoryDefaults(), isDemo: true)
        await store.loadOnce()
        await sprint.loadOnce()
        let workLinks = WorkLinksStore(
            links: links, stories: ItemStories(links: links), store: store, sprint: sprint, copilot: copilot, settings: settings
        )
        await workLinks.loadOnce()

        // The coupon pull request: its bug and task in Azure DevOps, and the task Copilot opened it from.
        let coupon = links.connections(of: .pullRequest(organization: organization, number: 4091))
        #expect(Set(coupon.map(\.item.ref).filter { $0.kind == .workItem })
            == [.workItem(organization: organization, id: 5110), .workItem(organization: organization, id: 5112)])
        let task = try #require(coupon.first { $0.item.ref == session })
        #expect(task.item.state == .done)
        #expect(task.item.menu != nil)
        // A teammate's pull request on a sprint's story, which the lists don't show, as Azure DevOps has it.
        let story = links.connections(of: .workItem(organization: organization, id: 5101))
        #expect(story.map(\.item.title) == ["Save items for later in the cart service"])
        #expect(story.first?.item.status == "Active")
        // A work item that isn't in the sprint, linked to one of your pull requests.
        let retry = links.connections(of: .pullRequest(organization: organization, number: 4102))
        #expect(retry.map(\.item.title) == ["Retry payments that fail for a moment"])
        // The bug reaches the session through its pull request.
        let bug = links.connections(of: .workItem(organization: organization, id: 5110))
        #expect(bug.first { $0.item.ref == session }?.via?.ref == .pullRequest(organization: organization, number: 4091))
        #expect(links.unknown([.workItem, .pullRequest]).isEmpty)
        // A story's tasks, in the sprint, are something to sum up besides what's linked; a task has none.
        #expect(links.describe(.workItem(organization: organization, id: 5101)).parts == 4)
        #expect(links.describe(.workItem(organization: organization, id: 5103)).parts == 0)

        // What's linked that the lists and the sprint don't show stays looked up once it's been read, so the engine keeps
        // it rather than forgetting it and reading it again.
        let inputs = workLinks.inputs()
        #expect(inputs.workItemLookups == [WorkItemKey(organization, 5160), WorkItemKey(organization, 5170)])
        #expect(inputs.pullRequestLookups == [PRKey(organization, 4118), PRKey(organization, 4120)])
        await workLinks.loadOnce()
        #expect(workLinks.inputs() == inputs)

        links.setOn(false)
        #expect(links.connections(of: .pullRequest(organization: organization, number: 4091)).isEmpty)
        #expect(workLinks.inputs().workItemLookups.isEmpty)
    }

    @Test func itTellsWhatItKnowsOfItsPullRequestsAndTasksWithoutReadingMore() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        let sprint = SprintStore(settings: settings, mode: .demo, client: store.client)
        let copilot = CopilotTasksStore(settings: settings, mode: .demo, notifier: nil)
        let links = Links(defaults: MemoryDefaults(), isDemo: true)
        await store.loadOnce()
        await sprint.loadOnce()
        let workLinks = WorkLinksStore(
            links: links, stories: ItemStories(links: links), store: store, sprint: sprint, copilot: copilot, settings: settings
        )
        await workLinks.loadOnce()

        // One of your pull requests: all that's read of it, with the build that ran on it.
        let coupon = try #require(workLinks.tell(.pullRequest(organization: organization, number: 4091)))
        #expect(coupon.sentence.hasPrefix("Ready to complete: Approved by"))
        // Which its sentence says, once.
        #expect(!coupon.facts.contains { $0.label == "Reviewers" })
        #expect(coupon.facts.first?.label == "Comments")
        #expect(coupon.runs.map(\.name) == ["payments-api CI"])
        #expect(coupon.runs.first?.state == .done)
        // A teammate's, which the lists don't show: what the pull request says itself.
        let saved = try #require(workLinks.tell(.pullRequest(organization: organization, number: 4120)))
        #expect(saved.facts.first == ItemStory.Fact("Author", "Sam Rivera"))
        #expect(saved.runs.isEmpty)
        #expect(saved.footnote != nil)
        // A task sent to Copilot: how it went, what it opened, and the summary it ended with.
        let task = try #require(workLinks.tell(session))
        #expect(task.sentence == "Opened !4091")
        #expect(task.facts == [ItemStory.Fact("Model", "Claude Opus 5.5 · Max")])
        #expect(task.account?.overview == "Coupon totals now round half up, with tests for every currency. Opened pull request 4091.")
        // Azure DevOps doesn't tell about the app's own sessions.
        #expect(workLinks.tell(.session("0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01")!) == nil)
        // A sprint's work item: who has it and how its tasks stand.
        let story = try #require(workLinks.tell(.workItem(organization: organization, id: 5101)))
        #expect(story.sentence == "Active")
        #expect(story.facts.prefix(2) == [ItemStory.Fact("Assigned to", "Robin Diaz"), ItemStory.Fact("Tasks", "1 of 4 done")])
        #expect(story.more == [ItemStory.Fact("Type", "User Story")])
        #expect(story.facts.contains(ItemStory.Fact("Work", "6 h left")))
        #expect(workLinks.tell(.workItem(organization: organization, id: 9999)) == nil)
    }

    @Test func whoSentAPullRequestInAChatIsntShared() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        let sprint = SprintStore(settings: settings, mode: .demo, client: store.client)
        let copilot = CopilotTasksStore(settings: settings, mode: .demo, notifier: nil)
        let links = Links(defaults: MemoryDefaults(), isDemo: true)
        await store.loadOnce()
        await sprint.loadOnce()
        let workLinks = WorkLinksStore(
            links: links, stories: ItemStories(links: links), store: store, sprint: sprint, copilot: copilot, settings: settings
        )
        await workLinks.loadOnce()

        // Dana sent it in Teams, and it needs you; Priya sent the other, and you approved it.
        for (number, status) in [(4113, "Needs You"), (4108, "Answered")] {
            let ref = ItemRef.pullRequest(organization: organization, number: number)
            let row = links.describe(ref)
            #expect(row.status == status)
            #expect(row.statusToShare == "Active")
            let story = try #require(workLinks.tell(ref))
            #expect(story.sentence.contains("sent this in Teams"))
            let shared = try #require(story.sharedSentence)
            #expect(!shared.isEmpty)
            for said in ["Dana", "Priya", "Teams", "sent this"] {
                #expect(!shared.contains(said))
            }
        }
        // One that's there for itself says so as it is.
        let coupon = links.describe(.pullRequest(organization: organization, number: 4091))
        #expect(coupon.sharedStatus == nil)
        #expect(try #require(workLinks.tell(coupon.ref)).sharedSentence == nil)
    }

    /// A task's row and story say how it works, not for how long, which its date says: a minute later, they're the same.
    @Test func aTaskAtWorkSaysTheSameAsTimePasses() async throws {
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        let working = try #require(CopilotTaskEntry.demo(now: start).first { $0.status.phase == .working && $0.workItem?.id == 5103 })
        // The lists say for how long.
        #expect(working.sentence(now: start) == "Working for 6m: Run the cart tests")
        #expect(working.sentence(now: start.addingTimeInterval(60)) == "Working for 7m: Run the cart tests")
        #expect(working.sentence(now: nil) == "Working: Run the cart tests")
        #expect(WorkLinksStore.story(of: working).sentence == "Working: Run the cart tests")

        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        let sprint = SprintStore(settings: settings, mode: .demo, client: store.client)
        let copilot = CopilotTasksStore(settings: settings, mode: .demo, notifier: nil)
        let links = Links(defaults: MemoryDefaults(), isDemo: true)
        await store.loadOnce()
        await sprint.loadOnce()
        let workLinks = WorkLinksStore(
            links: links, stories: ItemStories(links: links), store: store, sprint: sprint, copilot: copilot, settings: settings
        )
        await workLinks.loadOnce()
        let row = links.describe(try #require(ItemRef.session(working.id)))
        #expect(row.status == "Working: Run the cart tests")
    }

    /// The work sent to Copilot waits on Copilot while it goes on, and on you once the one sent last for something failed,
    /// unless that's done since.
    @Test func workSentToCopilotWaitsOnYouOnceTheOneSentLastFailed() {
        func sent(_ phase: RunPhase, minutesAgo: Double, session: Int) -> CopilotTaskEntry {
            CopilotTaskEntry(
                id: String(format: "1d6b2c7e-4f0a-4b8e-9c31-%012d", session),
                workItem: WorkItemReference(organization: "Contoso", project: "Storefront", id: 5103), options: CopilotModel.standard,
                startedAt: Date(timeIntervalSince1970: 1_792_000_000 - minutesAgo * 60), status: RunStatus(phase: phase)
            )
        }
        let task = ItemRef.workItem(organization: "contoso", id: 5103)
        let failed = sent(.failed, minutesAgo: 10, session: 1)
        #expect(failed.target == task)
        // A work item, by its type when it's known, and "it" on itself.
        #expect(CopilotTaskEntry.waits(of: [failed], isDone: { _ in false }) { _ in "Task" } == [ItemStory.Wait(
            .you, "you, to look at Copilot's work on task 5103, which failed", about: ItemRef.session(failed.id),
            onItself: .init(task, "you, to look at Copilot's work on it, which failed")
        )])
        #expect(CopilotTaskEntry.waits(of: [failed], isDone: { _ in false }).map(\.text)
            == ["you, to look at Copilot's work on work item 5103, which failed"])
        // Sent again since: Copilot's at it, whichever order they come in.
        let working = sent(.working, minutesAgo: 1, session: 2)
        #expect(CopilotTaskEntry.waits(of: [failed, working], isDone: { _ in false }) { _ in "Task" }.map(\.text) == ["Copilot, on task 5103"])
        // Or the task is done since.
        #expect(CopilotTaskEntry.waits(of: [failed]) { $0 == task }.isEmpty)
        // A task's work that went on to a pull request and failed there, sent again on that pull request since: among all
        // that was sent, it's not the latest, though it's the task's.
        let pullRequest = PullRequestReference(organization: "contoso", project: "Storefront", repository: "shop-web", id: 4120,
                                               sourceBranch: "saved-items")
        var wentOn = sent(.failed, minutesAgo: 10, session: 3)
        wentOn.onPullRequest = pullRequest
        var again = sent(.finished, minutesAgo: 2, session: 4)
        again.workItem = nil
        again.onPullRequest = pullRequest
        #expect(CopilotTaskEntry.waits(of: [wentOn], isDone: { _ in false }).map(\.text)
            == ["you, to look at Copilot's work on !4120, which failed"])
        #expect(CopilotTaskEntry.waits(of: [wentOn], among: [again, wentOn], isDone: { _ in false }).isEmpty)
    }

    /// A work item's story told before its details were read, as Where It Stands asks for it as it shows, is told again
    /// once they are, so a summary asked for then has its description and comments.
    @Test func aWorkItemsStoryIsToldAgainOnceItsDetailsAreRead() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        let sprint = SprintStore(settings: settings, mode: .demo, client: store.client)
        let copilot = CopilotTasksStore(settings: settings, mode: .demo, notifier: nil)
        let links = Links(defaults: MemoryDefaults(), isDemo: true)
        links.setOn(true)
        let stories = ItemStories(links: links)
        await store.loadOnce()
        await sprint.loadOnce()
        let workLinks = WorkLinksStore(links: links, stories: stories, store: store, sprint: sprint, copilot: copilot, settings: settings)
        let details = WorkItemDetailsStore(mode: .demo, client: store.client, board: sprint.$board.eraseToAnyPublisher())
        workLinks.details = details
        await workLinks.loadOnce()
        let item = try #require(sprint.board?.rows.compactMap(\.parent).first { $0.id == 5101 })
        let row = links.describe(item.linkRef)
        await stories.tell([row])
        #expect(stories.story(for: item.linkRef)?.notesRead == false)
        await details.loadOnce(item)
        await stories.tell([row])
        #expect(stories.story(for: item.linkRef)?.notesRead == true)
        #expect(stories.story(for: item.linkRef)?.notes.isEmpty == false)
    }

    @Test func looksUpWhatsLinkedButNotListedWhateverIsDescribed() {
        let listed: Set<ItemRef> = [.pullRequest(organization: "contoso", number: 4091), .workItem(organization: "contoso", id: 5110)]
        let linked: Set<ItemRef> = listed.union([
            .pullRequest(organization: "Contoso", number: 4120), .workItem(organization: "contoso", id: 5160),
            .gitHubPullRequest(repository: "octo/shop", number: 12), session,
        ])
        let lookups = WorkLinksStore.lookups(linked, listed: listed)
        #expect(lookups.workItems == [WorkItemKey("contoso", 5160)])
        #expect(lookups.pullRequests == [PRKey("contoso", 4120)])
    }
}
