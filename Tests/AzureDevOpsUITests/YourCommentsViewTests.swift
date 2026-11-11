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
/// with it shows on the thread then; what of yours takes the keyboard's focus back once each closes; what Esc and ⌘Return
/// do in your edit; what your edit says, does and lets you do once its comment changed since you began, and what VoiceOver
/// hears of it; and its spell checking. With the demo's made-up pull requests, read as a list that reads Azure DevOps
/// would, a stand-in for Azure DevOps that takes nothing, and the comments drawn in a window off screen.
///
/// One at a time: each draws a pull request's comments, which on CI's busy runner keeps the main actor busy long enough
/// that, all at once, they kept the other tests on it waiting past their time limits.
@MainActor
@Suite(.serialized, .opensNothing) struct YourCommentsViewTests {
    /// Which composer the details have open, as the test opens them; and what your comment on the long thread said as
    /// SwiftUI last drew the comments, which it does as the main run loop gets to the window, not as the comment changes.
    final class Composing: ObservableObject {
        @Published var open: CopilotComposing?
        /// Not published: drawing sets it.
        var drawn: String?
    }

    /// The comments, drawn as the details draw them, as the list has them now, with the composer open that `composing` says.
    private struct Comments: View {
        @ObservedObject var store: PRStore
        @ObservedObject var composing: Composing
        let make: (PRStore, Binding<CopilotComposing?>) -> AnyView

        var body: some View { make(store, $composing.open) }
    }

    /// What the stand-in for Azure DevOps was sent: it takes nothing, as Azure DevOps refusing it would; and what VoiceOver
    /// heard of your edit's comment changing (`ThreadChanges.speak`).
    final class Sent {
        var writes: [ADOWrite] = []
        /// How it refuses each: no permission, unless a test says otherwise.
        var fails = ADOError.forbidden
        var spoken: [String] = []

        /// What each edit sent said.
        var edits: [String] {
            writes.compactMap { if case .editComment(_, _, let markdown) = $0 { markdown } else { nil } }
        }
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

