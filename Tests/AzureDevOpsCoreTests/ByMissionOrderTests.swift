import Foundation
import Testing
@testable import AzureDevOpsCore

/// By Mission, the window's order for the pull requests that go together: wherever it's not drawn, they list by status.
@Suite struct ByMissionOrderTests {
    @Test func byMissionListsByStatusWhereverItsNotDrawnAndIsNotByDate() throws {
        func item(_ number: Int, _ group: PRGroup, since: Date) throws -> PRSnapshot {
            var snapshot = try #require(PRClassifier.snapshot(
                for: PRRecord(pullRequest: makePR(number), role: .author, me: People.me.id), seenCutoff: t(-3 * day),
                dismissedCutoff: t(-3 * day), now: t(0)
            ))
            snapshot.group = group
            snapshot.since = since
            return snapshot
        }
        let items = [
            try item(1, .idle, since: t(-1)), try item(2, .needsYou, since: t(-5)), try item(3, .ready, since: t(-50)),
            try item(4, .waiting, since: t(0)), try item(5, .failing, since: t(-hour)),
        ]

        #expect(PROrdering.sorted(items.shuffled(), by: .byMission) == PROrdering.sorted(items))
        #expect(!PROrder.byMission.isByDate)
        #expect(PROrder(rawValue: "byMission") == .byMission)
    }
}
