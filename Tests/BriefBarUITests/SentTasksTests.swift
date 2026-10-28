import BriefBarCore
import Combine
import Foundation
import SwiftUI
import Testing
@testable import BriefBarUI

/// The tasks BriefBar sent to the Copilot CLI, which the source that sent them tells, for Copilot's list.
@MainActor
@Suite struct SentTasksTests {
    private func task(_ id: String, stage: SentTask.Stage = .working, detail: String? = nil, open: @escaping () -> Void = {}) -> SentTask {
        SentTask(
            id: id, name: "Fix Comments: !4071 Fix totals", place: "shop-web", stage: stage, detail: detail, since: nil,
            opens: "Pull Request", open: open, menu: { AnyView(EmptyView()) }
        )
    }

    @Test func showsEachSourcesTasksUntilItWithdrawsThem() {
        let sent = SentTasks()
        #expect(sent.tasks.isEmpty)
        sent.publish(.azureDevOps, tasks: [task("a"), task("b")])
        #expect(sent.tasks.map(\.id) == ["a", "b"])
        // What it says now replaces what it said.
        sent.publish(.azureDevOps, tasks: [task("b", stage: .finished)])
        #expect(sent.tasks.map(\.id) == ["b"])
        #expect(sent.tasks.first?.stage == .finished)
        sent.withdraw(.azureDevOps)
        #expect(sent.tasks.isEmpty)
    }

    /// Each task once, as the first source in BriefBar's order says it, and nothing new when nothing changed but what its
    /// actions do.
    @Test func listsATaskOnceAndOnlyChangesWithIt() {
        let sent = SentTasks()
        sent.publish(.azureDevOps, tasks: [task("a")])
        sent.publish(.copilot, tasks: [task("a", stage: .failed), task("c")])
        #expect(sent.tasks.map(\.id) == ["a", "c"])
        #expect(sent.tasks.first?.stage == .working)

        var changes = 0
        let subscription = sent.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        var opened = false
        sent.publish(.azureDevOps, tasks: [task("a") { opened = true }])
        #expect(changes == 0)
        sent.publish(.azureDevOps, tasks: [task("a", detail: "Run the tests")])
        #expect(changes == 1)
        #expect(sent.tasks.first?.detail == "Run the tests")
        sent.withdraw(.teams)
        #expect(changes == 1)
        #expect(!opened)
    }

    @Test func opensWhatItsFor() {
        var opened = 0
        let pullRequest = task("a") { opened += 1 }
        #expect(pullRequest.openTitle == "Open Pull Request")
        pullRequest.open()
        #expect(opened == 1)
        #expect(pullRequest == task("a"))
        #expect(pullRequest != task("a", stage: .finished))
    }
}