    /// A list that reads Azure DevOps, with the demo's pull requests and the long thread read, and what changes them, which
    /// sends a stand-in what it would send Azure DevOps.
    private func live() throws -> (store: PRStore, changes: ThreadChanges, thread: ReviewThread, sent: Sent) {
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
        let changes = ThreadChanges(store: store, settings: settings)
        let sent = Sent()
        changes.send = { write, _ in
            sent.writes.append(write)
            throw sent.fails
        }
        changes.speak = { sent.spoken.append($0) }
        return (store, changes, thread, sent)
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
                composing.drawn = record.details?.threads.first { $0.id == 70 }?.comments.first { $0.id == 2 }?.markdown
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

    /// Awaits until `done`, for as long as a busy machine could need (`waitLimit`), while SwiftUI lays the window out and
    /// runs what its views start, on the main run loop Swift runs meanwhile: never running that run loop itself, which would
    /// hold the main actor from other tests. What didn't come, the test's expectations say.
    private func settle(until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !done(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Awaits a moment, `moments` times 20 ms, for what would come by then, as when nothing should.
    private func settle(at moments: Int) async throws {
        try await Task.sleep(for: .milliseconds(20 * moments))
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
        textViews(in: view).map(\.string)
    }

    /// The fields you write in: in the comments, only your edit's, or a reply's.
    private func textViews(in view: NSView) -> [NSTextView] {
        if let field = view as? NSTextView, field.isEditable { return [field] }
        return view.subviews.flatMap(textViews(in:))
    }

    /// What's behind each field to check its spelling.
    private func probes(in view: NSView) -> [SpellCheckingProbe.ProbeView] {
        if let probe = view as? SpellCheckingProbe.ProbeView { return [probe] }
        return view.subviews.flatMap(probes(in:))
    }

    /// A key pressed in a window.
    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    /// Presses a key in a window once SwiftUI takes it, as a button's shortcut, which it takes only once it has drawn the
    /// button enabled, as after a change that went, for as long as a busy machine could need (`waitLimit`): whether it took
    /// it. A button drawn before a change began takes it too, as the main run loop may not have got to the window since, and
    /// acts as things are now: Save, with your edit on its way, only beeps. So a test presses it again once the change has
    /// landed.
    private func press(_ key: NSEvent, in host: NSView) async throws -> Bool {
        var taken = false
        try await settle {
            taken = host.performKeyEquivalent(with: key)
            return taken
        }
        return taken
    }

    /// Writes at the end of a field, as you type there.
    private func type(_ text: String, in field: NSTextView) {
        field.window?.makeFirstResponder(field)
        field.insertText(text, replacementRange: NSRange(location: (field.string as NSString).length, length: 0))
    }

    /// Takes what's at the end of a field out, as you delete it there.
    private func delete(_ text: String, in field: NSTextView) {
        field.window?.makeFirstResponder(field)
        let length = (field.string as NSString).length, count = (text as NSString).length
        field.insertText("", replacementRange: NSRange(location: length - count, length: count))
    }

    /// The pull request read again, with the long thread's comment of yours saying something else, as edited elsewhere.
    private func receive(_ store: PRStore, yours text: String, in thread: ReviewThread) throws {
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        var changed = thread
        changed.comments[1].text = text
        changed.comments[1].markdown = text
        snapshot.records[index].details?.threads.append(changed)
        store.receive(snapshot)
    }

    /// Which of what corrects, replaces or substitutes text by itself, or checks its grammar, a field has on.
    private func corrections(of field: NSTextView) -> [String] {
        [("autocorrection", field.isAutomaticSpellingCorrectionEnabled), ("text replacement", field.isAutomaticTextReplacementEnabled),
         ("smart quotes", field.isAutomaticQuoteSubstitutionEnabled), ("smart dashes", field.isAutomaticDashSubstitutionEnabled),
         ("grammar", field.isGrammarCheckingEnabled)].filter(\.1).map(\.0)
    }

    // MARK: In sight

    /// Your comment, between the first and the latest of a long thread, which fold, shows as you edit it, its field in its
    /// place, though you didn't unfold them, as from VoiceOver's actions on a thread folded since; and stays, though a
    /// reply that came meanwhile makes it fold again. Once it leaves the thread, as deleted elsewhere, what was open on it
    /// closes.
    @Test func yourCommentStaysInSightWhileYouEditIt() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, _) = try live()
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

    // MARK: The keyboard

    /// Esc closes your edit, as its ✕ does, and keeps what you wrote, as Reply's keeps yours, until you save it or cancel:
    /// opened again, it has it. Only Cancel forgets it.
    @Test func escClosesYourEditAndKeepsWhatYouWrote() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, sent) = try live()
        let mine = thread.comments[1]
        let draft = ThreadChanges.CommentKey(thread: ThreadChanges.Key(pullRequest: key, thread: thread.id), comment: mine.id)
        let composing = Composing()
        composing.open = .edit(mine.id, in: thread.id)
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle { !textViews(in: host).isEmpty }
        let written = mine.markdown + " Per client too."
        type(" Per client too.", in: try #require(textViews(in: host).first))
        try await settle { changes.edit(draft) != nil }
        #expect(changes.edit(draft) == written)

        #expect(try await press(try key("\u{1b}", code: 53, in: window), in: host))
        try await settle { composing.open == nil && fields(in: host).isEmpty }
        #expect(composing.open == nil)
        #expect(fields(in: host).isEmpty)
        #expect(changes.edit(draft) == written)
        #expect(sent.writes.isEmpty)

        composing.open = .edit(mine.id, in: thread.id)
        try await settle { fields(in: host) == [written] }
        #expect(fields(in: host) == [written])
        window.contentView = nil
    }

    /// ⌘Return saves your edit, as Save does; but once your comment changed since you began editing it, in Azure DevOps or
    /// another window, Save is dimmed, and ⌘Return does nothing, which would replace what it says now unseen: your edit stays
    /// open, with what you wrote, and says it changed (`ThreadChanges.changedSince`).
    @Test func commandReturnDoesntReplaceYourCommentChangedSinceYouBegan() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, sent) = try live()
        let mine = thread.comments[1]
        let composing = Composing()
        composing.open = .edit(mine.id, in: thread.id)
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle { !textViews(in: host).isEmpty }
        let written = mine.markdown + " Per client too."
        type(" Per client too.", in: try #require(textViews(in: host).first))
        try await settle { fields(in: host) == [written] }
        let commandReturn = try key("\r", code: 36, .command, in: window)

        // Unchanged since: it goes, as the stand-in refuses it, and Save is back once it has.
        #expect(try await press(commandReturn, in: host))
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: thread.id)
        try await settle { if case .failed? = changes.state(of: threadKey) { true } else { false } }
        #expect(sent.writes.map(\.kind) == [.editComment])

