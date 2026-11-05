import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// What you leave in pull requests' details as you go, kept above the views that show them, which come and go: what you
/// wrote in their Copilot composers, by pull request and composer, until you send it; and where the threads you changed were,
/// while the details show their pull request, pages over them included. With the made-up pull requests and sprint, which
/// never use the Azure CLI or Azure DevOps.
@MainActor
@Suite struct DetailsDraftsTests {
    private let now = Date()
    private let records: [PRRecord]
    private let items: [PRSnapshot]

    init() {
        let now = now
        let seen = DemoData.seenState(now: now)
        records = DemoData.records(now: now)
        items = PROrdering.sorted(records.compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), dismissedCutoff: seen.dismissedCutoff(for: $0.id), now: now)
        })
    }

    private func item(_ number: Int) throws -> PRSnapshot {
        try #require(items.first { $0.key.number == number })
    }

    /// A thread of a pull request, as its details list it.
    private func thread(_ id: Int, of number: Int) throws -> PullRequestPanel.Thread {
        let item = try item(number)
        let record = try #require(records.first { $0.id == item.key })
        return try #require(PullRequestPanel(item, record: record).threads.all.first { $0.id == id })
    }

    private func key(_ number: Int) -> PRKey { PRKey(DemoData.organization, number) }

    private let session = ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01")!

    // MARK: What you wrote

    /// What you wrote in a composer stays, for each pull request and each composer on its own, as the details' views come and
    /// go, until it's sent; emptied, nothing's kept.
    @Test func whatYouWroteStaysByPullRequestAndComposerUntilItsSent() {
        let drafts = DetailsDrafts()
        let fix = CopilotComposing(part: .thread(11), ask: .fix)
        let explain = CopilotComposing(part: .thread(11), ask: .explain)
        drafts.keep("Cap it at 30 seconds, from RetryOptions", in: fix, of: key(4102))
        #expect(drafts.words(in: fix, of: key(4102)) == "Cap it at 30 seconds, from RetryOptions")
        // Another composer's, or the same thread's of another pull request, which Azure DevOps numbers from 1 too.
        #expect(drafts.words(in: explain, of: key(4102)).isEmpty)
        #expect(drafts.words(in: fix, of: key(4088)).isEmpty)
        #expect(drafts.words(in: .fixAll, of: key(4102)).isEmpty)

        drafts.keep("Why 30?", in: explain, of: key(4102))
        drafts.sent("Why 30?", in: explain, of: key(4102))
        #expect(drafts.words(in: explain, of: key(4102)).isEmpty)
        #expect(drafts.words(in: fix, of: key(4102)) == "Cap it at 30 seconds, from RetryOptions")
        // Written on while it went, as in the same composer in another window: what you wrote since stays.
        drafts.keep("Why 30? And why not 45?", in: explain, of: key(4102))
        drafts.sent("Why 30?", in: explain, of: key(4102))
        #expect(drafts.words(in: explain, of: key(4102)) == "Why 30? And why not 45?")
        drafts.keep("", in: fix, of: key(4102))
        #expect(drafts.words(in: fix, of: key(4102)).isEmpty)
    }

    /// A send called off once the session took it, as when its composer closes or its page goes while it says it's sending,
    /// went all the same: what you wrote goes, so that the composer doesn't open with it again, to send it twice. So does
    /// what was copied for you to paste. What didn't go stays: nothing went, or the Send to Copilot window takes it.
    @Test func whatWentIsForgottenThoughItsSendWasCalledOff() async {
        let drafts = DetailsDrafts()
        let fix = CopilotComposing(part: .thread(11), ask: .fix)
        let outcomes: [(CopilotSending.Outcome, forgets: Bool)] = [
            (.sent, true), (.copied("Copied the prompt, for you to paste"), true), (.notSent("The session is busy"), false), (.needsWindow, false),
        ]
        for (outcome, forgets) in outcomes {
            drafts.keep("Cap it at 30 seconds", in: fix, of: key(4102))
            let send = Task { @MainActor in
                await drafts.send("Cap it at 30 seconds", in: fix, of: key(4102)) {
                    // Taken: the session's answer comes, though the send was called off meanwhile.
                    while !Task.isCancelled { await Task.yield() }
                    return outcome
                }
            }
            send.cancel()
            #expect(await send.value == outcome)
            #expect(drafts.words(in: fix, of: key(4102)).isEmpty == forgets)
        }
    }

    /// What you write in a composer, and its going, says which composer's words changed, for the same composer open
    /// elsewhere to follow: not the same words again.
    @Test func whichComposersWordsChangedIsSaid() {
        final class Heard {
            var composers: [DetailsDrafts.Composer] = []
        }
        let drafts = DetailsDrafts()
        let heard = Heard()
        let subscription = drafts.wordsChanged.sink { heard.composers.append($0) }
        defer { subscription.cancel() }
        let fix = CopilotComposing(part: .thread(11), ask: .fix)
        drafts.keep("Cap it", in: fix, of: key(4102))
        drafts.keep("Cap it", in: fix, of: key(4102))
        drafts.keep("Cap it at 30", in: fix, of: key(4102))
        // Not what's kept now: nothing goes.
        drafts.sent("Cap it", in: fix, of: key(4102))
        drafts.sent("Cap it at 30", in: fix, of: key(4102))
        let thread = DetailsDrafts.Composer(pullRequest: key(4102), composer: fix)
        #expect(heard.composers == [thread, thread, thread])
        drafts.keep("Skip weekends", in: .fixAll, of: key(4088))
        drafts.forgetAll()
        let fixAll = DetailsDrafts.Composer(pullRequest: key(4088), composer: .fixAll)
        #expect(heard.composers == [thread, thread, thread, fixAll, fixAll])
    }

    /// Send Work to Copilot turned off takes the composers away, and what you wrote in them goes: it doesn't come back as it's
    /// turned on again. Where threads were stays: that's your replies'.
    @Test func whatYouWroteGoesAsSendWorkToCopilotIsTurnedOff() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let drafts = DetailsDrafts(settings: settings)
        let fix = CopilotComposing(part: .build(31), ask: .fix, row: "build-1")
        drafts.keep("Skip weekends", in: fix, of: key(4088))
        drafts.hold(try thread(11, of: 4102), in: key(4102))
        // Turned on again, or the same: nothing changes.
        settings.copilotEnabled = true
        #expect(drafts.words(in: fix, of: key(4088)) == "Skip weekends")

        settings.copilotEnabled = false
        #expect(drafts.words(in: fix, of: key(4088)).isEmpty)
        #expect(drafts.held(in: key(4102))[11] != nil)
        settings.copilotEnabled = true
        #expect(drafts.words(in: fix, of: key(4088)).isEmpty)
    }

    /// Someone else signing in to the Azure CLI forgets what you left in the details, as it does your replies; the same one,
    /// or the first one the list tells of, doesn't.
    @Test func someoneElseSigningInForgetsWhatYouLeft() throws {
        let drafts = DetailsDrafts()
        let fix = CopilotComposing(part: .thread(11), ask: .fix)
        drafts.accountChanged("robin@contoso.example")
        drafts.keep("Cap it", in: fix, of: key(4102))
        drafts.hold(try thread(11, of: 4102), in: key(4102))
        drafts.accountChanged(nil)
        drafts.accountChanged("robin@contoso.example")
        #expect(drafts.words(in: fix, of: key(4102)) == "Cap it")
        #expect(drafts.held(in: key(4102))[11] != nil)

        drafts.accountChanged("sam@contoso.example")
        #expect(drafts.words(in: fix, of: key(4102)).isEmpty)
        #expect(drafts.held(in: key(4102)).isEmpty)
    }

    // MARK: Where threads were

    /// A thread you change stays where it was as you first did, with those that wait on you, however it stands after, and
    /// however often you change it: until the details show its pull request no more.
    @Test func aThreadStaysWhereItWasAsYouFirstChangedIt() throws {
        let drafts = DetailsDrafts()
        let waiting = try thread(11, of: 4102)
        #expect(waiting.placement == .waitingOnYou)
        drafts.hold(waiting, in: key(4102))
        // Resolved since, and changed again: where it was as you first did.
        var resolved = waiting
        resolved.waitsOnYou = false
        resolved.thread.status = "fixed"
        #expect(resolved.placement == .resolved)
        drafts.hold(resolved, in: key(4102))
        #expect(drafts.held(in: key(4102))[11] == PullRequestPanel.Thread.Held(waiting))
        // Another pull request's thread 11 is its own.
        #expect(drafts.held(in: key(4088)).isEmpty)
        // Its details list it with the open ones, where it was, rather than folded away with the resolved ones.
        let threads = PullRequestPanel.Threads(waitingOnYou: [], open: [], resolved: [resolved])
        let arranged = threads.arranged(holding: drafts.held(in: key(4102)))
        #expect(arranged.open.flatMap(\.threads).map(\.id) == [11])
        #expect(arranged.resolved.isEmpty)
    }

    /// A thread you marked as read in the details, then change, stays where it was as you marked it as read, with those
    /// that wait on you: there too once you mark it as unread, which lets go of where it was then, as you changed it since.
    @Test func aThreadYouMarkedAsReadThenChangedStaysWhereItWasThen() throws {
        let drafts = DetailsDrafts()
        let waiting = try thread(11, of: 4102)
        #expect(waiting.placement == .waitingOnYou)
        // Marked as read, the details hold it where it was (`PullRequestDetailsStore.readHolds`); then you resolve it.
        let read = [11: PullRequestPanel.Thread.Held(waiting)]
        var resolved = waiting
        resolved.waitsOnYou = false
        resolved.thread.status = "fixed"
        drafts.hold(resolved, in: key(4102), read: read)
        #expect(drafts.held(in: key(4102))[11] == PullRequestPanel.Thread.Held(waiting))
        // Marked as unread: where you changed it still holds it.
        let threads = PullRequestPanel.Threads(waitingOnYou: [], open: [], resolved: [resolved])
        let arranged = threads.arranged(holding: PullRequestPanel.Thread.Held.kept(changed: drafts.held(in: key(4102)), read: [:]))
        #expect(arranged.open.flatMap(\.threads).map(\.id) == [11])
        #expect(arranged.resolved.isEmpty)
        // Another pull request's thread 11, which you didn't mark as read there, is held where it is.
        var other = resolved
        other.thread.status = "closed"
        drafts.hold(other, in: key(4088), read: [:])
        #expect(drafts.held(in: key(4088))[11] == PullRequestPanel.Thread.Held(other))
    }

    /// Beside the list, where the threads you changed were stays while the details show their pull request: as a page opens
    /// over them, such as its Copilot session's, and you come back, and as a file's page shows in their place. Once they show
    /// another pull request, or close, it goes: back to it, a thread you resolved is with the resolved ones.
    @Test func whereThreadsWereStaysWhileTheDetailsShowThePullRequest() async throws {
        let drafts = DetailsDrafts()
        let panel = PullRequestDetailsStore()
        panel.itemsChanged(items)
        drafts.follow(panel, pagesOver: workItems())
        panel.show(try item(4102))
        drafts.hold(try thread(11, of: 4102), in: key(4102))

        panel.open(page: session)
        await settled()
        panel.back()
        panel.open(file: "/src/Payments/PaymentsClient.cs", at: 11)
        await settled()
        panel.closeFile()
        // A pull request's page over it, and back.
        panel.open(page: key(4088).linkRef)
        await settled()
        panel.back()
        // Shown again, from the list: the same look at it.
        panel.show(try item(4102))
        await settled()
        #expect(drafts.held(in: key(4102))[11] != nil)

        panel.show(try item(4088))
        await settled()
        #expect(drafts.held(in: key(4102)).isEmpty)

        panel.show(try item(4102))
        drafts.hold(try thread(11, of: 4102), in: key(4102))
        panel.close()
        await settled()
        #expect(drafts.held(in: key(4102)).isEmpty)
    }

    /// The resolved threads, once you show them, or going to one of them did, stay shown with where the threads you changed
    /// were: as a file's page shows in the details' place and you come back, so that a thread you reactivated, which stays
    /// with them, is there to go back to. They fold again once the details show the pull request no more, or someone else
    /// signs in.
    @Test func theResolvedThreadsStayShownWithWhereThreadsWere() async throws {
        let drafts = DetailsDrafts()
        let panel = PullRequestDetailsStore()
        panel.itemsChanged(items)
        drafts.follow(panel, pagesOver: workItems())
        panel.show(try item(4102))
        #expect(!drafts.showsResolved(in: key(4102)))
        drafts.setShowsResolved(true, in: key(4102))
        #expect(drafts.showsResolved(in: key(4102)) && !drafts.showsResolved(in: key(4088)))

        panel.open(file: "/src/Payments/PaymentsClient.cs", at: 11)
        await settled()
        panel.closeFile()
        panel.open(page: session)
        await settled()
        panel.back()
        await settled()
        #expect(drafts.showsResolved(in: key(4102)))

        drafts.setShowsResolved(false, in: key(4102))
        #expect(!drafts.showsResolved(in: key(4102)))
        drafts.setShowsResolved(true, in: key(4102))
        panel.show(try item(4088))
        await settled()
        #expect(!drafts.showsResolved(in: key(4102)))

        drafts.setShowsResolved(true, in: key(4088))
        drafts.accountChanged("robin@contoso.example")
        drafts.accountChanged("sam@contoso.example")
        #expect(!drafts.showsResolved(in: key(4088)))
    }

    /// A pull request whose page shows over another's details, chosen in the list, shows beside it instead: where its threads
    /// were stays, though its page goes before it shows there; the other's goes.
    @Test func aPullRequestsPageChosenInTheListKeepsWhereItsThreadsWere() async throws {
        let drafts = DetailsDrafts()
        let panel = PullRequestDetailsStore()
        panel.itemsChanged(items)
        drafts.follow(panel, pagesOver: workItems())
        panel.show(try item(4097))
        drafts.hold(try thread(21, of: 4097), in: key(4097))
        panel.open(page: key(4102).linkRef)
        drafts.hold(try thread(11, of: 4102), in: key(4102))
        await settled()
        #expect(drafts.held(in: key(4097))[21] != nil && drafts.held(in: key(4102))[11] != nil)

        panel.show(try item(4102))
        await settled()
        #expect(drafts.held(in: key(4102))[11] != nil)
        #expect(drafts.held(in: key(4097)).isEmpty)
    }

    /// On a pull request's page over a work item's details, or over another pull request's, where its threads were stays
    /// while the page shows, a page over it included, and goes once you go back from it.
    @Test func andWhileItsPageShowsOverAWorkItemOrAnotherPullRequest() async throws {
        let drafts = DetailsDrafts()
        let panel = PullRequestDetailsStore()
        panel.itemsChanged(items)
        let workItems = workItems()
        drafts.follow(panel, pagesOver: workItems)
        let board = DemoData.sprintBoard(now: now)
        workItems.boardChanged(board)
        workItems.show(try #require(board.item(WorkItemKey(DemoData.organization, 5101))))
        workItems.open(page: key(4102).linkRef)
        drafts.hold(try thread(11, of: 4102), in: key(4102))
        // Its Copilot session's page over it, and back.
        workItems.open(page: session)
        await settled()
        workItems.back()
        await settled()
        #expect(drafts.held(in: key(4102))[11] != nil)
        workItems.back()
        await settled()
        #expect(drafts.held(in: key(4102)).isEmpty)

        // Over another pull request's details beside the list.
        panel.show(try item(4088))
        panel.open(page: key(4102).linkRef)
        drafts.hold(try thread(11, of: 4102), in: key(4102))
        panel.open(page: session)
        await settled()
        #expect(drafts.held(in: key(4102))[11] != nil)
        panel.back(toPage: nil)
        await settled()
        #expect(drafts.held(in: key(4102)).isEmpty)
    }

    /// Azure DevOps keeps them for its details, beside the list and on its pages, and follows what they show.
    @Test func azureDevOpsKeepsThemForItsDetails() async throws {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = AzureDevOpsSource(services: services, summarizer: .withoutModel)
        source.start()
        defer { source.stop() }
        let details = try #require(source.pullRequestDetails)
        let drafts = try #require(source.detailsDrafts)
        details.show(try item(4102))
        drafts.hold(try thread(11, of: 4102), in: key(4102))
        drafts.keep("Cap it", in: CopilotComposing(part: .thread(11), ask: .fix), of: key(4102))
        details.show(try item(4088))
        await settled()
        #expect(drafts.held(in: key(4102)).isEmpty)
        #expect(drafts.words(in: CopilotComposing(part: .thread(11), ask: .fix), of: key(4102)) == "Cap it")

        // Stopped, all of it goes.
        source.stop()
        #expect(drafts.words(in: CopilotComposing(part: .thread(11), ask: .fix), of: key(4102)).isEmpty)
    }

    /// Once what waits on the main queue ran, as what the details show is followed once each of their moves is done.
    private func settled() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private struct NoTokens: AccessTokenProvider {
        struct Unused: Error {}
        func token(tenant: String?) async throws -> AccessToken { throw Unused() }
        func invalidate(tenant: String?) async {}
    }

    /// A work item's details, from the made-up sprint, which read nothing.
    private func workItems() -> WorkItemDetailsStore {
        WorkItemDetailsStore(mode: .demo, client: ADOClient(tokens: NoTokens()), board: Empty().eraseToAnyPublisher())
    }

    // MARK: In a composer

    /// A composer opens with what you wrote in it, however it went: as a page over the details or a file's page in their place
    /// came and went, or the details showed another pull request and came back, each of which makes it anew. What you type
    /// is kept as you type it. Fix on thread 11 of !4102, drawn in a window off screen.
    @Test func aComposerOpensWithWhatYouWroteWhereverItOpensAgain() async throws {
        _ = NSApplication.shared
        let drafts = DetailsDrafts()
        let fix = CopilotComposing(part: .thread(11), ask: .fix)
        let composer = try fixComposer(drafts)
        drafts.keep("Cap it at 30 seconds", in: fix, of: key(4102))
        let (window, host) = window(showing: composer())
        defer { window.contentView = nil }
        try await settle { fields(in: host).contains("Cap it at 30 seconds") }
        #expect(fields(in: host).contains("Cap it at 30 seconds"))

        // You type on.
        try type(", from RetryOptions", in: host)
        try await settle { drafts.words(in: fix, of: key(4102)) == "Cap it at 30 seconds, from RetryOptions" }
        #expect(drafts.words(in: fix, of: key(4102)) == "Cap it at 30 seconds, from RetryOptions")

        // Gone, as a page opens over the details, then made anew as you come back: with what you wrote.
        host.rootView = AnyView(Color.clear.frame(width: 440, height: 100))
        try await settle { fields(in: host).isEmpty }
        host.rootView = composer()
        try await settle { fields(in: host).contains("Cap it at 30 seconds, from RetryOptions") }
        #expect(fields(in: host).contains("Cap it at 30 seconds, from RetryOptions"))
    }

    /// The same composer open in two windows, as Fix on a thread beside the list and on its pull request's page over a work
    /// item's details: what you write in either shows in the other, so neither writes over what you wrote in the other, nor
    /// sends what's out of date; and once it went, it's gone from both.
    @Test func theSameComposerInTwoWindowsFollowsWhatYouWrite() async throws {
        _ = NSApplication.shared
        let drafts = DetailsDrafts()
        let fix = CopilotComposing(part: .thread(11), ask: .fix)
        let composer = try fixComposer(drafts)
        let (first, firstHost) = window(showing: composer())
        let (second, secondHost) = window(showing: composer())
        defer {
            first.contentView = nil
            second.contentView = nil
        }
        try await settle { !fields(in: firstHost).isEmpty && !fields(in: secondHost).isEmpty }

        try type("Cap it at 30 seconds", in: firstHost)
        try await settle { fields(in: secondHost).contains("Cap it at 30 seconds") }
        #expect(fields(in: secondHost).contains("Cap it at 30 seconds"))
        try type(", from RetryOptions", in: secondHost)
        try await settle { fields(in: firstHost).contains("Cap it at 30 seconds, from RetryOptions") }
        #expect(fields(in: firstHost).contains("Cap it at 30 seconds, from RetryOptions"))
        #expect(drafts.words(in: fix, of: key(4102)) == "Cap it at 30 seconds, from RetryOptions")

        drafts.sent("Cap it at 30 seconds, from RetryOptions", in: fix, of: key(4102))
        try await settle { !(fields(in: firstHost) + fields(in: secondHost)).contains { $0.contains("Cap it") } }
        #expect(!(fields(in: firstHost) + fields(in: secondHost)).contains { $0.contains("Cap it") })
    }

    /// Fix on thread 11 of !4102, as its composer draws it, with made-up stores and what `drafts` keeps: each call makes
    /// another, as each window that shows it does.
    private func fixComposer(_ drafts: DetailsDrafts) throws -> () -> AnyView {
        let list = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        let copilot = CopilotTasksStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo, notifier: nil)
        let sessions = PullRequestSessions(copilot: copilot, links: Links(defaults: MemoryDefaults(), isDemo: false))
        let questions = CopilotQuestions(copilot: copilot)
        let code = PullRequestCodeStore(demo: true, client: ADOClient(tokens: NoTokens()))
        let item = try item(4102)
        let thread = try thread(11, of: 4102).thread
        return {
            AnyView(
                CommentComposer(ask: .fix, thread: thread, item: item, worked: nil, drafts: CopilotDrafts()) { _ in }
                    .environmentObject(list)
                    .environmentObject(copilot)
                    .environmentObject(sessions)
                    .environmentObject(questions)
                    .environmentObject(code)
                    .environmentObject(drafts)
                    .frame(width: 440)
            )
        }
    }

    /// A window off screen that shows `view`.
    private func window(showing view: AnyView) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 440, height: 400), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        return (window, host)
    }

    /// Types at the end of the field the window shows, as you would: in it, once it's being edited.
    private func type(_ text: String, in view: NSView) throws {
        let editor: NSTextView
        if let editing = textView(in: view) {
            editor = editing
        } else {
            let field = try #require(textField(in: view))
            #expect(field.window?.makeFirstResponder(field) == true)
            editor = try #require(field.currentEditor() as? NSTextView)
        }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// The field the window shows, as AppKit has it while it isn't being edited.
    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(textField(in:)).first
    }

    /// Lets SwiftUI lay the window out and run what its views start, until `done`, for as long as a busy machine could
    /// need (`waitLimit`). It awaits between looks, so that the main run loop does that meanwhile, and the main actor goes
    /// on with other tests' work: a test that ran that run loop itself would hold the main actor until it returned.
    private func settle(until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !done() {
            guard ContinuousClock.now < deadline else { throw Timeout(description: "Timed out waiting for the window") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The text of each field the window shows.
    private func fields(in view: NSView) -> [String] {
        if let text = view as? NSTextView { return [text.string] }
        if let field = view as? NSTextField, field.isEditable { return [field.stringValue] }
        return view.subviews.flatMap(fields(in:))
    }

    /// The field you type in, as AppKit has it.
    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap(textView(in:)).first
    }

    // MARK: What VoiceOver hears

    /// What became of Copilot's work on something, or of a question about it, is said once, though each view that shows it
    /// says so: the same pull request's details in two windows, or two rows of a build that two policies run. The same
    /// again later, from a new time, is said again; so is another part's, run's or pull request's.
    @Test func whatBecameOfSomethingIsSaidOnce() {
        let outcomes = SpokenOutcomes()
        let ended = Date(timeIntervalSince1970: 1_792_317_600)
        let fixed = SpokenText.Outcome(pullRequest: key(4088), part: .build(31), said: "Fixed in ‘Retry backoff’, not pushed", since: ended)
        #expect(outcomes.isNew(fixed, at: ended))
        #expect(!outcomes.isNew(fixed, at: ended.addingTimeInterval(0.2)))
        #expect(!outcomes.isNew(fixed, at: ended.addingTimeInterval(30)))

        var asked = fixed
        asked.since = ended.addingTimeInterval(120)
        #expect(outcomes.isNew(asked, at: ended.addingTimeInterval(120)))
        var other = fixed
        other.part = .build(32)
        #expect(outcomes.isNew(other, at: ended))
        other = fixed
        other.pullRequest = key(4102)
        #expect(outcomes.isNew(other, at: ended))
        // A question about another run of the build is its own.
        let answered = SpokenText.Outcome(pullRequest: key(4088), part: .build(31), run: 204_417, said: "‘Retry backoff’ answered", since: ended)
        var otherRun = answered
        otherRun.run = 204_418
        #expect(outcomes.isNew(answered, at: ended))
        #expect(outcomes.isNew(otherRun, at: ended))
        #expect(!outcomes.isNew(answered, at: ended))

        // Long after, it's forgotten.
        #expect(outcomes.isNew(fixed, at: ended.addingTimeInterval(SpokenOutcomes.remembered + 1)))
    }
}

private struct Timeout: Error, CustomStringConvertible {
    var description: String
}
