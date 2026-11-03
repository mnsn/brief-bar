import AzureDevOpsCore
import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsUI

/// The code of a pull request's comment threads, read as each comes on screen in its details, called off as it leaves,
/// and forgotten with the pull request: with a stand-in reader, never Azure DevOps.
@MainActor
@Suite struct PullRequestCodeStoreTests {
    /// Answers as a test says: at once, or once let go, with code or a problem; and counts what it's asked.
    actor Reader: ThreadCodeReader {
        var asked: [Int] = []
        /// The commits the pull request was at, as each was asked.
        var heads: [String?] = []
        var answers: [Int: Result<ThreadExcerpt, ThreadExcerpt.Problem>] = [:]
        /// Hold every answer until it's let go.
        var holds = false
        private var held: [Int: [CheckedContinuation<Void, Never>]] = [:]

        func excerpt(
            of thread: ReviewThread, in pullRequest: PullRequest, context: Int
        ) async -> Result<ThreadExcerpt, ThreadExcerpt.Problem> {
            asked.append(thread.id)
            heads.append(pullRequest.sourceCommit)
            if holds {
                await withCheckedContinuation { held[thread.id, default: []].append($0) }
            }
            return answers[thread.id] ?? .success(PullRequestCodeStoreTests.excerpt(thread.id, head: pullRequest.sourceCommit))
        }

        func answer(_ id: Int, _ result: Result<ThreadExcerpt, ThreadExcerpt.Problem>) {
            answers[id] = result
        }

        func hold(_ holds: Bool) {
            self.holds = holds
        }

        /// Lets the answers held for a thread go.
        func release(_ id: Int) {
            for turn in held.removeValue(forKey: id) ?? [] { turn.resume() }
        }

        func isHolding(_ id: Int) -> Bool {
            !(held[id] ?? []).isEmpty
        }
    }

    /// Code for a thread, saying which version of the pull request it was read at.
    nonisolated static func excerpt(_ id: Int, head: String?) -> ThreadExcerpt {
        ThreadExcerpt(
            threadId: id, path: "/src/Cart.cs", side: .right,
            lines: [.init(kind: .added, text: "let total = \(head ?? "?")", oldNumber: nil, newNumber: 12, isCommented: true)],
            reachesStart: false, reachesEnd: false, iteration: 1, latestIteration: 1
        )
    }

    private let pullRequest = PullRequest(
        key: PRKey("contoso", 7), title: "Fix the checkout total", author: Person(id: "a", name: "Alex Kim"), createdAt: Date(),
        projectId: "p1", projectName: "Shop", repositoryId: "r1", repositoryName: "shop-web", sourceCommit: "c1", targetCommit: "t1"
    )
    private let onLine = ReviewThread(id: 11, filePath: "/src/Cart.cs", line: 12, comments: [])
    private let onOther = ReviewThread(id: 12, filePath: "/src/Cart.cs", line: 40, comments: [])
    private let onPullRequest = ReviewThread(id: 13, comments: [])
    private let onFile = ReviewThread(id: 14, filePath: "/src/Cart.cs", comments: [], location: .init(path: "/src/Cart.cs"))

    private var key: PRKey { pullRequest.key }
    /// The view that shows the threads, as each tells the store, and the page it's on: the Pull Requests page of a window.
    private let viewer = UUID()
    private let page = PullRequestCodeStore.page(.azureDevOpsPullRequests, window: "1")

    /// A store a window shows, with the pull request held, as its details hold it.
    private func makeStore(_ reader: Reader, now: @escaping () -> Date = Date.init) -> PullRequestCodeStore {
        let store = PullRequestCodeStore(now: now) { _ in reader }
        store.setVisible(true, for: page)
        _ = store.hold(pullRequest.key)
        return store
    }

