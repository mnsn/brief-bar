import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

@Suite struct StateListTests {
    private func entry(_ section: SectionID, _ id: String, _ state: ItemState, _ minutesAgo: Double?) -> StateListEntry {
        StateListEntry(section: section, row: StateRow(
            id: id, state: state, date: minutesAgo.map { Date(timeIntervalSince1970: 100_000 - $0 * 60) }, view: AnyView(EmptyView())
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
}
