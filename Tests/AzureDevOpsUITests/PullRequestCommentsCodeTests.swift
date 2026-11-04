import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// A pull request's comments read their own threads' code wherever they show, as #80 lets them: beside the list, and as a
/// pull request's page over another's details or over a work item's. With made-up pull requests, a stand-in reader, and
/// the comments drawn in a window off screen.
@MainActor
@Suite struct PullRequestCommentsCodeTests {
    /// Code that says whose it is: "// the code of !4102".
    struct Reader: ThreadCodeReader {
        func excerpt(
            of thread: ReviewThread, in pullRequest: PullRequest, context: Int
        ) async -> Result<ThreadExcerpt, ThreadExcerpt.Problem> {
            .success(ThreadExcerpt(
                threadId: thread.id, path: thread.filePath ?? "", side: .right,
                lines: [.init(kind: .added, text: "// the code of !\(pullRequest.key.number)", oldNumber: nil,
                              newNumber: thread.line, isCommented: true)],
                reachesStart: false, reachesEnd: false, iteration: 1, latestIteration: 1
            ))
        }
    }

    /// The demo's pull request that Sam replied on, with its thread 11 on line 88; and another, numbered 4999, with a
    /// thread 11 too, as Azure DevOps numbers each pull request's threads from 1.
    private func records() throws -> (panel: PRRecord, page: PRRecord) {
        let panel = try #require(DemoData.records(now: Date()).first { $0.id.number == 4102 })
        var page = panel
        page.pullRequest.key = PRKey(DemoData.organization, 4999)
        page.pullRequest.title = "Cap the payments client's backoff"
        #expect(page.details?.threads.contains { $0.id == 11 } == true)
        return (panel, page)
    }

    /// The page the comments are on: the Pull Requests page of the window they're in.
    private let page = PullRequestCodeStore.page(.azureDevOpsPullRequests, window: "test")

    private func row(_ record: PRRecord) throws -> PRSnapshot {
        let now = Date()
        return try #require(PRClassifier.snapshot(for: record, seenCutoff: now, dismissedCutoff: .distantPast, now: now))
    }

    /// Its comments, as its details or its page show them, in a window off screen.
    private func comments(of record: PRRecord, list: PRStore, code: PullRequestCodeStore) throws -> AnyView {
        let item = try row(record)
        let copilot = CopilotTasksStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .live, notifier: nil)
        let sessions = PullRequestSessions(copilot: copilot, links: Links(defaults: MemoryDefaults(), isDemo: false))
        return AnyView(
            PullRequestCommentsSection(
                item: item, panel: PullRequestPanel(item, record: record), pullRequest: record.pullRequest, me: record.me,
                place: nil, highlighted: nil, composing: .constant(nil), drafts: CopilotDrafts(), held: .constant([:]),
                showsResolved: .constant(false)
            )
            .environmentObject(list)
            .environmentObject(code)
            // Copilot's part in its threads, which Send Work to Copilot, off, leaves out.
            .environmentObject(copilot)
            .environmentObject(sessions)
            .environmentObject(CopilotQuestions(copilot: copilot))
            // Your replies and statuses, which the demo's list turns on.
            .environmentObject(ThreadChanges(store: list, settings: list.settings))
            // On a window's Pull Requests page, as `WindowView` says.
            .environment(\.shownSection, .azureDevOpsPullRequests)
            .environment(\.shownWindow, "test")
            .frame(width: 440)
        )
    }

    private func window(showing view: AnyView) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 440, height: 1_200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        return (window, host)
    }

    /// Lets SwiftUI lay the window out and run what its views start, until `done`: its run loop runs for a moment, then
    /// what waits on the main actor.
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

    /// The text of each piece of code the window shows.
    private func code(in view: NSView) -> [String] {
        if let code = view as? CodeNSView { return [code.text] }
        return view.subviews.flatMap(code(in:))
    }

    private func isRead(_ code: PullRequestCodeStore, _ thread: Int, of key: PRKey, as text: String) -> Bool {
        guard case .read(let excerpt)? = code.state(of: thread, in: key) else { return false }
        return excerpt.lines.first?.text == text
    }

    @Test func aPullRequestsPageReadsItsOwnThreadsCodeWhateverThePanelShows() async throws {
        _ = NSApplication.shared
        let (panelRecord, pageRecord) = try records()
        let list = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        let code = PullRequestCodeStore { _ in Reader() }
        code.setVisible(true, for: page)
        let details = PullRequestDetailsStore()
        code.follow(details)

        // The panel shows !4102, whose thread 11 is read.
        details.show(try row(panelRecord))
        let panelThread = try #require(panelRecord.details?.threads.first { $0.id == 11 })
        code.show(panelThread, of: panelRecord.pullRequest, by: UUID(), on: page)
        try await settle { isRead(code, 11, of: panelRecord.id, as: "// the code of !4102") }
        #expect(isRead(code, 11, of: panelRecord.id, as: "// the code of !4102"))

        // !4999's page over it: its comments read its own thread 11, and show it, not !4102's.
        let (window, host) = window(showing: try comments(of: pageRecord, list: list, code: code))
        try await settle { self.code(in: host).contains("// the code of !4999") }
        #expect(code.shows(pageRecord.id))
        // Each of its threads on code, as the stand-in reads them all: only !4999's.
        #expect(Set(self.code(in: host)) == ["// the code of !4999"])
        #expect(isRead(code, 11, of: pageRecord.id, as: "// the code of !4999"))
        #expect(isRead(code, 11, of: panelRecord.id, as: "// the code of !4102"))

        // Over a work item's details, with no pull request in the panel: the page's code stays, as it shows.
        details.close()
        #expect(!code.shows(panelRecord.id) && code.state(of: 11, in: panelRecord.id) == nil)
        #expect(code.shows(pageRecord.id) && isRead(code, 11, of: pageRecord.id, as: "// the code of !4999"))

        // Gone, as you go back: nothing shows it, so it's forgotten.
        host.rootView = AnyView(Color.clear.frame(width: 440, height: 100))
        try await settle { !code.shows(pageRecord.id) }
        #expect(!code.shows(pageRecord.id))
        #expect(code.state(of: 11, in: pageRecord.id) == nil)
        window.contentView = nil
    }

    /// A page shown while no window shows its page on screen, as when the window is minimized, reads nothing until one
    /// does.
    @Test func aPageReadsNothingWhileNoWindowShowsIt() async throws {
        _ = NSApplication.shared
        let (_, pageRecord) = try records()
        let list = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        let code = PullRequestCodeStore { _ in Reader() }
        let (window, host) = window(showing: try comments(of: pageRecord, list: list, code: code))
        try await settle { code.shows(pageRecord.id) }
        #expect(code.shows(pageRecord.id))
        // Long enough for a thread on screen to ask for its code.
        for _ in 0..<30 {
            Self.runLoop()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(code.state(of: 11, in: pageRecord.id) == nil)
        #expect(self.code(in: host).isEmpty)

        // Shown on screen: it's read.
        code.setVisible(true, for: page)
        try await settle { self.code(in: host).contains("// the code of !4999") }
        #expect(Set(self.code(in: host)) == ["// the code of !4999"])
        window.contentView = nil
    }
}