        // Edited elsewhere, as the list reads it: your edit says so, as VoiceOver hears, and ⌘Return does nothing.
        try receive(store, yours: "It reads RetryOptions.MaxDelay, a minute by default.", in: thread)
        try await settle { !sent.spoken.isEmpty }
        #expect(!host.performKeyEquivalent(with: commandReturn))
        try await settle(at: 30)
        #expect(sent.writes.count == 1)
        #expect(composing.open == .edit(mine.id, in: thread.id))
        #expect(fields(in: host) == [written])
        window.contentView = nil
    }

    // MARK: Changed since you began

    /// Your edit's notice shows all of what your comment says now, however long, since Save Anyway replaces all of it: each
    /// line it adds makes it as much taller as it makes the comment itself.
    @Test func theNoticeShowsAllOfWhatYourCommentSaysNow() {
        _ = NSApplication.shared
        func height(_ view: some View) -> CGFloat {
            NSHostingView(rootView: view.frame(width: 360)).fittingSize.height
        }
        func comment(steps: Int) -> ReviewComment {
            let text = "Capped it:\n\n" + (1...steps).map { "- Step \($0) of the backoff" }.joined(separator: "\n")
            return ReviewComment(id: 2, author: DemoData.me, text: text, publishedAt: Date())
        }
        func notice(steps: Int) -> CGFloat {
            height(CommentChangedNotice(now: comment(steps: steps), isSending: false, canSave: true, startOver: {}, saveAnyway: {}))
        }
        func body(steps: Int) -> CGFloat {
            height(CommentBody(markdown: comment(steps: steps).markdown, isQuiet: false))
        }
        #expect(body(steps: 9) > body(steps: 4))
        #expect(abs((notice(steps: 9) - notice(steps: 4)) - (body(steps: 9) - body(steps: 4))) < 1)
    }

