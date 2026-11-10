import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// The actions under a pull request's heading: its Copilot session, opened as its line's ⌄ opens it, the folder it works
/// in now, and Fill the Page, which lasts until the details close or Show the List, and leaves a file's page its own.
@MainActor
@Suite(.opensNothing) struct PullRequestActionsRowTests {
    private let now = Date(timeIntervalSince1970: 1_792_317_600)
    private let fixing = "11111111-1111-4111-8111-111111111111"
    private let onBranch = "44444444-4444-4444-8444-444444444444"
    private let other = "77777777-7777-4777-8777-777777777777"

    private func run(_ id: String, inApp: Bool = false) -> CopilotRun {
        var run = CopilotRun(
            id: id, workItem: nil,
            onPullRequest: PullRequestReference(organization: "contoso", project: "Storefront", repository: "shop-web", id: 4071, sourceBranch: "fix-totals"),
            action: .fixComments, options: CopilotModel.standard,
            repository: URL(fileURLWithPath: "/tmp/shop-web"), worktree: URL(fileURLWithPath: "/tmp/copilot-worktrees/shop-web/pr-4071"),
            startedAt: now.addingTimeInterval(-600), process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished
        )
        if inApp { run.isAppSession = true }
        return run
    }

    private func task(_ id: String, inApp: Bool = false, busy: Bool = false) -> SessionChoice {
        let made = run(id, inApp: inApp)
        return SessionChoice(kind: .task(made), name: id, lastActive: made.startedAt, reasons: [.earlierTask], isBusy: busy)
    }

    private func app(_ id: String, folder: URL? = nil) -> SessionChoice {
        let session = AppSession(id: id, name: "Retry backoff", lastActive: now.addingTimeInterval(-60))
        var choice = SessionChoice(kind: .app(session), name: "Retry backoff", lastActive: session.lastActive, reasons: [.onItsBranch])
        choice.appFolder = folder
        return choice
    }

    private func session(_ pick: PullRequestSession.Pick, canChoose: Bool = true) -> PullRequestSession {
        PullRequestSession(pick: pick, candidates: [], others: [], guess: nil, delivery: nil, canChoose: canChoose)
    }

    @Test func offersItsSessionAndTheFolderItWorksIn() throws {
        // A session of the Copilot app's opens in Copilot, and its folder, as read with Send Work to Copilot on.
        let folder = URL(fileURLWithPath: "/Users/robin/Developer/copilot-worktrees/shop-web/retry-backoff", isDirectory: true)
        let appShortcuts = try #require(SessionShortcuts.of(session(.session(app(onBranch, folder: folder), .onItsBranch))))
        #expect(appShortcuts.way == .copilot && appShortcuts.folder == folder)
        // A task BriefBar runs with the Copilot CLI goes on in Terminal, in its worktree; one that went on with one of the
        // app's sessions, in Copilot.
        let taskShortcuts = try #require(SessionShortcuts.of(session(.session(task(fixing), .lastTask))))
        #expect(taskShortcuts.way == .terminal && taskShortcuts.folder?.path == "/tmp/copilot-worktrees/shop-web/pr-4071")
        #expect(SessionShortcuts.of(session(.session(task(fixing, inApp: true), .lastTask)))?.way == .copilot)
        // A session only Show Links links to it, until its folder is read: none.
        let linked = try #require(SessionShortcuts.of(session(.session(app(onBranch), .linkedByYou), canChoose: false)))
        #expect(linked.way == .copilot && linked.folder == nil)
        // Nothing without one, or while BriefBar asks which it is.
        #expect(SessionShortcuts.of(nil) == nil)
        #expect(SessionShortcuts.of(session(.newSession(chosenByYou: false))) == nil)
        #expect(SessionShortcuts.of(session(.newSession(chosenByYou: true))) == nil)
        #expect(SessionShortcuts.of(session(.ask([app(onBranch), app(other)]))) == nil)
    }

    /// A task that went on with one of the app's sessions opens where that session works now, as read, which may have moved
    /// since the task started; until it's read, where it started. A task BriefBar runs with the Copilot CLI works in its own
    /// worktree.
    @Test func opensWhereTheSessionATaskWentOnWithWorksNow() {
        let started = "/tmp/copilot-worktrees/shop-web/pr-4071"
        let moved = URL(fileURLWithPath: "/tmp/copilot-worktrees/shop-web/pr-4071-continued", isDirectory: true)
        var inApp = task(fixing, inApp: true)
        #expect(SessionShortcuts.of(session(.session(inApp, .lastTask)))?.folder?.path == started)
        inApp.appFolder = moved
        #expect(SessionShortcuts.of(session(.session(inApp, .lastTask)))?.folder == moved)
        // Where it started is still its worktree, to tell whether another task works in its checkout.
        #expect(inApp.folder?.path == started)
        var own = task(fixing)
        own.appFolder = moved
        #expect(SessionShortcuts.of(session(.session(own, .lastTask)))?.folder?.path == started)
    }

