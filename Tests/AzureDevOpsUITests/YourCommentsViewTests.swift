import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// Your comments in a pull request's details as you edit or delete them: they stay in sight while they're open, however a
/// long thread folds and whatever comes meanwhile; what was open on one closes once it leaves its thread, and what went wrong
/// with it shows on the thread then; and what of yours takes the keyboard's focus back once each closes. With the demo's
/// made-up pull requests, read as a list that reads Azure DevOps would, and the comments drawn in a window off screen.
@MainActor
@Suite(.opensNothing) struct YourCommentsViewTests {
    /// Which composer the details have open, as the test opens them.
    final class Composing: ObservableObject {
        @Published var open: CopilotComposing?
    }

    /// The comments, drawn as the details draw them, as the list has them now, with the composer open that `composing` says.
    private struct Comments: View {
        @ObservedObject var store: PRStore
        @ObservedObject var composing: Composing
        let make: (PRStore, Binding<CopilotComposing?>) -> AnyView

        var body: some View { make(store, $composing.open) }
    }

    /// The demo's pull request that Sam replied on.
    private let key = PRKey(DemoData.organization, 4102)
    private let priya = Person(id: "3b0a7c52-0000-4000-8000-00000000c0de", name: "Priya Shah")

    /// A long thread on it, 70, on the pull request rather than code: Sam's, yours, Sam's, Priya's and Sam's, so that yours,
    /// the second, folds between the first and the latest.
    private func longThread(sam: Person, now: Date) -> ReviewThread {
        func comment(_ id: Int, _ author: Person, _ text: String) -> ReviewComment {
            ReviewComment(id: id, author: author, text: text, publishedAt: now.addingTimeInterval(Double(id - 10) * 60))
        }
        return ReviewThread(id: 70, comments: [
            comment(1, sam, "Should the cap be configurable?"),
            comment(2, DemoData.me, "It reads RetryOptions.MaxDelay, 30 seconds by default."),
            comment(3, sam, "And per client?"),
            comment(4, priya, "Per client would be easier to test."),
            comment(5, sam, "Then per client, please."),
        ])
    }

    /// A list that reads Azure DevOps, with the demo's pull requests and the long thread read, and what changes them.
    private func live() throws -> (store: PRStore, changes: ThreadChanges, thread: ReviewThread) {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = true
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
        settings.useSeenState(DemoData.seenState(now: store.now))
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        let sam = try #require(snapshot.records[index].details?.threads.first?.comments.first { $0.author != DemoData.me }?.author)
        let thread = longThread(sam: sam, now: store.now)
        snapshot.records[index].details?.threads.append(thread)
        store.receive(snapshot)
        // Nothing's read again: there's no Azure DevOps.
        store.readAfterChange = { _, _ in nil }
        return (store, ThreadChanges(store: store, settings: settings), thread)
    }

