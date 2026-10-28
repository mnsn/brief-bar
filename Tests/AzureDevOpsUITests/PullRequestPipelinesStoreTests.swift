import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import Foundation
import Testing
@testable import AzureDevOpsUI

@MainActor
@Suite struct PullRequestPipelinesStoreTests {
    @Test func publishesAccountAndAuthoredListAtomicallyEvenWhenPRsAreUnchanged() async {
        let store = PRStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        var snapshot = DemoData.snapshot(now: Date())
        snapshot.account = "tenant/robin"
        store.receive(snapshot)
        let first = store.authoredPullRequestList
        var received: [AuthoredPullRequestList] = []
        let subscription = store.$authoredPullRequestList.sink { received.append($0) }
        snapshot.account = "tenant/sam"
        store.receive(snapshot)
        #expect(received.count == 2)
        #expect(received.last?.account == "tenant/sam")
        #expect(received.last?.pullRequests == first.pullRequests)
        subscription.cancel()
    }

    @Test func includesOnlyAuthoredActivePRsIncludingDraftsAndIdlePRs() async {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        await store.loadOnce()
        let snapshot = DemoData.snapshot(now: store.now)
        let expected = snapshot.records.filter { $0.role == .author && $0.pullRequest.status == .active }.map(\.pullRequest)
        #expect(Set(store.authoredPullRequests.map(\.key)) == Set(expected.map(\.key)))
        #expect(store.authoredPullRequests.contains { $0.isDraft })
        #expect(store.items.contains { item in
            item.role == .author && item.group == .idle && store.authoredPullRequests.contains { $0.key == item.key }
        })

        var closed = snapshot
        for index in closed.records.indices where closed.records[index].role == .author {
            closed.records[index].pullRequest.status = index.isMultiple(of: 2) ? .completed : .abandoned
        }
        store.receive(closed)
        #expect(store.authoredPullRequests.isEmpty)
    }

    @Test func demoUpdatesAndRemovesPRCardsWithoutChangingPinnedCounts() async {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        await store.loadOnce()
        let pipelines = PipelinesStore(settings: settings, mode: .demo, client: store.client)
        pipelines.setPullRequests(store.authoredPullRequests)
        await pipelines.loadOnce()
        let counts = pipelines.counts
        let pinned = settings.pinnedPipelines
        #expect(pipelines.pullRequests.map(\.id) == store.authoredPullRequests.map(\.key))
        pipelines.setPullRequests([])
        #expect(pipelines.pullRequests.isEmpty)
        #expect(pipelines.counts == counts)
        #expect(settings.pinnedPipelines == pinned)
    }

    @Test func createsFreshPlaceholdersWhenPRMetadataChanges() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        await store.loadOnce()
        var pr = try #require(store.authoredPullRequests.first)
        // A live store can show placeholders without starting its engine or using Azure DevOps.
        let pipelines = PipelinesStore(settings: settings, mode: .live, client: store.client)
        pipelines.setPullRequests([pr])
        #expect(pipelines.pullRequests.first?.pullRequest == pr)
        pr.sourceCommit = "new-source"
        pipelines.setPullRequests([pr])
        #expect(pipelines.pullRequests.first?.hasLoaded == false)
        #expect(pipelines.pullRequests.first?.pullRequest.sourceCommit == "new-source")
        pipelines.setPullRequests([])
        #expect(pipelines.pullRequests.isEmpty)
    }
}