    @Test func namesTheFolderInItsTooltips() {
        let worktree = URL(fileURLWithPath: "/tmp/copilot-worktrees/shop-web/pr-4071", isDirectory: true)
        #expect(SessionShortcuts.folderPhrase(task(fixing), folder: worktree)
            == "the worktree ‘Fix Comments’ works in, /tmp/copilot-worktrees/shop-web/pr-4071")
        #expect(SessionShortcuts.folderPhrase(app(onBranch), folder: worktree).hasPrefix("the folder ‘Retry backoff’ works in, "))
    }

    /// As its line's ⌄ opens it: never while Copilot works in it or in its checkout; a task in Terminal only once it's done,
    /// and not in the demo, which sends nothing.
    @Test func opensTheSessionOnlyWhenItsLineWould() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        settings.copilotRuns = [run(fixing)]
        let done = SessionOpening.of(task(fixing), links: links, copilot: store)
        #expect(done.way == .terminal && done.title == "Continue in Terminal" && done.isEnabled)
        #expect(!SessionOpening.of(task(fixing, busy: true), links: links, copilot: store).isEnabled)
        // A task BriefBar no longer has.
        #expect(!SessionOpening.of(task(other), links: links, copilot: store).isEnabled)
        let inCopilot = SessionOpening.of(app(onBranch), links: links, copilot: store)
        #expect(inCopilot.way == .copilot && inCopilot.title == "Open in Copilot" && inCopilot.isEnabled)
        var busy = app(onBranch)
        busy.isFolderBusy = true
        #expect(!SessionOpening.of(busy, links: links, copilot: store).isEnabled)

        let demo = CopilotTasksStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo, notifier: nil)
        let finished = try #require(demo.entries.first { !$0.status.phase.isActive })
        let demoTask = SessionChoice(kind: .task(run(finished.id)), name: finished.id, reasons: [.openedIt])
        #expect(!SessionOpening.of(demoTask, links: links, copilot: demo).isEnabled)
    }

    /// Fill the Page lasts as other pull requests, pages and files' pages show, until the details close or Show the List,
    /// which ends a file's page's filling it too.
    @Test func fillingThePageLastsUntilTheDetailsCloseOrShowTheList() throws {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let items = DemoData.records(now: now).compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), dismissedCutoff: seen.dismissedCutoff(for: $0.id), now: now)
        }
        let first = try #require(items.first)
        let second = try #require(items.dropFirst().first)
        let store = PullRequestDetailsStore()
        store.itemsChanged(items)
        store.show(first)
        store.detailsFillPage = true
        store.open(file: "src/Retry.cs")
        store.fillsPage = true
        store.closeFile()
        store.open(page: try #require(ItemRef.session(fixing)))
        store.show(second)
        #expect(store.detailsFillPage && store.fillsPage)
        store.showList()
        #expect(!store.detailsFillPage && !store.fillsPage)
        store.detailsFillPage = true
        store.close()
        #expect(!store.detailsFillPage && !store.fillsPage)
    }

    /// A file's page that you made fill the page fills it under the details, whose own Fill the Page doesn't take its place
    /// (`fillsDetailsPage`), and either fills it alone. Drawn in a window off screen, beside a list.
    @Test func aFilesPageFillsThePageUnderTheDetailsOwnFillThePage() async throws {
        _ = NSApplication.shared
        let cases: [(file: Bool, details: Bool, room: DetailsRoom)] = [(true, false, .fillingPage), (false, true, .fillingPage), (false, false, .beside)]
        for (file, details, room) in cases {
            let seen = SeenRoom()
            let split = DetailsSplit(showsDetails: true, preferredWidth: .constant(nil)) {
                Color.clear
            } details: {
                VStack {
                    RoomProbe(seen: seen)
                    // As a file's page asks, once you click its ⤢.
                    Color.clear.frame(height: 10).preference(key: DetailsFillsPageKey.self, value: file)
                }
                // As a pull request's details do, with Fill the Page or without.
                .fillsDetailsPage(details)
            }
            .frame(width: 1_200, height: 700)
            let host = NSHostingView(rootView: split)
            let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1_200, height: 700), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            let deadline = ContinuousClock.now.advanced(by: waitLimit)
            while seen.room != room, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            #expect(seen.room == room, "with a file's page asking: \(file); with Fill the Page: \(details)")
        }
    }
}

/// Where `DetailsSplit` put the details, as a view in them sees it.
@MainActor private final class SeenRoom {
    var room: DetailsRoom?
}

private struct RoomProbe: View {
    let seen: SeenRoom
    @Environment(\.detailsRoom) private var room

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { seen.room = room }
            .onChange(of: room) { _, now in seen.room = now }
    }
}
