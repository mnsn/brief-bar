import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// What a work item on the Sprint page opens a click away: the tasks you sent it to Copilot, and the sessions and pull
/// requests Show Links links to it, each once, as BriefBar knows them, reading nothing for it.
@MainActor
@Suite struct WorkItemShortcutsTests {
    private let now = Date(timeIntervalSince1970: 1_792_317_600)
    /// Sessions' IDs: a task you sent with the CLI, one of the Copilot app's, and one on its pull request's branch.
    private let sent = "11111111-1111-4111-8111-111111111111"
    private let inApp = "22222222-2222-4222-8222-222222222222"
    private let onBranch = "33333333-3333-4333-8333-333333333333"

    /// Task 5104 of the demo's sprint.
    private func task() throws -> WorkItem {
        try #require(DemoData.sprintBoard(now: now).item(WorkItemKey(DemoData.organization, 5104)))
    }

    private func copilot() -> CopilotTasksStore {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        return CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
    }

    /// A folder of its own, for a task's worktree.
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarWorkItemShortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The task you sent it with, which ran with the CLI in `worktree` and finished without a pull request; or, with
    /// `pullRequest`, a task BriefBar ran on that pull request, as Fix the Build does.
    private func run(_ id: String? = nil, onPullRequest pullRequest: Int? = nil, in worktree: URL) -> CopilotRun {
        CopilotRun(
            id: id ?? sent,
            workItem: pullRequest == nil ? WorkItemReference(organization: DemoData.organization, project: "Storefront", id: 5104) : nil,
            onPullRequest: pullRequest.map {
                PullRequestReference(organization: DemoData.organization, project: "Storefront", repository: "shop-web", id: $0,
                                     sourceBranch: "coupon-rounding")
            },
            options: CopilotModel.standard, repository: URL(fileURLWithPath: "/Users/robin/dev/Storefront"), worktree: worktree,
            startedAt: now, process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished
        )
    }

    /// Show Links, with what Copilot and Azure DevOps say: one of the app's sessions linked to the task, which waits on you;
    /// its pull request, !4091; a session on that pull request's branch; and the task you sent, as Azure DevOps tells it.
    private func links(for item: WorkItem) throws -> Links {
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        links.setOn(true)
        let pullRequest = ItemRef.pullRequest(organization: DemoData.organization, number: 4091)
        let app = try #require(ItemRef.session(inApp)), branch = try #require(ItemRef.session(onBranch))
        let own = try #require(ItemRef.session(sent))
        links.publish(.copilot, links: [
            try #require(ItemLink(app, item.linkRef, origin: .session)), try #require(ItemLink(branch, pullRequest, origin: .branch)),
        ], items: [
            LinkedItem(ref: app, label: "Save items for later", title: "Save items for later", symbol: "waveform.path.ecg",
                       color: .orange, state: .needsYou, status: "Waiting for your answer", date: now),
            LinkedItem(ref: branch, label: "Fix the cart tests", title: "Fix the cart tests", symbol: "waveform.path.ecg",
                       color: .blue, state: .running, status: "Working", date: now),
        ])
        links.publish(.azureDevOps, links: [
            try #require(ItemLink(item.linkRef, pullRequest, origin: .azureDevOps)), try #require(ItemLink(own, item.linkRef, origin: .copilot)),
        ], items: [
            LinkedItem(ref: pullRequest, label: "!4091", title: "Round half up in the coupon service", symbol: "arrow.triangle.pull",
                       color: .blue, status: "Active"),
            LinkedItem(ref: own, label: "5104: Move a saved item back to the cart", title: "Copilot: 5104", symbol: "paperplane.fill",
                       color: .green, status: "Finished, without a pull request", sent: SentToCopilot(from: item.linkRef)),
        ])
        return links
    }

