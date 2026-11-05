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

    /// A click shows what it's for in BriefBar's window where it can: from a page of the window, and from the menu bar or a
    /// widget as its source says; else, and once showing it fails, where it lives. Its menu has the other way to it.
    @Test func aClickShowsWhatItsForInBriefBarWhereItCan() {
        var opened = 0
        var shown = 0
        var canShow = true
        var shows = true
        var fromMenuBar = false
        let sent = SentTask(
            id: "a", name: "Fix Comments: !4071 Fix totals", place: "shop-web", stage: .finished, detail: nil, since: nil,
            opens: "Pull Request", whereItOpens: "in Azure DevOps", open: { opened += 1 }, canShow: { canShow },
            show: {
                shown += 1
                return shows
            },
            showsFromMenuBar: { fromMenuBar }, menu: { AnyView(EmptyView()) }
        )
        #expect(sent.openTitle == "Open Pull Request in Azure DevOps")
        #expect(sent.showTitle == "Show Pull Request in BriefBar")

        sent.click(inWindow: true)
        #expect(shown == 1 && opened == 0)
        #expect(sent.clickTitle(inWindow: true) == "Show Pull Request in BriefBar")
        #expect(sent.otherOpening(inWindow: true)?.title == "Open Pull Request in Azure DevOps")
        sent.otherOpening(inWindow: true)?.action()
        #expect(shown == 1 && opened == 1)

        // From the menu bar, where it lives, until its source says otherwise; its details second.
        sent.click(inWindow: false)
        #expect(shown == 1 && opened == 2)
        #expect(sent.clickTitle(inWindow: false) == "Open Pull Request in Azure DevOps")
        sent.otherOpening(inWindow: false)?.action()
        #expect(shown == 2 && opened == 2)
        fromMenuBar = true
        sent.click(inWindow: false)
        #expect(shown == 3 && opened == 2)

        // It couldn't show after all, as when no window has the page anymore: where it lives.
        shows = false
        sent.click(inWindow: true)
        #expect(shown == 4 && opened == 3)
        // It can't show there: where it lives alone.
        canShow = false
        sent.click(inWindow: true)
        #expect(shown == 4 && opened == 4)
        #expect(sent.clickTitle(inWindow: true) == "Open Pull Request in Azure DevOps")
        #expect(sent.otherOpening(inWindow: true) == nil && sent.otherOpening(inWindow: false) == nil)
        // Where it lives is part of what it is.
        #expect(sent != SentTask(
            id: "a", name: "Fix Comments: !4071 Fix totals", place: "shop-web", stage: .finished, detail: nil, since: nil,
            opens: "Pull Request", open: {}, menu: { AnyView(EmptyView()) }
        ))
        // A pull request on GitHub, as a work item's task can open, is said to open there; one that says nothing of where,
        // as before.
        let onGitHub = SentTask(
            id: "b", name: "Work Item 4217", place: "shop-web", stage: .finished, detail: nil, since: nil,
            opens: "Pull Request", whereItOpens: "on GitHub", open: {}, menu: { AnyView(EmptyView()) }
        )
        #expect(onGitHub.openTitle == "Open Pull Request on GitHub")
        #expect(onGitHub.clickTitle(inWindow: true) == "Open Pull Request on GitHub" && onGitHub.otherOpening(inWindow: true) == nil)
        #expect(task("c").openTitle == "Open Pull Request")
    }
}
