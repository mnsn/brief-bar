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

    /// Turning Summaries off asks lists to look again at once, though no pull request changed.
    @Test func listsLookAgainWhenSummariesChange() async {
        let source = AzureDevOpsSource(services: AppServices(defaults: MemoryDefaults(), isDemo: true))
        source.start()
        defer { source.stop() }
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let subscription = source.stateRowsChanged.sink { count.value += 1 }
        defer { subscription.cancel() }
        // What starting sends first, through the main queue, until a turn of it brings nothing more.
        for _ in 0..<20 {
            let sent = count.value
            await mainQueueTurn()
            if count.value == sent { break }
        }
        count.value = 0

        source.settings.summaries = false
        await mainQueueTurn()
        // At least once: the demo's own comment, six seconds after it starts, asks lists to look again too, and a
        // busy runner can take that long.
        #expect(count.value >= 1)
    }

    /// Lets the main queue run what's on it, and what that puts on it in turn: the source tells lists through it.
    private func mainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
