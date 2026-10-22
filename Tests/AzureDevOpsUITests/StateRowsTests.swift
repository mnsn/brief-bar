import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// A list by state shows the same pull requests as the menu bar counts: the made-up ones, which never use the Azure CLI
/// or Azure DevOps.
@MainActor
@Suite struct StateRowsTests {
    private func states(_ rows: [StateRow]) -> StateCounts {
        var counts = StateCounts()
        for row in rows { counts[row.state] += 1 }
        return counts
    }

    @Test func listsWhatTheMenuBarCountsByState() {
        let source = AzureDevOpsSource(services: AppServices(defaults: MemoryDefaults(), isDemo: true))
        source.start()
        defer { source.stop() }

        let rows = source.stateRows(for: .azureDevOpsPullRequests)
        #expect(states(rows) == StateCounts(needsYou: 4, failing: 2, done: 2))
        #expect(states(rows) == source.segment(for: .azureDevOpsPullRequests).states)
        #expect(Set(rows.map(\.id)).count == rows.count)

        // To Review joins what needs you only while the menu bar shows it.
        source.settings.showToReview = true
        let withToReview = source.stateRows(for: .azureDevOpsPullRequests)
        #expect(states(withToReview) == StateCounts(needsYou: 5, failing: 2, done: 2))
        #expect(states(withToReview) == source.segment(for: .azureDevOpsPullRequests).states)

        // The sprint's work isn't in any state.
        #expect(source.stateRows(for: .azureDevOpsSprint).isEmpty)
        #expect(source.info(for: .azureDevOpsSprint)?.states.isEmpty == true)
    }
}