    /// Once your comment changed since you began, Save is dimmed, and Save Anyway (⌥⌘Return) replaces the version your edit
    /// shows: it goes, in place of it, and, though Azure DevOps refuses it, stays chosen, so Save saves it again; but a later
    /// version, which you haven't seen, it doesn't replace: your edit says so, and Save is dimmed again.
    @Test func saveAnywayReplacesTheVersionYourEditShowsAndOnlyThat() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, sent) = try live()
        let mine = thread.comments[1]
        let composing = Composing()
        composing.open = .edit(mine.id, in: thread.id)
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle { !textViews(in: host).isEmpty }
        let written = mine.markdown + " Per client too."
        type(" Per client too.", in: try #require(textViews(in: host).first))
        try await settle { fields(in: host) == [written] }
        let commandReturn = try key("\r", code: 36, .command, in: window)
        let saveAnyway = try key("\r", code: 36, [.command, .option], in: window)
        #expect(!host.performKeyEquivalent(with: saveAnyway))

        try receive(store, yours: "It reads RetryOptions.MaxDelay, a minute by default.", in: thread)
        try await settle { sent.spoken.count == 1 }
        #expect(sent.spoken == [ThreadChanges.changedSentence + " " + ThreadChanges.changedChoices])
        #expect(!host.performKeyEquivalent(with: commandReturn))
        #expect(sent.writes.isEmpty)

        #expect(try await press(saveAnyway, in: host))
        // Refused: what you chose stays chosen, and the notice gone; Save is back once the refusal has landed.
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: thread.id)
        try await settle { if case .failed? = changes.state(of: threadKey) { true } else { false } }
        #expect(sent.edits == [written])
        #expect(try await press(commandReturn, in: host))
        try await settle { sent.writes.count == 2 }
        try await settle { if case .failed? = changes.state(of: threadKey) { true } else { false } }
        #expect(sent.edits == [written, written])
        #expect(!host.performKeyEquivalent(with: saveAnyway))

        try receive(store, yours: "It reads RetryOptions.MaxDelay, two minutes by default.", in: thread)
        try await settle { sent.spoken.count == 2 }
        #expect(!host.performKeyEquivalent(with: commandReturn))
        try await settle(at: 30)
        #expect(sent.writes.count == 2)
        #expect(composing.open == .edit(mine.id, in: thread.id))
        #expect(fields(in: host) == [written])
        window.contentView = nil
    }

    /// Start Over (⌥⌘R) puts what your comment says now in your edit, in place of what you wrote, which is forgotten: the
    /// notice goes, Save comes back, and your edit begins from it, so that what you write then goes in its place.
    @Test func startOverBeginsAgainFromWhatYourCommentSaysNow() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, sent) = try live()
        let mine = thread.comments[1]
        let draft = ThreadChanges.CommentKey(thread: ThreadChanges.Key(pullRequest: key, thread: thread.id), comment: mine.id)
        let composing = Composing()
        composing.open = .edit(mine.id, in: thread.id)
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle { !textViews(in: host).isEmpty }
        type(" Per client too.", in: try #require(textViews(in: host).first))
        try await settle { fields(in: host) == [mine.markdown + " Per client too."] }
        let elsewhere = "It reads RetryOptions.MaxDelay, a minute by default."
        try receive(store, yours: elsewhere, in: thread)
        try await settle { sent.spoken.count == 1 }

        #expect(try await press(try key("r", code: 15, [.command, .option], in: window), in: host))
        try await settle { fields(in: host) == [elsewhere] }
        #expect(fields(in: host) == [elsewhere])
        #expect(changes.edit(draft) == nil)
        #expect(sent.spoken.last == "Started over from what your comment says now")

        type(" Per client too.", in: try #require(textViews(in: host).first))
        try await settle { fields(in: host) == [elsewhere + " Per client too."] }
        #expect(try await press(try key("\r", code: 36, .command, in: window), in: host))
        try await settle { sent.writes.count == 1 }
        #expect(sent.edits == [elsewhere + " Per client too."])
        window.contentView = nil
    }

    /// Your edit, while you haven't changed it, follows your comment as it changes, in Azure DevOps or another window: it
    /// shows what the comment says now, quietly, with no notice, as saving it would replace nothing. Save stays: it saves
    /// nothing, as the comment says that already, and your edit closes; opened again, it has what the comment says now.
    @Test func anEditYouHaventChangedFollowsYourComment() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, sent) = try live()
        let mine = thread.comments[1]
        let draft = ThreadChanges.CommentKey(thread: ThreadChanges.Key(pullRequest: key, thread: thread.id), comment: mine.id)
        let composing = Composing()
        composing.open = .edit(mine.id, in: thread.id)
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle { fields(in: host) == [mine.markdown] }
        let elsewhere = "It reads RetryOptions.MaxDelay, a minute by default."
        try receive(store, yours: elsewhere, in: thread)
        try await settle { fields(in: host) == [elsewhere] }
        #expect(fields(in: host) == [elsewhere])
        try await settle(at: 30)
        #expect(sent.spoken.isEmpty)
        #expect(changes.edit(draft) == nil)
        #expect(!host.performKeyEquivalent(with: try key("\r", code: 36, [.command, .option], in: window)))

        #expect(try await press(try key("\r", code: 36, .command, in: window), in: host))
        try await settle { composing.open == nil && fields(in: host).isEmpty }
        #expect(composing.open == nil)
        #expect(sent.writes.isEmpty)
        composing.open = .edit(mine.id, in: thread.id)
        try await settle { fields(in: host) == [elsewhere] }
        #expect(fields(in: host) == [elsewhere])
        window.contentView = nil
    }

    /// Your edit, changed once your comment changed since you began, then changed back to what you began with, follows the
    /// comment: the notice goes, quietly, and your edit shows what the comment says now, which Save saves nothing over.
    @Test func anEditYouChangeBackFollowsYourComment() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, sent) = try live()
        let mine = thread.comments[1]
        let composing = Composing()
        composing.open = .edit(mine.id, in: thread.id)
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle { !textViews(in: host).isEmpty }
        type(" Per client too.", in: try #require(textViews(in: host).first))
        try await settle { fields(in: host) == [mine.markdown + " Per client too."] }
        let elsewhere = "It reads RetryOptions.MaxDelay, a minute by default."
        try receive(store, yours: elsewhere, in: thread)
        try await settle { sent.spoken.count == 1 }
        #expect(fields(in: host) == [mine.markdown + " Per client too."])

        delete(" Per client too.", in: try #require(textViews(in: host).first))
        try await settle { fields(in: host) == [elsewhere] }
        #expect(fields(in: host) == [elsewhere])
        #expect(!host.performKeyEquivalent(with: try key("\r", code: 36, [.command, .option], in: window)))
        #expect(try await press(try key("\r", code: 36, .command, in: window), in: host))
        try await settle { composing.open == nil }
        #expect(composing.open == nil)
        #expect(sent.writes.isEmpty)
        #expect(sent.spoken.count == 1)
        window.contentView = nil
    }

    /// VoiceOver hears once that your comment changed since you began, as your edit says so; and once again as your edit
    /// opens again on it, though it heard of that version before, not twice.
    @Test func voiceOverHearsOnceAsYourEditOpensAgainOnAChangedComment() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, sent) = try live()
        let mine = thread.comments[1]
        let composing = Composing()
        composing.open = .edit(mine.id, in: thread.id)
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle { !textViews(in: host).isEmpty }
        let written = mine.markdown + " Per client too."
        type(" Per client too.", in: try #require(textViews(in: host).first))
        try await settle { fields(in: host) == [written] }
        try receive(store, yours: "It reads RetryOptions.MaxDelay, a minute by default.", in: thread)
        try await settle { sent.spoken.count == 1 }

        #expect(try await press(try key("\u{1b}", code: 53, in: window), in: host))
        try await settle { composing.open == nil && fields(in: host).isEmpty }
        #expect(fields(in: host).isEmpty)
        #expect(sent.spoken.count == 1)
        composing.open = .edit(mine.id, in: thread.id)
        try await settle { fields(in: host) == [written] }
        try await settle { sent.spoken.count == 2 }
        try await settle(at: 30)
        let said = ThreadChanges.changedSentence + " " + ThreadChanges.changedChoices
        #expect(sent.spoken == [said, said])
        window.contentView = nil
    }

    /// An edit that may have gone, as one Azure DevOps didn't answer in time, is checked before it goes again: the thread,
    /// read again, has the comment edited elsewhere. VoiceOver hears once that it changed, and that your edit wasn't saved,
    /// though your edit then shows it changed too.
    @Test func voiceOverHearsOnceThatAnEditCheckedAgainWasntSaved() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, sent) = try live()
        sent.fails = .network(ADOClient.unansweredMessage)
        let mine = thread.comments[1]
        let composing = Composing()
        composing.open = .edit(mine.id, in: thread.id)
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle { !textViews(in: host).isEmpty }
        type(" Per client too.", in: try #require(textViews(in: host).first))
        try await settle { fields(in: host) == [mine.markdown + " Per client too."] }
        let commandReturn = try key("\r", code: 36, .command, in: window)
        #expect(try await press(commandReturn, in: host))
        // Unanswered: Save is back once that has landed, not as soon as the stand-in has the edit, still on its way then.
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: thread.id)
        try await settle { if case .failed? = changes.state(of: threadKey) { true } else { false } }
        #expect(sent.writes.count == 1)

        var read = thread
        read.comments[1].text = "It reads RetryOptions.MaxDelay, a minute by default."
        read.comments[1].markdown = read.comments[1].text
        let threads = [read]
        changes.readThreads = { _ in threads }
        #expect(try await press(commandReturn, in: host))
        try await settle { !sent.spoken.isEmpty }
        // Your edit shows it changed, and dims Save, once SwiftUI draws the comment as read again: until then, Save as it was
        // drawn takes ⌘Return.
        try await settle { composing.drawn == read.comments[1].markdown }
        try await settle(at: 30)
        #expect(sent.spoken == [
            ThreadChanges.changedSentence + " " + ThreadChanges.unsavedSentence + " " + ThreadChanges.changedChoices,
        ])
        #expect(sent.writes.count == 1)
        #expect(!host.performKeyEquivalent(with: commandReturn))
        window.contentView = nil
    }

    // MARK: Spell checking

    /// Your edit is spell checked as you type, and nothing corrects, replaces or substitutes what you write by itself, nor
    /// checks its grammar, whatever turns one on: SwiftUI as you type, the right-click menu's Substitutions, or AppKit as the
    /// system's settings change, which key-value observing doesn't hear, here as if they were all on.
    @Test func yourEditIsSpellCheckedAndNothingCorrectsIt() async throws {
        _ = NSApplication.shared
        let (store, changes, thread, _) = try live()
        let composing = Composing()
        composing.open = .edit(thread.comments[1].id, in: thread.id)
        let (window, host) = window(showing: comments(store, changes, composing: composing))
        try await settle { textViews(in: host).first?.isContinuousSpellCheckingEnabled == true }
        let field = try #require(textViews(in: host).first)
        #expect(probes(in: host).first?.textView === field)
        #expect(field.isContinuousSpellCheckingEnabled)
        #expect(corrections(of: field).isEmpty)

        // SwiftUI, as you type, and the right-click menu's Substitutions.
        type(" Per client too.", in: field)
        try await settle(at: 10)
        #expect(field.isContinuousSpellCheckingEnabled)
        #expect(corrections(of: field).isEmpty)
        for keyPath in SpellCheckingProbe.ProbeView.kept { field[keyPath: keyPath] = true }
        #expect(corrections(of: field).isEmpty)

        // AppKit, as the system's settings change, here to on, in memory only: it gives the text view each as it says so, on
        // a Mac here, though not on CI's runner, where there's nothing to turn off again.
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            // As they were, and every text view in the process, as other tests', with the machine's own settings again.
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for name in SpellCheckingProbe.ProbeView.systemSettingChanges {
                NotificationCenter.default.post(name: name, object: nil)
            }
        }
        defaults.setVolatileDomain(arguments.merging(Self.substitutionsOn) { _, on in on }, forName: UserDefaults.argumentDomain)
        for name in SpellCheckingProbe.ProbeView.systemSettingChanges {
            NotificationCenter.default.post(name: name, object: nil)
        }
        // Off, and still off a moment later, should AppKit give them after it posts.
        try await settle { corrections(of: field).isEmpty }
        try await settle(at: 10)
        #expect(corrections(of: field).isEmpty)
        #expect(field.isContinuousSpellCheckingEnabled)
        #expect(probes(in: host).first?.foundNone == false)
        window.contentView = nil
    }

    /// The system's settings, all on.
    private static let substitutionsOn: [String: Any] = [
        "NSAutomaticSpellingCorrectionEnabled": true, "NSAutomaticTextReplacementEnabled": true,
        "NSAutomaticQuoteSubstitutionEnabled": true, "NSAutomaticDashSubstitutionEnabled": true,
    ]

    /// Behind something that isn't an editor, spell checking finds no text view: it says so, as the log does, rather than
    /// leave autocorrection on anywhere.
    @Test func spellCheckingSaysWhenItFindsNoEditor() async throws {
        _ = NSApplication.shared
        let (window, host) = window(showing: AnyView(Text(verbatim: "Not an editor").frame(width: 200, height: 60).spellChecked()))
        try await settle { probes(in: host).first?.foundNone == true }
        let probe = try #require(probes(in: host).first)
        #expect(probe.foundNone)
        #expect(probe.textView == nil)
        window.contentView = nil
    }
}