    /// The task you sent it first, then the sessions Show Links links to it, the one that needs you first, that on its pull
    /// request's branch too; each once; and its pull request. A task that ran with the CLI goes on in Terminal; the app's
    /// sessions open in Copilot.
    @Test func opensItsSessionsAndItsPullRequest() throws {
        let item = try task()
        let copilot = copilot()
        let off = Links(defaults: MemoryDefaults(), isDemo: false)
        #expect(WorkItemShortcuts.of(item, links: off, copilot: copilot).sessions.isEmpty)

        let worktree = try folder()
        defer { try? FileManager.default.removeItem(at: worktree) }
        copilot.settings.copilotRuns = [run(in: worktree)]
        // Without Show Links, the task you sent it, and no pull request.
        var shortcuts = WorkItemShortcuts.of(item, links: off, copilot: copilot)
        #expect(shortcuts.sessions.map(\.id) == [sent])
        #expect(shortcuts.pullRequests.isEmpty)

        let links = try links(for: item)
        shortcuts = WorkItemShortcuts.of(item, links: links, copilot: copilot)
        #expect(shortcuts.sessions.map(\.id) == [sent, inApp, onBranch])
        #expect(shortcuts.sessions.map { SessionOpening.way(of: $0) } == [.terminal, .copilot, .copilot])
        #expect(shortcuts.sessions.allSatisfy { !$0.isUnavailable })
        #expect(WorkItemShortcuts.title(of: shortcuts.sessions[0], links: links, copilot: copilot)
            == "‘Work Item 5104’ — Finished, without a pull request (in Terminal)")
        #expect(WorkItemShortcuts.title(of: shortcuts.sessions[1], links: links, copilot: copilot)
            == "‘Save items for later’ — Waiting for your answer")
        #expect(shortcuts.pullRequests.map(\.ref) == [.pullRequest(organization: DemoData.organization, number: 4091)])
        #expect(WorkItemShortcuts.title(of: shortcuts.pullRequests[0]) == "!4091 · Round half up in the coupon service — Active")

        // With Send Work to Copilot off, the task you sent isn't offered, though Show Links still names it.
        copilot.settings.copilotEnabled = false
        #expect(WorkItemShortcuts.of(item, links: links, copilot: copilot).sessions.map(\.id) == [inApp, onBranch])

        // A link you hid isn't offered.
        links.unlink(item.linkRef, try #require(ItemRef.session(inApp)))
        #expect(WorkItemShortcuts.of(item, links: links, copilot: copilot).sessions.map(\.id) == [onBranch])
    }

    /// A task BriefBar ran with the CLI whose worktree is gone has nowhere to go on in Terminal: it isn't offered, neither the
    /// work item's own nor one on its pull request that Show Links links to it, and not as one of the Copilot app's sessions
    /// either, as a pull request's tasks aren't.
    @Test func leavesOutTasksWhoseWorktreesAreGone() throws {
        let item = try task()
        let copilot = copilot()
        let worktrees = try folder()
        defer { try? FileManager.default.removeItem(at: worktrees) }
        let ownWorktree = worktrees.appendingPathComponent("wi-5104", isDirectory: true)
        let pullRequestWorktree = worktrees.appendingPathComponent("pr-4091", isDirectory: true)
        for worktree in [ownWorktree, pullRequestWorktree] {
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        }
        // The session on the pull request's branch is BriefBar's task on it.
        copilot.settings.copilotRuns = [run(in: ownWorktree), run(onBranch, onPullRequest: 4091, in: pullRequestWorktree)]
        let links = try links(for: item)
        let shortcuts = WorkItemShortcuts.of(item, links: links, copilot: copilot)
        #expect(shortcuts.sessions.map(\.id) == [sent, inApp, onBranch])
        #expect(shortcuts.sessions.map { SessionOpening.way(of: $0) } == [.terminal, .copilot, .terminal])

        try FileManager.default.removeItem(at: ownWorktree)
        try FileManager.default.removeItem(at: pullRequestWorktree)
        #expect(WorkItemShortcuts.of(item, links: links, copilot: copilot).sessions.map(\.id) == [inApp])
        #expect(WorkItemShortcuts.of(item, links: Links(defaults: MemoryDefaults(), isDemo: false), copilot: copilot).sessions.isEmpty)
    }

    /// A pull request shows over the work item's details where they take it; else in BriefBar's window, for one that shows
    /// there; else where it lives.
    @Test func showsAPullRequestWhereItCan() {
        var shown: [String] = []
        let pullRequest = LinkedItem(
            ref: .pullRequest(organization: DemoData.organization, number: 4091), label: "!4091", title: "Round half up",
            symbol: "arrow.triangle.pull", color: .blue, open: { shown.append("Azure DevOps") },
            show: { shown.append("window"); return false }
        )
        WorkItemShortcuts.show(pullRequest, navigation: ItemNavigation { _ in shown.append("details"); return true })
        #expect(shown == ["details"])
        shown = []
        WorkItemShortcuts.show(pullRequest, navigation: ItemNavigation { _ in shown.append("details"); return false })
        #expect(shown == ["details", "window", "Azure DevOps"])
        shown = []
        WorkItemShortcuts.show(pullRequest, navigation: nil)
        #expect(shown == ["window", "Azure DevOps"])
    }
}