    /// Waits for the store's reads, which finish on the main actor between this test's awaits.
    private func settle(until done: () async -> Bool) async throws {
        for _ in 0..<150 {
            if await done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits for what the store and the reader do, for as long as a busy machine could need (`waitLimit`), failing the test
    /// if it doesn't happen.
    private func waitFor(_ done: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while await !done() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isRead(_ store: PullRequestCodeStore, _ id: Int) -> Bool {
        if case .read? = store.state(of: id, in: key) { return true }
        return false
    }

    @Test func aThreadsCodeIsReadOnceItsOnScreen() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        #expect(store.state(of: onLine.id, in: key) == nil)
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        #expect(store.state(of: onLine.id, in: key) == .reading)
        try await settle { isRead(store, onLine.id) }
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c1")))
        // On screen again, or still: it's read already.
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        store.hide(onLine.id, of: key, by: viewer)
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.asked == [11])
        #expect(isRead(store, onLine.id))

        // Nothing's read for a thread on the pull request or on a whole file, or of a pull request nothing shows.
        store.show(onPullRequest, of: pullRequest, by: viewer, on: page)
        store.show(onFile, of: pullRequest, by: viewer, on: page)
        var other = pullRequest
        other.key = PRKey("contoso", 8)
        store.show(onOther, of: other, by: viewer, on: page)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.asked == [11])
        #expect(store.state(of: onPullRequest.id, in: key) == nil && store.state(of: onFile.id, in: key) == nil && store.state(of: onOther.id, in: key) == nil)
    }

    @Test func aThreadThatLeavesTheScreenBeforeItsReadIsCalledOff() async throws {
        let reader = Reader()
        await reader.hold(true)
        let store = makeStore(reader)
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await settle { await reader.isHolding(onLine.id) }
        store.hide(onLine.id, of: key, by: viewer)
        #expect(store.state(of: onLine.id, in: key) == nil)
        // Its answer, once it comes, shows nothing.
        await reader.release(onLine.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.state(of: onLine.id, in: key) == nil)
        // Back on screen, it's read again.
        await reader.hold(false)
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await settle { isRead(store, onLine.id) }
        #expect(await reader.asked == [11, 11])
    }

    @Test func afterAPushItsReadAgainShowingTheOldCodeMeanwhile() async throws {
        let reader = Reader()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(reader) { now }
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await settle { isRead(store, onLine.id) }
        await reader.hold(true)
        var pushed = pullRequest
        pushed.sourceCommit = "c2"
        store.show(onLine, of: pushed, by: viewer, on: page)
        // The code it showed stays until the new one is read.
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c1")))
        try await settle { await reader.isHolding(onLine.id) }
        await reader.release(onLine.id)
        try await settle { store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c2")) }
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c2")))
        #expect(await reader.heads == ["c1", "c2"])

        // Offline after another push: the code it showed stays rather than the failure, and it's read again half a
        // minute later.
        await reader.hold(false)
        await reader.answer(onLine.id, .failure(.unreadable(.offline)))
        pushed.sourceCommit = "c3"
        store.show(onLine, of: pushed, by: viewer, on: page)
        try await settle { await reader.asked.count == 3 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c2")))
        store.show(onLine, of: pushed, by: viewer, on: page)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 3)
        now += PullRequestCodeStore.retryInterval
        await reader.answer(onLine.id, .success(Self.excerpt(onLine.id, head: "c3")))
        store.show(onLine, of: pushed, by: viewer, on: page)
        try await settle { store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c3")) }
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c3")))
        // Read, it's not read again.
        now += PullRequestCodeStore.retryInterval
        store.show(onLine, of: pushed, by: viewer, on: page)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 4)
    }

    @Test func codeThatCouldntBeReadIsReadAgainOnlyWhenThatMayHelp() async throws {
        let reader = Reader()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(reader) { now }
        await reader.answer(onLine.id, .failure(.unreadable(.offline)))
        await reader.answer(onOther.id, .failure(.binary))
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        store.show(onOther, of: pullRequest, by: viewer, on: page)
        try await settle { store.state(of: onLine.id, in: key) == .failed(.unreadable(.offline)) && store.state(of: onOther.id, in: key) == .failed(.binary) }
        #expect(store.state(of: onLine.id, in: key) == .failed(.unreadable(.offline)))

        // Back on screen a moment later: not yet.
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        store.show(onOther, of: pullRequest, by: viewer, on: page)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 2)
        // Half a minute later, offline is worth another try; a file that isn't text never is.
        now += PullRequestCodeStore.retryInterval
        await reader.answer(onLine.id, .success(Self.excerpt(onLine.id, head: "c1")))
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        store.show(onOther, of: pullRequest, by: viewer, on: page)
        try await settle { isRead(store, onLine.id) }
        #expect(await reader.asked.sorted() == [11, 11, 12])
        #expect(store.state(of: onOther.id, in: key) == .failed(.binary))

        // Not even when asked.
        store.show(onOther, of: pullRequest, by: viewer, on: page, again: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 3)

        // Asked to, it tries again at once what may pass.
        var other = ReviewThread(id: 15, filePath: "/src/Cart.cs", line: 60, comments: [])
        await reader.answer(other.id, .failure(.unreadable(.http(503))))
        store.show(other, of: pullRequest, by: viewer, on: page)
        try await settle { store.state(of: other.id, in: key) == .failed(.unreadable(.http(503))) }
        await reader.answer(other.id, .success(Self.excerpt(other.id, head: "c1")))
        store.show(other, of: pullRequest, by: viewer, on: page, again: true)
        try await settle { isRead(store, other.id) }
        #expect(isRead(store, other.id))
        // Moved to other lines, a thread is read again.
        other.line = 61
        store.show(other, of: pullRequest, by: viewer, on: page)
        try await settle { await reader.asked.filter { $0 == 15 }.count == 3 }
        #expect(await reader.asked.filter { $0 == 15 }.count == 3)
    }

