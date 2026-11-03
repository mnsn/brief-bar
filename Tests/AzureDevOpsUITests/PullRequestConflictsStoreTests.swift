import AzureDevOpsCore
import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsUI

/// A pull request's merge conflicts, for its details: read once as they show, while a window shows them on screen, again
/// once either branch moves, called off as the window hides, and forgotten with the pull request. With a stand-in reader,
/// never Azure DevOps.
@MainActor
@Suite struct PullRequestConflictsStoreTests {
    /// Answers as a test says, at once or once let go, and counts what it's asked.
    actor Reader {
        var asked: [String] = []
        var holds = false
        var error: ADOError?
        private var held: [CheckedContinuation<Void, Never>] = []

        func read(_ pullRequest: PullRequest) async throws -> MergeConflicts {
            asked.append("\(pullRequest.key.number) \(pullRequest.sourceCommit ?? "?") \(pullRequest.targetCommit ?? "?")")
            if holds { await withCheckedContinuation { held.append($0) } }
            if let error { throw error }
            return MergeConflicts(files: [
                MergeConflict(id: 1, path: "/src/\(pullRequest.sourceCommit ?? "?").cs", kind: .editEdit),
            ], of: pullRequest)
        }

        func hold(_ holds: Bool) {
            self.holds = holds
        }

        var isHolding: Bool { !held.isEmpty }

        func release() {
            for turn in held { turn.resume() }
            held = []
        }

        func fail(_ error: ADOError?) {
            self.error = error
        }
    }

    private let pullRequest = PullRequest(
        key: PRKey("contoso", 7), title: "Rename the order status enum", author: Person(id: "a", name: "Robin Diaz"), createdAt: Date(),
        projectId: "p1", projectName: "Shop", repositoryId: "r1", repositoryName: "shop-web", mergeStatus: "conflicts",
        sourceCommit: "c1", targetCommit: "t1"
    )
    private var key: PRKey { pullRequest.key }
    /// The window's page the details are on.
    private let page = PullRequestCodeStore.page(.azureDevOpsPullRequests, window: "1")

    /// A store whose code store a window shows, with the pull request held, as its details hold it.
    private func makeStores(
        _ reader: Reader, now: @escaping () -> Date = Date.init
    ) -> (conflicts: PullRequestConflictsStore, code: PullRequestCodeStore, hold: Int) {
        let code = PullRequestCodeStore(now: now) { _ in StubCode() }
        code.setVisible(true, for: page)
        let hold = code.hold(key)
        return (PullRequestConflictsStore(code: code, now: now) { try await reader.read($0) }, code, hold)
    }

    /// Reads no code: the conflicts' tests don't ask for any.
    private struct StubCode: ThreadCodeReader {
        func excerpt(of thread: ReviewThread, in pullRequest: PullRequest, context: Int) async -> Result<ThreadExcerpt, ThreadExcerpt.Problem> {
            .failure(.notOnLines)
        }
    }

    /// Waits for the store's reads, which finish on the main actor between this test's awaits, for at most a minute, as
    /// `make test` runs every test on one thread.
    private func settle(until done: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if await done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let isDone = await done()
        try #require(isDone, "Timed out waiting for the store", sourceLocation: sourceLocation)
    }

    private func read(_ store: PullRequestConflictsStore, _ key: PRKey? = nil) -> MergeConflicts? {
        if case .read(let conflicts)? = store.state(of: key ?? self.key) { return conflicts }
        return nil
    }

    @Test func readsThemOnceAsTheyShowAndOnlyThen() async throws {
        let reader = Reader()
        let (store, code, hold) = makeStores(reader)
        #expect(store.state(of: key) == nil)
        store.show(pullRequest, on: page)
        #expect(store.state(of: key) == .reading)
        try await settle { read(store) != nil }
        #expect(read(store)?.files.map(\.path) == ["/src/c1.cs"])
        // Shown again, or in another window: read already.
        store.show(pullRequest, on: page)
        store.show(pullRequest, on: PullRequestCodeStore.page(.azureDevOpsPullRequests, window: "2"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked == ["7 c1 t1"])

        // Nothing for one that doesn't conflict, isn't open, or that nothing shows; nor outside a window, or while no window
        // shows the page.
        var merged = pullRequest
        merged.mergeStatus = "succeeded"
        store.show(merged, on: page)
        var abandoned = pullRequest
        abandoned.status = .abandoned
        store.show(abandoned, on: page)
        var other = pullRequest
        other.key = PRKey("contoso", 8)
        store.show(other, on: page)
        code.release(hold)
        let again = code.hold(key)
        store.show(pullRequest, on: nil)
        code.setVisible(false, for: page)
        store.show(pullRequest, on: page)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.asked == ["7 c1 t1"])
        #expect(store.state(of: other.key) == nil)
        code.release(again)
    }

    @Test func readsThemAgainOnceEitherBranchMoves() async throws {
        let reader = Reader()
        let (store, _, _) = makeStores(reader)
        store.show(pullRequest, on: page)
        try await settle { read(store) != nil }
        var pushed = pullRequest
        pushed.sourceCommit = "c2"
        // The ones read before a push aren't the pull request's any more: not for a prompt, and not on screen.
        #expect(store.conflicts(for: pushed) == nil)
        #expect(store.conflicts(for: pullRequest) != nil)
        await reader.hold(true)
        store.show(pushed, on: page)
        #expect(store.state(of: key) == .reading)
        try await settle { await reader.isHolding }
        await reader.release()
        try await settle { read(store)?.files.first?.path == "/src/c2.cs" }
        #expect(store.conflicts(for: pushed)?.files.first?.path == "/src/c2.cs")
        await reader.hold(false)
        var moved = pushed
        moved.targetCommit = "t2"
        store.show(moved, on: page)
        try await settle { await reader.asked.count == 3 }
        #expect(await reader.asked == ["7 c1 t1", "7 c2 t1", "7 c2 t2"])
    }

