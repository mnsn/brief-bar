import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// Try Again on a comment's fix, through the composer it opens, as a thread's Fix draws it: it sends that fix again with
/// Push and Reply as the fix had it, whether BriefBar still knows the fix's words or not, and leaves Push and Reply for the
/// next fix as you last left it.
@MainActor
@Suite(.serialized, .opensNothing) struct CommentTryAgainTests {
    private let task = "11111111-1111-4111-8111-111111111111"

    /// What the composer had BriefBar launch.
    private final class Launched {
        var requests: [CopilotLauncher.Request] = []
    }

    /// A comment's fix on one of your pull requests, sent to a task of BriefBar's, which failed: as Try Again finds it.
    private struct Setup {
        var item: PRSnapshot
        var thread: ReviewThread
        var settings: AppSettings
        var copilot: CopilotTasksStore
        var launched: Launched
        var details: DetailsDrafts
        var composer: (CopilotDrafts) -> AnyView
        var folder: URL
    }

    private func setUp() async throws -> Setup {
        let prs = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await prs.loadOnce()
        let item = try #require(prs.items.first {
            prs.record(for: $0.key)?.role == .author && prs.record(for: $0.key)?.details?.threads.isEmpty == false
        })
        let record = try #require(prs.record(for: item.key))
        let thread = try #require(record.details?.threads.first)
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        copilot.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        copilot.appHomeForTests = URL(fileURLWithPath: "/nonexistent/copilot-app", isDirectory: true)
        let launched = Launched()
        copilot.launchForTests = { request, _, _ in
            launched.requests.append(request)
            throw CancellationError()
        }
        // The task the fix went to, which failed: its worktree is there, for the CLI to fork it again.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CommentTryAgainTests-\(UUID().uuidString)", isDirectory: true)
        let worktree = folder.appendingPathComponent("copilot-worktrees/\(record.pullRequest.repositoryName)/pr-\(item.key.number)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".git"), withIntermediateDirectories: true)
        settings.copilotRuns = [CopilotRun(
            id: task, workItem: nil, onPullRequest: PullRequestTasks.task(for: record).reference, action: .fixComments,
            options: CopilotModel.standard, repository: folder, worktree: worktree, startedAt: Date().addingTimeInterval(-600),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .failed
        )]
        let sessions = PullRequestSessions(copilot: copilot, links: Links(defaults: MemoryDefaults(), isDemo: false))
        sessions.record = { prs.record(for: $0) }
        await sessions.prepare([item])
        try #require(sessions.session(for: item.key)?.candidates.contains { $0.id == task } == true)
        let questions = CopilotQuestions(copilot: copilot)
        let code = PullRequestCodeStore(demo: true, client: ADOClient(tokens: NoTokens()))
        let details = DetailsDrafts()
        let composer = { (drafts: CopilotDrafts) in
            AnyView(
                CommentComposer(ask: .fix, thread: thread, item: item, worked: nil, drafts: drafts) { _ in }
                    .environmentObject(prs)
                    .environmentObject(copilot)
                    .environmentObject(sessions)
                    .environmentObject(questions)
                    .environmentObject(code)
                    .environmentObject(details)
                    .frame(width: 440)
            )
        }
        return Setup(
            item: item, thread: thread, settings: settings, copilot: copilot, launched: launched, details: details, composer: composer,
            folder: folder
        )
    }

    /// With the words the fix went with, Try Again sends them again at once, pushing and replying as that fix was to, as
    /// its words say (`CommentComposer.restore`), though Push and Reply is off for the next fix.
    @Test func tryAgainSendsAFixAgainWithItsWordsAsItWent() async throws {
        let setup = try await setUp()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        setup.settings.copilotFixesPushAndReply = false
        let part = PullRequestPart.thread(setup.thread.id)
        let words = CopilotTasksStore.FixWords(text: "Cap it at 30 seconds", takenAt: Date().addingTimeInterval(-600), ships: true)
        setup.copilot.fixWords[CopilotTasksStore.PartKey(pullRequest: setup.item.key, part: part)] = words
        let drafts = CopilotDrafts()
        drafts.retry(CopilotComposing(part: part, ask: .fix), words: words, ships: true, to: .fork(task))
        let window = window(showing: setup.composer(drafts))
        defer { window.contentView = nil }

        try await settle("the send", in: window) { !setup.launched.requests.isEmpty }
        let request = try #require(setup.launched.requests.first)
        #expect(Self.action(of: request) == .pushAndReply)
        #expect(request.fixing)
        #expect(request.forking?.id == task)
        #expect(request.prompt.contains("Cap it at 30 seconds"))
        #expect(!setup.settings.copilotFixesPushAndReply)
    }

    /// Without the words, as once BriefBar restarted, or on a thread Fix All took on, Try Again opens the composer going
    /// where the fix went, for you to send, with Push and Reply as that fix had it, which its line knows: Return sends it
    /// so, whichever way you last left Push and Reply, which stays so for the next fix.
    @Test(arguments: [false, true])
    func tryAgainWithoutTheWordsPushesAndRepliesAsTheFixWent(shipped: Bool) async throws {
        let setup = try await setUp()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        setup.settings.copilotFixesPushAndReply = !shipped
        let drafts = CopilotDrafts()
        let composer = CopilotComposing(part: .thread(setup.thread.id), ask: .fix)
        drafts.retry(composer, words: nil, ships: shipped, to: .fork(task))
        let window = window(showing: setup.composer(drafts))
        defer { window.contentView = nil }
        let host = try #require(window.contentView)
        try await settle("the composer to open as Try Again asked", in: window) { drafts.retries[composer] == nil }
        // It waits for you.
        #expect(setup.launched.requests.isEmpty)

        // Return sends once SwiftUI drew what Try Again's plan chose, and took what you typed: it would send as the composer
        // was before then, a moment no one could press it in.
        try type("Keep the API as it is", in: host)
        try await settle("the composer to keep what you typed", in: window) {
            setup.details.words(in: composer, of: setup.item.key) == "Keep the API as it is"
        }
        try returnKey(in: host)
        try await settle("the send after Return", in: window) { !setup.launched.requests.isEmpty }
        let request = try #require(setup.launched.requests.first)
        #expect(Self.action(of: request) == (shipped ? .pushAndReply : .fixComments))
        #expect(request.fixing == shipped)
        #expect(request.forking?.id == task)
        #expect(request.prompt.contains("Keep the API as it is"))
        #expect(setup.settings.copilotFixesPushAndReply == !shipped)
    }

    private static func action(of request: CopilotLauncher.Request) -> PullRequestAction? {
        if case .pullRequest(_, let action) = request.subject { return action }
        return nil
    }

    // MARK: The window

    /// A window that takes keys, though it's off screen, and takes none that no view takes: AppKit would beep for each.
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override func noResponder(for eventSelector: Selector) {}
    }

    /// A window off screen that shows `view`.
    private func window(showing view: AnyView) -> NSWindow {
        let window = KeyWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 440, height: 400), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    /// Types at the end of the field the window shows, as you would: in it, once it's being edited.
    private func type(_ text: String, in view: NSView) throws {
        let editor = try self.editor(in: view)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// Presses Return in the field, which sends what it says, as you would.
    private func returnKey(in view: NSView) throws {
        try editor(in: view).doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    /// The field's editor, once it's being edited.
    private func editor(in view: NSView) throws -> NSTextView {
        if let editing = textView(in: view) { return editing }
        let field = try #require(textField(in: view))
        #expect(field.window?.makeFirstResponder(field) == true)
        return try #require(field.currentEditor() as? NSTextView)
    }

    /// The field the window shows, as AppKit has it while it isn't being edited.
    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(textField(in:)).first
    }

    /// The field you type in, as AppKit has it while it's being edited.
    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap(textView(in:)).first
    }

    /// Lets SwiftUI lay the window out and run what its views start, until `done`, for as long as a busy machine could need
    /// (`waitLimit`), awaiting between looks, so that the main run loop does that meanwhile. An off-screen window may wait
    /// to apply what changed while other tests' windows keep the main thread busy, so it's laid out and drawn each time.
    private func settle(_ what: String, in window: NSWindow, until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while true {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if done() { return }
            guard ContinuousClock.now < deadline else { throw Timeout(description: "Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Timeout: Error, CustomStringConvertible {
        var description: String
    }

    private struct NoTokens: AccessTokenProvider {
        struct Unused: Error {}
        func token(tenant: String?) async throws -> AccessToken { throw Unused() }
        func invalidate(tenant: String?) async {}
    }
}
