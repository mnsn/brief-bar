import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// The Send to Copilot window, as Edit the Whole Prompt… opens it for a comment's fix sent to push and reply: its Send
/// checks the pull request, as the list reads it then, against its prompt (`CopilotTasksStore.windowProblem`).
@MainActor
@Suite(.serialized, .opensNothing) struct CopilotComposerWindowTests {
    private let task = "11111111-1111-4111-8111-111111111111"

    /// What the window had BriefBar launch, the branch the list reads the pull request merging into, and whether the window
    /// closed.
    private final class Seen {
        var requests: [CopilotLauncher.Request] = []
        var listed = "release/2"
        var closed = false
    }

    /// Once the list reads another branch the pull request merges into than the one its prompt names, Send sends nothing,
    /// and the window stays open to say why; once it merges into that one again, Send sends it.
    @Test func sendSendsAFixThatShipsOnlyIntoTheBranchItsPromptNames() async throws {
        let prs = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await prs.loadOnce()
        let record = try #require(prs.items.lazy.compactMap { prs.record(for: $0.key) }.first { $0.role == .author })
        let pullRequest = PullRequestTasks.task(for: record)
        try #require(pullRequest.targetBranch != "release/2")
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        copilot.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        copilot.appHomeForTests = URL(fileURLWithPath: "/nonexistent/copilot-app", isDirectory: true)
        let seen = Seen()
        copilot.launchForTests = { request, _, _ in
            seen.requests.append(request)
            throw CancellationError()
        }
        copilot.currentTarget = { _ in seen.listed }
        // The task the window forks, with the CLI, as a comment's fix sent to push and reply goes wherever a fix goes.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CopilotComposerWindowTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let worktree = folder.appendingPathComponent("copilot-worktrees/\(record.pullRequest.repositoryName)/pr-\(pullRequest.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let run = CopilotRun(
            id: task, workItem: nil, onPullRequest: pullRequest.reference, action: .fixComments, options: CopilotModel.standard,
            repository: folder, worktree: worktree, startedAt: Date().addingTimeInterval(-600),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished
        )
        settings.copilotRuns = [run]
        let choice = SessionChoice(kind: .task(run), name: "Fix Comments", reasons: [.earlierTask])
        let view = CopilotComposerView(
            subject: .pullRequest(pullRequest, .pushAndReply), options: CopilotModel.standard, template: "",
            prompt: "Fix the comment, then push and reply", sessionPrompt: "Fix the comment, then push and reply",
            start: .session(choice, forking: true), parts: [.thread(11)], fixes: true, close: { seen.closed = true }
        )
        let host = NSHostingView(rootView: AnyView(view.environmentObject(copilot).environmentObject(settings).frame(width: 560)))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 560, height: 900), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        let send = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))

        #expect(try await press(send, in: host, window: window))
        #expect(copilot.pending.isEmpty)
        #expect(seen.requests.isEmpty)
        #expect(!seen.closed)

        seen.listed = pullRequest.targetBranch
        #expect(try await press(send, in: host, window: window))
        #expect(seen.closed)
        try await settle(window) { !seen.requests.isEmpty }
        let request = try #require(seen.requests.first)
        #expect(request.forking?.id == task)
        #expect(request.fixing)
    }

    /// Presses a key in the window once SwiftUI takes it, as the shortcut of a button it has drawn enabled, for as long as a
    /// busy machine could need (`waitLimit`): whether it took it.
    private func press(_ key: NSEvent, in host: NSView, window: NSWindow) async throws -> Bool {
        var taken = false
        try await settle(window) {
            taken = host.performKeyEquivalent(with: key)
            return taken
        }
        return taken
    }

    /// Lets SwiftUI lay the window out and run what its views start, until `done`, for as long as a busy machine could need
    /// (`waitLimit`): an off-screen window may wait to apply what changed while other tests' windows keep the main thread
    /// busy, so it's laid out and drawn each time. What didn't come, the test's expectations say.
    private func settle(_ window: NSWindow, until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while true {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if done() || ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