    /// Minimized, hidden or covered, a window doesn't read: what only it asked for is called off, and read once it shows
    /// them again.
    @Test func callsTheReadOffAsTheWindowHides() async throws {
        let reader = Reader()
        let (store, code, _) = makeStores(reader)
        await reader.hold(true)
        store.show(pullRequest, on: page)
        try await settle { await reader.isHolding }
        code.setVisible(false, for: page)
        #expect(store.state(of: key) == nil)
        await reader.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.state(of: key) == nil)
        await reader.hold(false)
        code.setVisible(true, for: page)
        store.show(pullRequest, on: page)
        try await settle { read(store) != nil }
        #expect(await reader.asked.count == 2)
    }

    @Test func forgetsThemOnceNothingShowsThePullRequest() async throws {
        let reader = Reader()
        let (store, code, hold) = makeStores(reader)
        store.show(pullRequest, on: page)
        try await settle { read(store) != nil }
        code.release(hold)
        #expect(store.state(of: key) == nil)
        #expect(store.conflicts(for: pullRequest) == nil)
    }

    @Test func readsAgainHalfAMinuteAfterAFailureThatMayPass() async throws {
        let reader = Reader()
        var now = Date()
        let (store, _, _) = makeStores(reader) { now }
        await reader.fail(.offline)
        store.show(pullRequest, on: page)
        try await settle { store.state(of: key) == .failed(.offline) }
        // At once, it waits; half a minute later, or when you ask, it's read again.
        await reader.fail(nil)
        store.show(pullRequest, on: page)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 1)
        now = now.addingTimeInterval(PullRequestCodeStore.retryInterval)
        store.show(pullRequest, on: page)
        try await settle { read(store) != nil }
        #expect(await reader.asked.count == 2)

        // One that won't pass isn't read again, unless either branch moves.
        let other = Reader()
        let (failing, _, _) = makeStores(other) { now }
        await other.fail(.notFound)
        failing.show(pullRequest, on: page)
        try await settle { failing.state(of: key) == .failed(.notFound) }
        now = now.addingTimeInterval(PullRequestCodeStore.retryInterval)
        failing.show(pullRequest, on: page, again: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await other.asked.count == 1)
        #expect(!PullRequestConflictsStore.mayPass(.notFound))
        #expect(!PullRequestConflictsStore.mayPass(.forbidden))
        #expect(PullRequestConflictsStore.mayPass(.offline))
        #expect(PullRequestConflictsStore.mayPass(.throttled(retryAfter: 10)))
    }

    @Test func forgetsThemWhenSomeoneElseSignsInAndReadsNothingOnceStopped() async throws {
        let reader = Reader()
        let (store, _, _) = makeStores(reader)
        store.accountChanged("robin@contoso.com")
        store.show(pullRequest, on: page)
        try await settle { read(store) != nil }
        store.accountChanged("robin@contoso.com")
        #expect(read(store) != nil)
        store.accountChanged("sam@contoso.com")
        #expect(store.state(of: key) == nil)
        store.stop()
        store.show(pullRequest, on: page)
        await store.readAll(of: pullRequest)
        #expect(store.state(of: key) == nil)
        #expect(await reader.asked.count == 1)
    }

    /// `--render` reads them for a pull request something holds, whether a window shows it or not.
    @Test func readsThemAllForPictures() async {
        let reader = Reader()
        let (store, code, _) = makeStores(reader)
        code.setVisible(false, for: page)
        await store.readAll(of: pullRequest)
        #expect(read(store)?.files.count == 1)
    }

    /// Resolve Conflicts lists the files its details read, in both places Copilot may work.
    @Test func resolveConflictsListsTheFilesRead() async {
        let record = PRRecord(pullRequest: pullRequest, role: .author, details: nil, me: "a")
        let conflicts = MergeConflicts(files: [MergeConflict(id: 1, path: "/src/Orders/OrderStatus.cs", kind: .editEdit)], of: pullRequest)
        let prompts = await PullRequestTasks.prompts(.resolveConflicts, for: record, client: nil, conflicts: conflicts)
        #expect(prompts.worktree.contains("1. src/Orders/OrderStatus.cs: changed on both branches"))
        #expect(prompts.session.contains("1. src/Orders/OrderStatus.cs: changed on both branches"))
        #expect(prompts.session.contains("merge it into your checkout"))
        let without = await PullRequestTasks.prompts(.resolveConflicts, for: record, client: nil)
        #expect(!without.worktree.contains("Azure DevOps lists"))
    }

    /// The demo's are made up: its pull request with conflicts has them, without a network.
    @Test func theDemoMakesThemUp() async throws {
        let code = PullRequestCodeStore(demo: true, client: ADOClient(tokens: NoTokens()))
        code.setVisible(true, for: page)
        let records = DemoData.records(now: Date())
        let conflicting = try #require(records.first { $0.pullRequest.hasConflicts }).pullRequest
        let hold = code.hold(conflicting.key)
        let store = PullRequestConflictsStore(code: code, demo: true, client: ADOClient(tokens: NoTokens()))
        store.show(conflicting, on: page)
        try await settle { read(store, conflicting.key) != nil }
        #expect(read(store, conflicting.key)?.files.count == 5)
        code.release(hold)
    }

    /// Never asked: the demo reads nothing.
    private struct NoTokens: AccessTokenProvider {
        func token(tenant: String?) async throws -> AccessToken {
            throw AuthError.signedOut("The demo reads nothing.")
        }

        func invalidate(tenant: String?) async {}
    }
}
