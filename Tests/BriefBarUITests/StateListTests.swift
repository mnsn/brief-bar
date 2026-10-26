import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

@Suite struct StateListTests {
    private func entry(_ section: SectionID, _ id: String, _ state: ItemState, _ minutesAgo: Double?, isReady: Bool = false) -> StateListEntry {
        StateListEntry(section: section, row: StateRow(
            id: id, state: state, date: minutesAgo.map { Date(timeIntervalSince1970: 100_000 - $0 * 60) },
            view: AnyView(EmptyView()), isReady: isReady
        ))
    }

    @Test func groupsEverySourcesThingsByStateNewestFirst() {
        let groups = StateList.groups([
            entry(.copilotSessions, "done", .done, 30),
            entry(.teamsChats, "avery", .needsYou, 12),
            entry(.azureDevOpsPullRequests, "4091", .needsYou, 8),
            entry(.copilotSessions, "release", .needsYou, 1),
            entry(.azureDevOpsPipelines, "shop-web", .failing, 20),
            entry(.copilotSessions, "tests", .running, 3),
            entry(.azureDevOpsPullRequests, "4088", .failing, 40),
        ])
        // Needs you, something's wrong, running, then done or ready.
        #expect(groups.map(\.state) == [.needsYou, .failing, .running, .done])
        #expect(groups[0].entries.map(\.row.id) == ["release", "4091", "avery"])
        #expect(groups[1].entries.map(\.id) == ["azureDevOps.pipelines/shop-web", "azureDevOps.pullRequests/4088"])
        #expect(groups[2].entries.map(\.section) == [.copilotSessions])
    }

    @Test func putsThingsWithoutADateLastInTheOrderTheyCame() {
        let groups = StateList.groups([
            entry(.teamsChats, "a", .needsYou, nil),
            entry(.teamsGroupChats, "b", .needsYou, 5),
            entry(.teamsChats, "c", .needsYou, nil),
            entry(.azureDevOpsPullRequests, "d", .needsYou, 5),
        ])
        #expect(groups.map(\.state) == [.needsYou])
        #expect(groups[0].entries.map(\.row.id) == ["b", "d", "a", "c"])
        #expect(StateList.groups([]).isEmpty)
    }

    @Test func readinessAndCompletionSplitOnlyWhenRequestedWithoutDroppingRows() {
        let entries = [
            entry(.copilotSessions, "finished", .done, 1),
            entry(.azureDevOpsPullRequests, "ready-older", .done, 10, isReady: true),
            entry(.githubPullRequests, "ready-newer", .done, 2, isReady: true),
            entry(.copilotSessions, "permission", .needsYou, 3),
            entry(.azureDevOpsPipelines, "failed", .failing, 5),
        ]
        let original = StateList.groups(entries)
        #expect(original.map(\.title) == ["Needs You", "Something's Wrong", "Done or Ready"])
        #expect(original.last?.entries.map(\.row.id) == ["finished", "ready-newer", "ready-older"])

        let separated = StateList.groups(entries, separateReady: true)
        #expect(separated.map(\.title) == ["Needs You", "Something's Wrong", "Ready to Merge", "Finished"])
        #expect(separated[2].entries.map(\.row.id) == ["ready-newer", "ready-older"])
        #expect(separated[3].entries.map(\.row.id) == ["finished"])
        #expect(Set(separated.flatMap(\.entries).map(\.id)) == Set(entries.map(\.id)))
        #expect(Set(separated.map(\.id)).count == separated.count)
        #expect(StateList.groups(entries, separateReady: false).map(\.id) == original.map(\.id))
    }

    @Test func readinessDoesNotRelabelFailuresOrCreateEmptyGroups() {
        let entries = [entry(.githubPullRequests, "failed", .failing, nil, isReady: true)]
        let groups = StateList.groups(entries, separateReady: true)
        #expect(groups.map(\.title) == ["Something's Wrong"])
        #expect(groups.first?.completion == nil)
        #expect(StateList.groups([], separateReady: true).isEmpty)
    }
}
