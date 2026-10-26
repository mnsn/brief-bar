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
        let workLinks = WorkLinksStore(links: links, store: store, sprint: sprint, copilot: copilot, settings: settings)
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
