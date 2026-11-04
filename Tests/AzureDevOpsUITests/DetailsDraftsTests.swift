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
        drafts.sent(explain, of: key(4102))
        #expect(drafts.words(in: explain, of: key(4102)).isEmpty)
        #expect(drafts.words(in: fix, of: key(4102)) == "Cap it at 30 seconds, from RetryOptions")
        drafts.keep("", in: fix, of: key(4102))
        #expect(drafts.words(in: fix, of: key(4102)).isEmpty)
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

    /// Beside the list, where the threads you changed were stays while the details show their pull request: as a page opens
    /// over them, such as its Copilot session's, and you come back, and as a file's page shows in their place. Once they show
    /// another pull request, or close, it goes: back to it, a thread you resolved is with the resolved ones.
    @Test func whereThreadsWereStaysWhileTheDetailsShowThePullRequest() throws {
        let drafts = DetailsDrafts()
        let panel = PullRequestDetailsStore()
        panel.itemsChanged(items)
        drafts.follow(panel, pagesOver: workItems())
        panel.show(try item(4102))
        drafts.hold(try thread(11, of: 4102), in: key(4102))

        panel.open(page: session)
        panel.back()
        panel.open(file: "/src/Payments/PaymentsClient.cs", at: 11)
        panel.closeFile()
        // A pull request's page over it, and back.
        panel.open(page: key(4088).linkRef)
        panel.back()
        // Shown again, from the list: the same look at it.
        panel.show(try item(4102))
        #expect(drafts.held(in: key(4102))[11] != nil)

        panel.show(try item(4088))
        #expect(drafts.held(in: key(4102)).isEmpty)

        panel.show(try item(4102))
        drafts.hold(try thread(11, of: 4102), in: key(4102))
        panel.close()
        #expect(drafts.held(in: key(4102)).isEmpty)
    }

    /// On a pull request's page over a work item's details, or over another pull request's, where its threads were stays
    /// while the page shows, a page over it included, and goes once you go back from it.
    @Test func andWhileItsPageShowsOverAWorkItemOrAnotherPullRequest() throws {
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
        workItems.back()
        #expect(drafts.held(in: key(4102))[11] != nil)
        workItems.back()
        #expect(drafts.held(in: key(4102)).isEmpty)

        // Over another pull request's details beside the list.
        panel.show(try item(4088))
        panel.open(page: key(4102).linkRef)
        drafts.hold(try thread(11, of: 4102), in: key(4102))
        panel.open(page: session)
        #expect(drafts.held(in: key(4102))[11] != nil)
        panel.back(toPage: nil)
        #expect(drafts.held(in: key(4102)).isEmpty)
    }

    /// Azure DevOps keeps them for its details, beside the list and on its pages, and follows what they show.
    @Test func azureDevOpsKeepsThemForItsDetails() throws {
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
        #expect(drafts.held(in: key(4102)).isEmpty)
        #expect(drafts.words(in: CopilotComposing(part: .thread(11), ask: .fix), of: key(4102)) == "Cap it")

        // Stopped, all of it goes.
        source.stop()
        #expect(drafts.words(in: CopilotComposing(part: .thread(11), ask: .fix), of: key(4102)).isEmpty)
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
        let list = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        let copilot = CopilotTasksStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo, notifier: nil)
        let sessions = PullRequestSessions(copilot: copilot, links: Links(defaults: MemoryDefaults(), isDemo: false))
        let questions = CopilotQuestions(copilot: copilot)
        let code = PullRequestCodeStore(demo: true, client: ADOClient(tokens: NoTokens()))
        let drafts = DetailsDrafts()
        let fix = CopilotComposing(part: .thread(11), ask: .fix)
        let item = try item(4102)
        let thread = try thread(11, of: 4102).thread
        func composer() -> AnyView {
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
        drafts.keep("Cap it at 30 seconds", in: fix, of: item.key)
        let host = NSHostingView(rootView: composer())
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 440, height: 400), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await settle { fields(in: host).contains("Cap it at 30 seconds") }
        #expect(fields(in: host).contains("Cap it at 30 seconds"))

        // You type on.
        let field = try #require(textView(in: host))
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        field.insertText(", from RetryOptions", replacementRange: field.selectedRange())
        try await settle { drafts.words(in: fix, of: item.key) == "Cap it at 30 seconds, from RetryOptions" }
        #expect(drafts.words(in: fix, of: item.key) == "Cap it at 30 seconds, from RetryOptions")

        // Gone, as a page opens over the details, then made anew as you come back: with what you wrote.
        host.rootView = AnyView(Color.clear.frame(width: 440, height: 100))
        try await settle { fields(in: host).isEmpty }
        host.rootView = composer()
        try await settle { fields(in: host).contains("Cap it at 30 seconds, from RetryOptions") }
        #expect(fields(in: host).contains("Cap it at 30 seconds, from RetryOptions"))
    }

    /// Lets SwiftUI lay the window out and run what its views start, until `done`.
    private func settle(until done: () -> Bool) async throws {
        for _ in 0..<300 where !done() {
            Self.runLoop()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The main run loop, for a moment, where SwiftUI lays windows out and starts their views' tasks.
    private static func runLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
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
