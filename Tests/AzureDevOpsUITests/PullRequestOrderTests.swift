import AzureDevOpsCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// How you sort the pull requests is a choice kept in the preferences, by status until you make it; by date, the list has
/// every pull request it has by status, by when each was created. With the made-up pull requests, which never use the Azure
/// CLI or Azure DevOps.
@MainActor
@Suite struct PullRequestOrderTests {
    @Test func byStatusUntilYouChoose() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.pullRequestOrder == .status)

        settings.pullRequestOrder = .oldestFirst
        // Kept for the next launch.
        #expect(AppSettings(defaults: defaults).pullRequestOrder == .oldestFirst)

        // Something else in the preferences, by status.
        defaults.set("sideways", forKey: SettingsKey.pullRequestOrder)
        #expect(AppSettings(defaults: defaults).pullRequestOrder == .status)
    }

    @Test func byDateListsTheSamePullRequestsByWhenEachWasCreated() async {
        let store = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await store.loadOnce()
        #expect(!store.items.isEmpty)
        #expect(store.items(by: .status) == store.items)

        let newest = store.items(by: .newestFirst)
        let oldest = store.items(by: .oldestFirst)
        #expect(Set(newest.map(\.key)) == Set(store.items.map(\.key)))
        #expect(Set(oldest.map(\.key)) == Set(store.items.map(\.key)))
        let created = oldest.map { $0.createdAt ?? .distantFuture }
        #expect(created == created.sorted())
        let newestCreated: [Date] = newest.map { $0.createdAt ?? .distantPast }
        #expect(newestCreated == newestCreated.sorted(by: >))
        // What the status order counts stays as it was.
        #expect(GroupCounts(newest) == store.counts)

        // In one list, all but Done's and Idle's, which keep their own sections.
        let listed = store.dateList(.oldestFirst)
        let apart: Set<PRGroup> = [.done, .idle]
        #expect(listed == oldest.filter { !apart.contains($0.group) })
        #expect(listed.count == store.items.count - store.counts.done - store.counts.idle)
        let groups = Set(listed.map(\.group))
        #expect(groups.contains(.needsYou))
        #expect(groups.contains(.ready))
    }
}