    /// The pull request's comments, as its details show them, with what a composer needs.
    private func comments(_ store: PRStore, _ changes: ThreadChanges, composing: Composing) -> AnyView {
        let copilot = CopilotTasksStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .live, notifier: nil)
        let sessions = PullRequestSessions(copilot: copilot, links: Links(defaults: MemoryDefaults(), isDemo: false))
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let key = key
        return AnyView(
            Comments(store: store, composing: composing) { store, open in
                guard let record = store.record(for: key), let item = store.items.first(where: { $0.key == key }) else {
                    return AnyView(EmptyView())
                }
                return AnyView(
                    PullRequestCommentsSection(
                        item: item, panel: PullRequestPanel(item, record: record), pullRequest: record.pullRequest, me: record.me,
                        place: nil, highlighted: nil, composing: open, drafts: CopilotDrafts()
                    )
                )
            }
            .environmentObject(store)
            .environmentObject(store.settings)
            .environmentObject(services)
            .environmentObject(PullRequestCodeStore(demo: true, client: store.client))
            .environmentObject(DetailsDrafts())
            .environmentObject(copilot)
            .environmentObject(sessions)
            .environmentObject(CopilotQuestions(copilot: copilot))
            .environmentObject(changes)
            .environment(\.shownSection, .azureDevOpsPullRequests)
            .environment(\.shownWindow, "test")
            .frame(width: 440)
        )
    }

    private func window(showing view: AnyView) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 440, height: 1_600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        return (window, host)
    }

    /// Lets SwiftUI lay the window out and run what its views start, until `done`, or for a moment.
    private func settle(until done: () -> Bool = { false }, at most: Int = 300) async throws {
        for _ in 0..<most where !done() {
            Self.runLoop()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The main run loop, for a moment, where SwiftUI lays windows out and starts their views' tasks.
    private static func runLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    /// The long thread, as the pull request's details have it.
    private func panelThread(_ store: PRStore) throws -> PullRequestPanel.Thread {
        let record = try #require(store.record(for: key))
        let item = try #require(store.items.first { $0.key == key })
        let threads = PullRequestPanel(item, record: record).threads
        return try #require((threads.waitingOnYou + threads.open).first { $0.id == 70 })
    }

    /// What each field you write in says: in the comments, only your edit's, or a reply's, draws one.
    private func fields(in view: NSView) -> [String] {
        if let field = view as? NSTextView, field.isEditable { return [field.string] }
        return view.subviews.flatMap(fields(in:))
    }

    // MARK: In sight

    /// Your comment, between the first and the latest of a long thread, which fold, shows as you edit it, its field in its
    /// place, though you didn't unfold them, as from VoiceOver's actions on a thread folded since; and stays, though a
    /// reply that came meanwhile makes it fold again. Once it leaves the thread, as deleted elsewhere, what was open on it
    /// closes.
    @Test func yourCommentStaysInSightWhileYouEditIt() async throws {
        _ = NSApplication.shared
        let (store, changes, thread) = try live()
        let mine = thread.comments[1]
        let composing = Composing()
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle(at: 30)
        #expect(fields(in: host).isEmpty)
        #expect(try panelThread(store).foldedComments == 3)

        composing.open = .edit(mine.id, in: thread.id)
        try await settle { !fields(in: host).isEmpty }
        #expect(fields(in: host) == [mine.markdown])

        // Sam replies meanwhile.
        let sam = thread.comments[0].author
        store.changed(key, by: ThreadChange(thread: thread.id, comments: [
            ReviewComment(id: 6, author: sam, text: "Thanks!", publishedAt: store.now.addingTimeInterval(60)),
        ]))
        try await settle(at: 30)
        #expect(try panelThread(store).comments.count == 6)
        #expect(fields(in: host) == [mine.markdown])
        #expect(composing.open == .edit(mine.id, in: thread.id))

        // Deleted elsewhere: the list reads the thread without it.
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        var without = thread
        without.comments.removeAll { $0.id == mine.id }
        snapshot.records[index].details?.threads.append(without)
        store.receive(snapshot)
        try await settle { composing.open == nil }
        #expect(composing.open == nil)
        #expect(fields(in: host).isEmpty)
        window.contentView = nil
    }

    /// How many comments fold: none while a comment of yours there is open to edit or delete, wherever it is, nor once you
    /// unfolded them; as many as ever otherwise, your reply open on the thread or your comment open on another.
    @Test func noCommentFoldsWhileYoursIsOpen() throws {
        let thread = try panelThread(try live().store)
        #expect(ThreadCard.folded(thread, isUnfolded: false, composing: nil) == 3)
        #expect(ThreadCard.folded(thread, isUnfolded: false, composing: .edit(2, in: 70)) == 0)
        #expect(ThreadCard.folded(thread, isUnfolded: false, composing: .deleting(2, in: 70)) == 0)
        #expect(ThreadCard.folded(thread, isUnfolded: false, composing: .edit(5, in: 70)) == 0)
        #expect(ThreadCard.folded(thread, isUnfolded: true, composing: nil) == 0)
        #expect(ThreadCard.folded(thread, isUnfolded: false, composing: .reply(to: 70)) == 3)
        #expect(ThreadCard.folded(thread, isUnfolded: false, composing: .edit(2, in: 71)) == 3)
        #expect(ThreadCard.folded(thread, isUnfolded: false, composing: .fixAll) == 3)
    }

    /// The comment a composer of yours edits, or confirms you delete, on its thread; none for your reply, Copilot's, a tag's
    /// or another thread's.
    @Test func aComposerSaysWhichCommentOfYoursItsOpenOn() {
        #expect(CopilotComposing.edit(2, in: 70).comment(on: 70) == 2)
        #expect(CopilotComposing.deleting(12, in: 70).comment(on: 70) == 12)
        #expect(CopilotComposing.edit(2, in: 70).comment(on: 71) == nil)
        #expect(CopilotComposing.reply(to: 70).comment(on: 70) == nil)
        #expect(CopilotComposing(part: .thread(70), ask: .explain).comment(on: 70) == nil)
        #expect(CopilotComposing.tags.comment(on: 70) == nil)
        #expect(CopilotComposing.fixAll.comment(on: 70) == nil)
        #expect(CopilotComposing.reply(to: 70).isReply)
        #expect(!CopilotComposing.edit(2, in: 70).isReply && !CopilotComposing.deleting(2, in: 70).isReply)
        #expect(CopilotComposing.edit(2, in: 70).isYours(on: 70) && CopilotComposing.deleting(2, in: 70).isYours(on: 70))
    }

    // MARK: What went wrong

    /// What went wrong with your edit shows in your edit while it's open on a comment the thread has; on the thread
    /// otherwise, as once the comment left it, or the edit closed. A reply's shows in your reply; a status's and a
    /// deletion's always on the thread.
    @Test func whatWentWrongWithAnEditShowsWhereItCan() throws {
        let thread = try panelThread(try live().store)
        var gone = thread
        gone.thread.comments.removeAll { $0.id == 2 }
        func showsInEdit(_ sending: ThreadChanges.Sending, _ composing: CopilotComposing?, _ thread: PullRequestPanel.Thread,
                         canChange: Bool = true) -> Bool {
            ThreadReplyArea.showsInItsComposer(sending, composing: composing, thread: thread, canChange: canChange)
        }
        #expect(showsInEdit(.edit(comment: 2), .edit(2, in: 70), thread))
        #expect(!showsInEdit(.edit(comment: 2), .edit(2, in: 70), gone))
        #expect(!showsInEdit(.edit(comment: 2), nil, thread))
        #expect(!showsInEdit(.edit(comment: 2), .edit(4, in: 70), thread))
        #expect(!showsInEdit(.edit(comment: 2), .edit(2, in: 70), thread, canChange: false))
        #expect(showsInEdit(.reply(then: nil), .reply(to: 70), thread))
        #expect(!showsInEdit(.reply(then: nil), .edit(2, in: 70), thread))
        #expect(!showsInEdit(.delete(comment: 2), .deleting(2, in: 70), thread))
        #expect(!showsInEdit(.status(.fixed), .reply(to: 70), thread))
    }

    // MARK: The keyboard's focus

    /// Your edit of a comment, saved or canceled, and what confirms you delete it, as you keep the comment, give the
    /// keyboard's focus back to the comment's ⋯; once a comment you deleted is done with, Reply takes it back. Opening a
    /// composer forgets what closed before; and another thread's, your reply's, or Copilot's composers aren't the comment's.
    @Test func theKeyboardsFocusGoesBackToWhatOpenedYourEdit() {
        var refocus = ThreadRefocus()
        refocus.closed(.edit(2, in: 70), on: 70)
        #expect(refocus == ThreadRefocus(comment: 2))
        refocus.opened()
        #expect(refocus == ThreadRefocus())
        refocus.closed(.deleting(4, in: 70), on: 70)
        #expect(refocus == ThreadRefocus(comment: 4))

        refocus.deleting(4)
        #expect(refocus == ThreadRefocus(deleting: 4))
        refocus.deleted(4)
        #expect(refocus == ThreadRefocus(reply: true))
        // Another comment's deletion done with isn't this one's.
        var other = ThreadRefocus()
        other.deleting(4)
        other.deleted(5)
        #expect(other == ThreadRefocus(deleting: 4))

        var unchanged = ThreadRefocus(reply: true)
        unchanged.closed(.edit(2, in: 71), on: 70)
        unchanged.closed(.reply(to: 70), on: 70)
        unchanged.closed(CopilotComposing(part: .thread(70), ask: .explain), on: 70)
        #expect(unchanged == ThreadRefocus(reply: true))
    }

    /// A composer that opened while your comment was being deleted has the keyboard's focus, though it closed again before
    /// the deletion was done with, as another thread's reply you opened and closed meanwhile: Reply doesn't take it back.
    @Test func aComposerOpenedWhileYourCommentIsDeletedKeepsTheFocus() {
        var refocus = ThreadRefocus()
        refocus.deleting(4)
        // Another thread's reply opens, then closes: nothing's open as the deletion is done with.
        refocus.opened()
        refocus.deleted(4)
        #expect(refocus == ThreadRefocus())
    }
}
