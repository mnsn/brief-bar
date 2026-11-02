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

    private func makeStore(_ reader: Reader, now: @escaping () -> Date = Date.init) -> PullRequestCodeStore {
        let store = PullRequestCodeStore(now: now) { _ in reader }
        store.use(pullRequest.key)
        return store
    }

    /// Waits for the store's reads, which finish on the main actor between this test's awaits.
    private func settle(until done: () async -> Bool) async throws {
        for _ in 0..<150 {
            if await done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isRead(_ store: PullRequestCodeStore, _ id: Int) -> Bool {
        if case .read? = store.state(of: id) { return true }
        return false
    }

    @Test func aThreadsCodeIsReadOnceItsOnScreen() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        #expect(store.state(of: onLine.id) == nil)
        store.show(onLine, of: pullRequest)
        #expect(store.state(of: onLine.id) == .reading)
        try await settle { isRead(store, onLine.id) }
        #expect(store.state(of: onLine.id) == .read(Self.excerpt(onLine.id, head: "c1")))
        // On screen again, or still: it's read already.
        store.show(onLine, of: pullRequest)
        store.hide(onLine.id)
        store.show(onLine, of: pullRequest)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.asked == [11])
        #expect(isRead(store, onLine.id))

        // Nothing's read for a thread on the pull request or on a whole file, or of another pull request.
        store.show(onPullRequest, of: pullRequest)
        store.show(onFile, of: pullRequest)
        var other = pullRequest
        other.key = PRKey("contoso", 8)
        store.show(onOther, of: other)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.asked == [11])
        #expect(store.state(of: onPullRequest.id) == nil && store.state(of: onFile.id) == nil && store.state(of: onOther.id) == nil)
    }

    @Test func aThreadThatLeavesTheScreenBeforeItsReadIsCalledOff() async throws {
        let reader = Reader()
        await reader.hold(true)
        let store = makeStore(reader)
        store.show(onLine, of: pullRequest)
        try await settle { await reader.isHolding(onLine.id) }
        store.hide(onLine.id)
        #expect(store.state(of: onLine.id) == nil)
        // Its answer, once it comes, shows nothing.
        await reader.release(onLine.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.state(of: onLine.id) == nil)
        // Back on screen, it's read again.
        await reader.hold(false)
        store.show(onLine, of: pullRequest)
        try await settle { isRead(store, onLine.id) }
        #expect(await reader.asked == [11, 11])
    }

    @Test func afterAPushItsReadAgainShowingTheOldCodeMeanwhile() async throws {
        let reader = Reader()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(reader) { now }
        store.show(onLine, of: pullRequest)
        try await settle { isRead(store, onLine.id) }
        await reader.hold(true)
        var pushed = pullRequest
        pushed.sourceCommit = "c2"
        store.show(onLine, of: pushed)
        // The code it showed stays until the new one is read.
        #expect(store.state(of: onLine.id) == .read(Self.excerpt(onLine.id, head: "c1")))
        try await settle { await reader.isHolding(onLine.id) }
        await reader.release(onLine.id)
        try await settle { store.state(of: onLine.id) == .read(Self.excerpt(onLine.id, head: "c2")) }
        #expect(store.state(of: onLine.id) == .read(Self.excerpt(onLine.id, head: "c2")))
        #expect(await reader.heads == ["c1", "c2"])

        // Offline after another push: the code it showed stays rather than the failure, and it's read again half a
        // minute later.
        await reader.hold(false)
        await reader.answer(onLine.id, .failure(.unreadable(.offline)))
        pushed.sourceCommit = "c3"
        store.show(onLine, of: pushed)
        try await settle { await reader.asked.count == 3 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.state(of: onLine.id) == .read(Self.excerpt(onLine.id, head: "c2")))
        store.show(onLine, of: pushed)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 3)
        now += PullRequestCodeStore.retryInterval
        await reader.answer(onLine.id, .success(Self.excerpt(onLine.id, head: "c3")))
        store.show(onLine, of: pushed)
        try await settle { store.state(of: onLine.id) == .read(Self.excerpt(onLine.id, head: "c3")) }
        #expect(store.state(of: onLine.id) == .read(Self.excerpt(onLine.id, head: "c3")))
        // Read, it's not read again.
        now += PullRequestCodeStore.retryInterval
        store.show(onLine, of: pushed)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 4)
    }

    @Test func codeThatCouldntBeReadIsReadAgainOnlyWhenThatMayHelp() async throws {
        let reader = Reader()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(reader) { now }
        await reader.answer(onLine.id, .failure(.unreadable(.offline)))
        await reader.answer(onOther.id, .failure(.binary))
        store.show(onLine, of: pullRequest)
        store.show(onOther, of: pullRequest)
        try await settle { store.state(of: onLine.id) == .failed(.unreadable(.offline)) && store.state(of: onOther.id) == .failed(.binary) }
        #expect(store.state(of: onLine.id) == .failed(.unreadable(.offline)))

        // Back on screen a moment later: not yet.
        store.show(onLine, of: pullRequest)
        store.show(onOther, of: pullRequest)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 2)
        // Half a minute later, offline is worth another try; a file that isn't text never is.
        now += PullRequestCodeStore.retryInterval
        await reader.answer(onLine.id, .success(Self.excerpt(onLine.id, head: "c1")))
        store.show(onLine, of: pullRequest)
        store.show(onOther, of: pullRequest)
        try await settle { isRead(store, onLine.id) }
        #expect(await reader.asked.sorted() == [11, 11, 12])
        #expect(store.state(of: onOther.id) == .failed(.binary))

        // Not even when asked.
        store.show(onOther, of: pullRequest, again: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 3)

        // Asked to, it tries again at once what may pass.
        var other = ReviewThread(id: 15, filePath: "/src/Cart.cs", line: 60, comments: [])
        await reader.answer(other.id, .failure(.unreadable(.http(503))))
        store.show(other, of: pullRequest)
        try await settle { store.state(of: other.id) == .failed(.unreadable(.http(503))) }
        await reader.answer(other.id, .success(Self.excerpt(other.id, head: "c1")))
        store.show(other, of: pullRequest, again: true)
        try await settle { isRead(store, other.id) }
        #expect(isRead(store, other.id))
        // Moved to other lines, a thread is read again.
        other.line = 61
        store.show(other, of: pullRequest)
        try await settle { await reader.asked.filter { $0 == 15 }.count == 3 }
        #expect(await reader.asked.filter { $0 == 15 }.count == 3)
    }

    @Test func anotherPullRequestForgetsWhatWasRead() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        store.show(onLine, of: pullRequest)
        try await settle { isRead(store, onLine.id) }
        await reader.hold(true)
        store.show(onOther, of: pullRequest)
        try await settle { await reader.isHolding(onOther.id) }

        store.use(PRKey("contoso", 8))
        #expect(store.key == PRKey("contoso", 8))
        #expect(store.states.isEmpty)
        await reader.release(onOther.id)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.states.isEmpty)
        // The same one again keeps what it read.
        store.use(pullRequest.key)
        await reader.hold(false)
        store.show(onLine, of: pullRequest)
        try await settle { isRead(store, onLine.id) }
        store.use(pullRequest.key)
        #expect(isRead(store, onLine.id))
        store.stop()
        #expect(store.key == nil && store.states.isEmpty)
    }

    /// It follows the details: what they show is what it reads.
    @Test func itReadsThePullRequestTheDetailsShow() throws {
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
        #expect(store.key == nil)
        details.show(first)
        #expect(store.key == first.key)
        details.show(second, at: .thread(43))
        #expect(store.key == second.key)
        details.close()
        #expect(store.key == nil)
    }

    @Test func forRenderingAllTheirCodeIsRead() async throws {
        let reader = Reader()
        let store = makeStore(reader)
        await reader.answer(onOther.id, .failure(.tooLarge))
        await store.readAll([onLine, onOther, onPullRequest, onFile], of: pullRequest)
        #expect(isRead(store, onLine.id))
        #expect(store.state(of: onOther.id) == .failed(.tooLarge))
        #expect(store.state(of: onPullRequest.id) == nil && store.state(of: onFile.id) == nil)
        #expect(await reader.asked == [11, 12])
    }
}