    /// Whether the code changed since the comment couldn't be read, as when Azure DevOps couldn't be reached for it: the
    /// code shows, and it's read again half a minute later, until that's known.
    @Test func codeThatMayHaveChangedSinceIsReadAgainForThat() async throws {
        let reader = Reader()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(reader) { now }
        var unknown = Self.excerpt(onLine.id, head: "c1")
        unknown.latestIteration = 2
        unknown.changedSince = nil
        await reader.answer(onLine.id, .success(unknown))
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await settle { store.state(of: onLine.id, in: key) == .read(unknown) }
        #expect(store.state(of: onLine.id, in: key) == .read(unknown))
        // Back on screen a moment later: not yet.
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 1)
        // Half a minute later, it's read again, and now it's known.
        var known = unknown
        known.changedSince = true
        await reader.answer(onLine.id, .success(known))
        now += PullRequestCodeStore.retryInterval
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await settle { store.state(of: onLine.id, in: key) == .read(known) }
        #expect(store.state(of: onLine.id, in: key) == .read(known))
        // Known, it isn't read again.
        now += PullRequestCodeStore.retryInterval
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 2)
    }

    /// Two views show the same thread, as the same pull request's details in two windows: one leaving the screen while its
    /// code is read leaves the read to the other, and it's called off only once neither shows it.
    @Test func aReadIsCalledOffOnlyOnceNoViewShowsIt() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        let first = UUID()
        let second = UUID()
        await reader.hold(true)
        store.show(onLine, of: pullRequest, by: first, on: page)
        try await settle { await reader.isHolding(onLine.id) }
        store.show(onLine, of: pullRequest, by: second, on: page)
        // The first leaves: the second still waits on it, and gets it.
        store.hide(onLine.id, of: key, by: first)
        #expect(store.state(of: onLine.id, in: key) == .reading)
        await reader.release(onLine.id)
        try await settle { isRead(store, onLine.id) }
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c1")))
        #expect(await reader.asked == [11])

        // Both leave while it's read again after a push: that's called off, and the code it showed stays.
        var pushed = pullRequest
        pushed.sourceCommit = "c2"
        store.show(onLine, of: pushed, by: first, on: page)
        store.show(onLine, of: pushed, by: second, on: page)
        try await settle { await reader.isHolding(onLine.id) }
        store.hide(onLine.id, of: key, by: first)
        store.hide(onLine.id, of: key, by: second)
        await reader.release(onLine.id)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c1")))
        // Back on screen, it's read again.
        await reader.hold(false)
        store.show(onLine, of: pushed, by: second, on: page)
        try await settle { store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c2")) }
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c2")))
    }

    /// A thread whose file's path changed only in how a letter is written, as "é" in one character and in two, is on
    /// another file to Git: its code is read again.
    @Test func aThreadOnAnotherSpellingOfItsPathIsReadAgain() async throws {
        let composed = "/src/caf\u{E9}.cs"
        let decomposed = "/src/cafe\u{301}.cs"
        #expect(composed == decomposed)
        let before = ReviewThread(id: 11, filePath: composed, line: 12, comments: [], location: .init(
            path: composed, right: .init(lines: 12...12), madeOn: .init(base: 1),
            tracking: .init(to: .init(first: 1, second: 2), originalPath: composed, originalRight: .init(lines: 12...12))
        ))
        var after = before
        after.filePath = decomposed
        #expect(PullRequestCodeStore.Ask(before, pullRequest) == PullRequestCodeStore.Ask(before, pullRequest))
        #expect(PullRequestCodeStore.Ask(before, pullRequest) != PullRequestCodeStore.Ask(after, pullRequest))
        var moved = before
        moved.location?.path = decomposed
        #expect(PullRequestCodeStore.Ask(before, pullRequest) != PullRequestCodeStore.Ask(moved, pullRequest))
        var renamed = before
        renamed.location?.tracking?.originalPath = decomposed
        #expect(PullRequestCodeStore.Ask(before, pullRequest) != PullRequestCodeStore.Ask(renamed, pullRequest))
        var retargeted = pullRequest
        retargeted.targetBranch = "caf\u{E9}"
        var other = pullRequest
        other.targetBranch = "cafe\u{301}"
        #expect(PullRequestCodeStore.Ask(before, retargeted) != PullRequestCodeStore.Ask(before, other))

        let reader = Reader()
        let store = makeStore(reader)
        store.show(before, of: pullRequest, by: viewer, on: page)
        try await settle { isRead(store, before.id) }
        store.show(after, of: pullRequest, by: viewer, on: page)
        try await settle { await reader.asked.count == 2 }
        #expect(await reader.asked == [11, 11])
    }

    /// What nothing shows anymore is forgotten, and what's being read of it called off; what something still shows stays.
    @Test func whatNothingShowsAnymoreIsForgotten() async throws {
        let reader = Reader()
        let store = PullRequestCodeStore { _ in reader }
        store.setVisible(true, for: page)
        let first = store.hold(key)
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await settle { isRead(store, onLine.id) }
        await reader.hold(true)
        store.show(onOther, of: pullRequest, by: viewer, on: page)
        try await settle { await reader.isHolding(onOther.id) }

        // Another view shows it too: it stays when the first lets go, and goes once both have.
        let second = store.hold(key)
        store.release(first)
        #expect(store.shows(key) && isRead(store, onLine.id))
        store.release(second)
        #expect(!store.shows(key))
        #expect(store.states.isEmpty)
        // What was being read shows nothing once it comes.
        await reader.release(onOther.id)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.states.isEmpty)
        // Letting go twice changes nothing.
        store.release(second)
        // Held again, it's read again.
        await reader.hold(false)
        let again = store.hold(key)
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await settle { isRead(store, onLine.id) }
        #expect(await reader.asked.filter { $0 == onLine.id }.count == 2)
        store.release(again)
        store.stop()
        #expect(store.states.isEmpty && !store.isVisible(page))
    }

    /// The panel's details: their pull request's code is kept while they show it, pages over them included, and goes
    /// once they show another one, unless something else holds it.
    @Test func itFollowsThePullRequestThePanelShows() async throws {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let items = DemoData.records(now: now).compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), dismissedCutoff: seen.dismissedCutoff(for: $0.id), now: now)
        }
        let first = try #require(items.first { $0.key.number == 4102 })
        let second = try #require(items.first { $0.key.number == 4088 })
        let details = PullRequestDetailsStore()
        details.itemsChanged(items)
        let store = PullRequestCodeStore { _ in Reader() }
        store.follow(details)
        #expect(!store.shows(first.key))
        details.show(first)
        #expect(store.shows(first.key))
        // A page over them doesn't let it go.
        details.open(page: .workItem(organization: DemoData.organization, id: 5160))
        #expect(store.shows(first.key))
        // Held by a page of it elsewhere, it stays once the panel shows another one.
        let page = store.hold(first.key)
        details.show(second, at: .thread(43))
        #expect(store.shows(first.key) && store.shows(second.key))
        store.release(page)
        #expect(!store.shows(first.key))
        details.close()
        #expect(!store.shows(second.key))
    }

    /// The details move from one pull request to another, the first fading away: its thread with the same ID, as Azure
    /// DevOps numbers each pull request's threads from 1, neither calls off the next one's read nor shows its code.
    @Test func aThreadOfThePullRequestBeforeLeavesTheNextOnesAlone() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        var next = pullRequest
        next.key = PRKey("contoso", 8)
        let fading = store.hold(key)
        let shown = store.hold(next.key)
        await reader.hold(true)
        store.show(onLine, of: next, by: viewer, on: page)
        try await settle { await reader.isHolding(onLine.id) }
        // The first one's thread 11 goes as it fades away.
        store.hide(onLine.id, of: key, by: viewer)
        #expect(store.state(of: onLine.id, in: next.key) == .reading)
        #expect(store.state(of: onLine.id, in: key) == nil)
        store.release(fading)
        await reader.release(onLine.id)
        try await settle { store.state(of: onLine.id, in: next.key) == .read(Self.excerpt(onLine.id, head: "c1")) }
        #expect(store.state(of: onLine.id, in: next.key) == .read(Self.excerpt(onLine.id, head: "c1")))
        #expect(store.state(of: onLine.id, in: key) == nil)
        store.release(shown)
    }

    /// A thread's code is read only while the window it's in shows its page on screen: minimized, hidden or covered, what
    /// was being read for it is called off, to be read once the window shows it again.
    @Test func nothingIsReadWhileItsWindowDoesntShowIt() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        let changes = store.visibilityChanges
        await reader.hold(true)
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await settle { await reader.isHolding(onLine.id) }
        // Minimized: the read under way is called off, and nothing else is read.
        store.setVisible(false, for: page)
        #expect(!store.isVisible(page) && store.visibilityChanges == changes + 1)
        #expect(store.state(of: onLine.id, in: key) == nil)
        store.show(onOther, of: pullRequest, by: viewer, on: page)
        #expect(store.state(of: onOther.id, in: key) == nil)
        await reader.release(onLine.id)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.state(of: onLine.id, in: key) == nil)
        #expect(await reader.asked == [11])
        // Told again that it doesn't show, or of a page that never showed: nothing changes.
        store.setVisible(false, for: page)
        store.setVisible(false, for: PullRequestCodeStore.page(.azureDevOpsSprint, window: "1"))
        #expect(store.visibilityChanges == changes + 1)
        // Nothing outside a window's page is read.
        store.show(onLine, of: pullRequest, by: viewer, on: nil)
        #expect(store.state(of: onLine.id, in: key) == nil)
        // Shown again: what each thread asks for is read.
        await reader.hold(false)
        store.setVisible(true, for: page)
        #expect(store.isVisible(page) && store.visibilityChanges == changes + 2)
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        try await settle { isRead(store, onLine.id) }
        #expect(isRead(store, onLine.id))
    }

    /// One window's Pull Requests page is minimized while another window shows its Sprint page: the minimized one's threads
    /// ask for nothing, though a window shows a page where pull requests' details can show; and the same thread on the
    /// other window's page, such as the same pull request's page over a work item's details, goes on being read.
    @Test func aWindowThatHidesTakesOnlyItsOwnThreadsAway() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        let sprint = PullRequestCodeStore.page(.azureDevOpsSprint, window: "2")
        store.setVisible(true, for: sprint)
        let onSprint = UUID()
        await reader.hold(true)
        // Thread 11 on both windows' pages, thread 12 only on the Pull Requests page.
        store.show(onLine, of: pullRequest, by: viewer, on: page)
        store.show(onLine, of: pullRequest, by: onSprint, on: sprint)
        store.show(onOther, of: pullRequest, by: viewer, on: page)
        try await settle {
            let line = await reader.isHolding(onLine.id)
            let other = await reader.isHolding(onOther.id)
            return line && other
        }

        // The Pull Requests window is minimized: thread 12's read is called off; thread 11's goes on for the other window.
        store.setVisible(false, for: page)
        #expect(store.isVisible(sprint) && !store.isVisible(page))
        #expect(store.state(of: onOther.id, in: key) == nil)
        #expect(store.state(of: onLine.id, in: key) == .reading)
        await reader.release(onOther.id)
        await reader.release(onLine.id)
        try await settle { isRead(store, onLine.id) }
        #expect(isRead(store, onLine.id))
        #expect(store.state(of: onOther.id, in: key) == nil)

        // A push while it's minimized: its threads ask again, but nothing is read for them.
        await reader.hold(false)
        var pushed = pullRequest
        pushed.sourceCommit = "c2"
        store.show(onOther, of: pushed, by: viewer, on: page)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.filter { $0 == onOther.id }.count == 1)
        #expect(store.state(of: onOther.id, in: key) == nil)
        // The other window's thread is read again after the push, as it shows it.
        store.show(onLine, of: pushed, by: onSprint, on: sprint)
        try await settle { store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c2")) }
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c2")))

        // Shown again, the Pull Requests window's threads are read.
        store.setVisible(true, for: page)
        store.show(onOther, of: pushed, by: viewer, on: page)
        try await settle { isRead(store, onOther.id) }
        #expect(store.state(of: onOther.id, in: key) == .read(Self.excerpt(onOther.id, head: "c2")))
    }

    @Test func forRenderingAllTheirCodeIsRead() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        await reader.answer(onOther.id, .failure(.tooLarge))
        await store.readAll([onLine, onOther, onPullRequest, onFile], of: pullRequest)
        #expect(isRead(store, onLine.id))
        #expect(store.state(of: onOther.id, in: key) == .failed(.tooLarge))
        #expect(store.state(of: onPullRequest.id, in: key) == nil && store.state(of: onFile.id, in: key) == nil)
        #expect(await reader.asked == [11, 12])
        // Not for a pull request nothing holds.
        var other = pullRequest
        other.key = PRKey("contoso", 8)
        await store.readAll([onLine], of: other)
        #expect(await reader.asked == [11, 12])
    }

    /// For a prompt about a thread whose code doesn't show, as from a composer on its file's page: it's read as a thread on
    /// screen is, by the composer, and kept, and read again after a push; what's read is used.
    @Test func aPromptsCodeIsReadAsAThreadOnScreenIs() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        let composer = UUID()
        #expect(await store.excerpt(of: onLine, in: pullRequest, by: composer, on: page) == Self.excerpt(onLine.id, head: "c1"))
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c1")))
        // Read, it isn't read again.
        #expect(await store.excerpt(of: onLine, in: pullRequest, by: composer, on: page) == Self.excerpt(onLine.id, head: "c1"))
        #expect(await reader.asked == [11])
        // After a push, it is.
        var pushed = pullRequest
        pushed.sourceCommit = "c2"
        #expect(await store.excerpt(of: onLine, in: pushed, by: composer, on: page) == Self.excerpt(onLine.id, head: "c2"))
        #expect(await reader.asked == [11, 11])
        // Nothing for one that isn't on lines, can't be read, or whose pull request nothing shows.
        await reader.answer(onOther.id, .failure(.tooLarge))
        #expect(await store.excerpt(of: onFile, in: pullRequest, by: composer, on: page) == nil)
        #expect(await store.excerpt(of: onOther, in: pullRequest, by: composer, on: page) == nil)
        #expect(store.state(of: onOther.id, in: key) == .failed(.tooLarge))
        var other = pullRequest
        other.key = PRKey("contoso", 8)
        #expect(await store.excerpt(of: onLine, in: other, by: composer, on: page) == nil)
        #expect(await reader.asked == [11, 11, 12])
        // While its window doesn't show it on screen, nothing's read, and what was read is used.
        store.setVisible(false, for: page)
        let onNext = ReviewThread(id: 15, filePath: "/src/Cart.cs", line: 60, comments: [])
        #expect(await store.excerpt(of: onNext, in: pushed, by: composer, on: page) == nil)
        #expect(await store.excerpt(of: onLine, in: pushed, by: composer, on: page) == Self.excerpt(onLine.id, head: "c2"))
        #expect(await store.excerpt(of: onNext, in: pushed, by: composer, on: nil) == nil)
        #expect(await reader.asked == [11, 11, 12])
    }

    /// A prompt's read is called off as its window hides, as a thread's on screen is, and the prompt goes without the
    /// code; it's read again once the window shows.
    @Test func aPromptsReadIsCalledOffAsItsWindowHides() async throws {
        let reader = Reader()
        await reader.hold(true)
        let store = makeStore(reader)
        let composer = UUID()
        let asking = Task { await store.excerpt(of: onLine, in: pullRequest, by: composer, on: page) }
        try await waitFor { await reader.isHolding(onLine.id) }
        store.setVisible(false, for: page)
        #expect(store.state(of: onLine.id, in: key) == nil)
        await reader.release(onLine.id)
        #expect(await asking.value == nil)
        #expect(store.state(of: onLine.id, in: key) == nil)
        // Shown again, it's read.
        await reader.hold(false)
        store.setVisible(true, for: page)
        #expect(await store.excerpt(of: onLine, in: pullRequest, by: composer, on: page) == Self.excerpt(onLine.id, head: "c1"))
        #expect(await reader.asked == [11, 11])
        // Once the composer lets go, and nothing else shows the thread, a read after a push is called off.
        await reader.hold(true)
        var pushed = pullRequest
        pushed.sourceCommit = "c2"
        store.show(onLine, of: pushed, by: composer, on: page)
        try await waitFor { await reader.isHolding(onLine.id) }
        store.hide(onLine.id, of: key, by: composer)
        await reader.release(onLine.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c1")))
    }

    /// A prompt waits for the read under way, whichever view asked for it, as when a push started one in its place, and
    /// gets what that one read.
    @Test func aPromptsCodeIsTheLatestReadOfIt() async throws {
        let reader = Reader()
        await reader.hold(true)
        let store = makeStore(reader)
        let asking = Task { await store.excerpt(of: onLine, in: pullRequest, by: UUID(), on: page) }
        try await waitFor { await reader.isHolding(onLine.id) }
        var pushed = pullRequest
        pushed.sourceCommit = "c2"
        store.show(onLine, of: pushed, by: viewer, on: page)
        try await waitFor { await reader.asked.count == 2 }
        await reader.release(onLine.id)
        #expect(await asking.value == Self.excerpt(onLine.id, head: "c2"))
        #expect(store.state(of: onLine.id, in: key) == .read(Self.excerpt(onLine.id, head: "c2")))
    }
}
