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
        #expect(rows.filter(\.isReady).count == 2)
        #expect(rows.filter(\.isReady).allSatisfy { $0.state == .done })

        // To Review joins what needs you only while the menu bar shows it.
        source.settings.showToReview = true
        let withToReview = source.stateRows(for: .azureDevOpsPullRequests)
        #expect(states(withToReview) == StateCounts(needsYou: 5, failing: 2, done: 2))
        #expect(states(withToReview) == source.segment(for: .azureDevOpsPullRequests).states)

        // The sprint's work isn't in any state.
        #expect(source.stateRows(for: .azureDevOpsSprint).isEmpty)
        #expect(source.info(for: .azureDevOpsSprint)?.states.isEmpty == true)
    }

    @Test func saysTheSamePullRequestsInTheBriefAndAsksTheModelOnlyWithSummaries() {
        let source = AzureDevOpsSource(services: AppServices(defaults: MemoryDefaults(), isDemo: true))
        source.start()
        defer { source.stop() }

        let lines = source.briefLines(for: .azureDevOpsPullRequests)
        var counts = StateCounts()
        for line in lines { counts[line.state] += 1 }
        #expect(counts == source.segment(for: .azureDevOpsPullRequests).states)
        #expect(Set(lines.map(\.id)).count == lines.count)
        #expect(lines.allSatisfy { $0.source == .azureDevOps && !$0.sentence.isEmpty })
        // The demo's comments have text for the model to condense, while Summaries is on.
        #expect(source.settings.summaries)
        #expect(lines.contains { $0.request != nil })

        source.settings.summaries = false
        #expect(source.briefLines(for: .azureDevOpsPullRequests).allSatisfy { $0.request == nil })
    }

    @Test func readableWidgetsGrowWithoutStartingASourceOrChangingOtherSettings() {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = AzureDevOpsSource(services: services)
        for section in [SectionID.azureDevOpsPullRequests, .azureDevOpsSprint, .azureDevOpsPipelines] {
            let height = source.widgetHeight(for: section, rows: 3)
            #expect(height == 162)
        }
        services.setInterfaceOption(.readableRows, enabled: true)
        for section in [SectionID.azureDevOpsPullRequests, .azureDevOpsSprint, .azureDevOpsPipelines] {
            let height = source.widgetHeight(for: section, rows: 3)
            #expect(height == 174)
            #expect(source.stateRows(for: section).isEmpty)
        }
        services.setInterfaceOption(.readableRows, enabled: false)
        let restored = source.widgetHeight(for: .azureDevOpsPullRequests, rows: 3)
        #expect(restored == 162)
    }

    /// Turning Summaries off asks lists to look again at once, though no pull request changed.
    @Test func listsLookAgainWhenSummariesChange() async {
        let source = AzureDevOpsSource(services: AppServices(defaults: MemoryDefaults(), isDemo: true))
        source.start()
        defer { source.stop() }
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let subscription = source.stateRowsChanged.sink { count.value += 1 }
        defer { subscription.cancel() }
        // What starting sends first, however long a busy machine takes to send it: until nothing more comes for a moment.
        var seen = -1
        for _ in 0..<50 where seen != count.value {
            seen = count.value
            try? await Task.sleep(for: .milliseconds(200))
        }
        count.value = 0

        source.settings.summaries = false
        for _ in 0..<100 where count.value == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // At least once: on a busy machine, the demo's own new comment, a few seconds after it starts, can come too.
        #expect(count.value >= 1)
    }
}
