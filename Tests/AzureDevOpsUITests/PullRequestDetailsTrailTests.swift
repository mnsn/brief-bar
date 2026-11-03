import AzureDevOpsCore
import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsUI

/// The thread a pull request's details were taken to, which their trail names after the pull request ("!4102 ›
/// PaymentsClient.cs:88") until they go elsewhere. With the made-up pull requests.
@MainActor
@Suite struct PullRequestDetailsTrailTests {
    private typealias Place = PullRequestDetailsStore.Place

    private func makeStore() throws -> (PullRequestDetailsStore, PRSnapshot, PRSnapshot) {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let items = DemoData.records(now: now).compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), dismissedCutoff: seen.dismissedCutoff(for: $0.id), now: now)
        }
        let store = PullRequestDetailsStore()
        store.itemsChanged(items)
        return (store, try #require(items.first { $0.key.number == 4102 }), try #require(items.first { $0.key.number == 4088 }))
    }

    @Test func theTrailNamesTheThreadTheDetailsWereTakenTo() throws {
        let (store, item, other) = try makeStore()
        store.show(item)
        #expect(store.trailThread == nil)
        // Taken to a thread from elsewhere: the trail names it.
        store.show(item, at: .thread(11))
        #expect(store.trailThread == 11 && store.place == .thread(11))
        // Once they're there, it still does.
        store.reached(.thread(11))
        #expect(store.trailThread == 11 && store.place == nil)
        // Another place in them: it doesn't.
        store.go(to: .section(.checks))
        #expect(store.trailThread == nil)
        store.go(to: .thread(13))
        #expect(store.trailThread == 13)
        // The pull request in the trail goes back to their top.
        store.goToTop()
        #expect(store.trailThread == nil && store.place == .top)
        // A page opened over them, another pull request, or closing them: it doesn't either.
        store.go(to: .thread(11))
        store.open(page: .workItem(organization: DemoData.organization, id: 5160))
        #expect(store.trailThread == nil)
        store.show(item, at: .thread(11))
        store.show(other)
        #expect(store.trailThread == nil)
        store.show(item, at: .thread(11))
        store.close()
        #expect(store.trailThread == nil)
    }

    @Test func theirTopIsWhereTheTitleIs() {
        #expect(Place.top.anchor(in: []) == .top)
        #expect(Place.thread(11).thread == 11)
        #expect(Place.top.thread == nil && Place.run(1).thread == nil && Place.section(.comments).thread == nil)
    }
}
