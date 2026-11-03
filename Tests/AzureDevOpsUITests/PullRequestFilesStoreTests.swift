import AzureDevOpsCore
import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsUI

/// A pull request's whole change, for its Files: its files, read as they come on screen, each file's diff as its page shows
/// it, and each one's count as its row shows it, one file at a time; all called off as they leave, and forgotten with the
/// pull request. With a stand-in reader, never Azure DevOps.
@MainActor
@Suite struct PullRequestFilesStoreTests {
    /// Answers as a test says, at once or once let go, and counts what it's asked.
    actor Reader: ThreadCodeReader {
        var asked: [String] = []
        var holds = false
        var listProblem: ThreadExcerpt.Problem?
        var diffProblems: [String: ThreadExcerpt.Problem] = [:]
        private var held: [String: [CheckedContinuation<Void, Never>]] = [:]

        func excerpt(of thread: ReviewThread, in pullRequest: PullRequest, context: Int) async -> Result<ThreadExcerpt, ThreadExcerpt.Problem> {
            asked.append("excerpt \(thread.id)")
            return .success(PullRequestCodeStoreTests.excerpt(thread.id, head: pullRequest.sourceCommit))
        }

        func changedFiles(of pullRequest: PullRequest, scope: ChangeScope) async -> Result<ChangedFiles, ThreadExcerpt.Problem> {
            let name = "files \(pullRequest.sourceCommit ?? "?")"
            asked.append(name)
            await wait(name)
            if let listProblem { return .failure(listProblem) }
            return .success(PullRequestFilesStoreTests.files(head: pullRequest.sourceCommit))
        }

        func diff(of file: FileChange, in files: ChangedFiles, of pullRequest: PullRequest) async -> Result<FileDiff, ThreadExcerpt.Problem> {
            let name = "diff \(file.name)"
            asked.append(name)
            await wait(name)
            if let problem = diffProblems[file.name] { return .failure(problem) }
            return .success(FileDiff(file: file, lines: [
                DiffLine(.removed, "old", old: 1, new: nil), DiffLine(.added, "new", old: nil, new: 1),
                DiffLine(.added, file.name, old: nil, new: 2),
            ]))
        }

        private func wait(_ name: String) async {
            guard holds else { return }
            await withCheckedContinuation { held[name, default: []].append($0) }
        }

        func hold(_ holds: Bool) {
            self.holds = holds
        }

        func release(_ name: String) {
            for turn in held.removeValue(forKey: name) ?? [] { turn.resume() }
        }

        func isHolding(_ name: String) -> Bool {
            !(held[name] ?? []).isEmpty
        }

        func failList(_ problem: ThreadExcerpt.Problem?) {
            listProblem = problem
        }

        func failDiff(_ name: String, _ problem: ThreadExcerpt.Problem?) {
            diffProblems[name] = problem
        }
    }

    /// Five files, at the pull request's head.
    nonisolated static func files(head: String?) -> ChangedFiles {
        ChangedFiles(
            scope: .whole, comparison: ReviewThread.Comparison(base: 2),
            iterations: [PRIteration(id: 1, sourceCommit: "c0", commonCommit: "b"), PRIteration(id: 2, sourceCommit: head, commonCommit: "b")],
            files: ["A", "B", "C", "D", "E"].map { name in
                FileChange(path: "/src/\(name).cs", kind: .edit, objectId: "\(name)-\(head ?? "?")", originalObjectId: "\(name)-0")
            }
        )
    }

    private let pullRequest = PullRequest(
        key: PRKey("contoso", 7), title: "Fix the checkout total", author: Person(id: "a", name: "Alex Kim"), createdAt: Date(),
        projectId: "p1", projectName: "Shop", repositoryId: "r1", repositoryName: "shop-web", sourceCommit: "c1", targetCommit: "t1"
    )
    private var key: PRKey { pullRequest.key }
    private let viewer = UUID()

    /// A store whose code store a window shows, with the pull request held, as its details hold it; and how many readers
    /// were made.
    private func makeStores(
        _ reader: Reader, now: @escaping () -> Date = Date.init
    ) -> (files: PullRequestFilesStore, code: PullRequestCodeStore, hold: Int, made: () -> Int) {
        var made = 0
        let code = PullRequestCodeStore(now: now) { _ in
            made += 1
            return reader
        }
        code.setVisible(true, for: "window.1")
        let hold = code.hold(key)
        return (PullRequestFilesStore(code: code, now: now), code, hold, { made })
    }

    private func settle(until done: () async -> Bool) async throws {
        for _ in 0..<150 {
            if await done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func readFiles(_ store: PullRequestFilesStore) -> ChangedFiles? {
        if case .read(let files)? = store.list(of: key, .whole) { return files }
        return nil
    }

    @Test func readsTheFilesOnceTheyShowAndOnlyThen() async throws {
        let reader = Reader()
        let (store, code, hold, made) = makeStores(reader)
        #expect(store.list(of: key, .whole) == nil)
        store.showList(of: pullRequest, scope: .whole)
        #expect(store.list(of: key, .whole) == .reading)
        try await settle { readFiles(store) != nil }
        #expect(readFiles(store)?.files.count == 5)
        // On screen again: read already, and with the same reader as the threads' code.
        store.showList(of: pullRequest, scope: .whole)
        code.show(ReviewThread(id: 11, filePath: "/src/A.cs", line: 1, comments: []), of: pullRequest, by: viewer)
        try await settle { await reader.asked.count == 2 }
        #expect(await reader.asked == ["files c1", "excerpt 11"])
        #expect(made() == 1)

        // Nothing for a pull request nothing shows, or while no window shows the page.
        var other = pullRequest
        other.key = PRKey("contoso", 8)
        store.showList(of: other, scope: .whole)
        code.setVisible(false, for: "window.1")
        store.showList(of: pullRequest, scope: .since(1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.asked.count == 2)
        #expect(store.list(of: other.key, .whole) == nil && store.list(of: key, .since(1)) == nil)
        code.release(hold)
    }

    @Test func readsTheFilesAgainAfterAPushShowingTheOldOnesMeanwhile() async throws {
        let reader = Reader()
        let (store, _, _, _) = makeStores(reader)
        store.showList(of: pullRequest, scope: .whole)
        try await settle { readFiles(store) != nil }
        await reader.hold(true)
        var pushed = pullRequest
        pushed.sourceCommit = "c2"
        store.showList(of: pushed, scope: .whole)
        try await settle { await reader.isHolding("files c2") }
        #expect(readFiles(store)?.files.first?.objectId == "A-c1")
        await reader.release("files c2")
        try await settle { readFiles(store)?.files.first?.objectId == "A-c2" }
        #expect(readFiles(store)?.files.first?.objectId == "A-c2")
    }

    @Test func readsAFilesDiffAsItsPageShowsAndCallsItOffWhenItGoes() async throws {
        let reader = Reader()
        let (store, _, _, _) = makeStores(reader)
        let files = Self.files(head: "c1")
        let file = files.files[0]
        let version = PullRequestFilesStore.Version(file, in: files)
        await reader.hold(true)
        store.showDiff(of: file, in: files, of: pullRequest, by: viewer)
        #expect(store.diff(of: version, in: key) == .reading)
        try await settle { await reader.isHolding("diff A.cs") }
        // It went before it was read: called off, and its answer shows nothing.
        store.hideDiff(version, of: key, by: viewer)
        #expect(store.diff(of: version, in: key) == nil)
        await reader.release("diff A.cs")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.diff(of: version, in: key) == nil)

        // Back, it's read, and counted with it.
        await reader.hold(false)
        store.showDiff(of: file, in: files, of: pullRequest, by: viewer)
        try await settle { if case .read? = store.diff(of: version, in: key) { true } else { false } }
        guard case .read(let diff)? = store.diff(of: version, in: key) else {
            Issue.record("The file's diff wasn't read")
            return
        }
        #expect(diff.counts == LineCounts(added: 2, removed: 1))
        #expect(store.counts(of: version, in: key) == .success(LineCounts(added: 2, removed: 1)))
        #expect(await reader.asked == ["diff A.cs", "diff A.cs"])
    }

    @Test func countsOneFileAtATimeAsTheirRowsShow() async throws {
        let reader = Reader()
        let (store, _, _, _) = makeStores(reader)
        let files = Self.files(head: "c1")
        await reader.hold(true)
        for file in files.files.prefix(3) {
            store.count(file, in: files, of: pullRequest, by: viewer)
        }
        try await settle { await reader.isHolding("diff A.cs") }
        // One at a time: B waits for A.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked == ["diff A.cs"])
        // C left the screen before its turn: it isn't counted.
        store.stopCounting(PullRequestFilesStore.Version(files.files[2], in: files), of: key, by: viewer)
        await reader.release("diff A.cs")
        try await settle { await reader.isHolding("diff B.cs") }
        await reader.release("diff B.cs")
        try await settle { store.counts(of: PullRequestFilesStore.Version(files.files[1], in: files), in: key) != nil }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked == ["diff A.cs", "diff B.cs"])
        #expect(store.counts(of: PullRequestFilesStore.Version(files.files[0], in: files), in: key) == .success(LineCounts(added: 2, removed: 1)))
        #expect(store.counts(of: PullRequestFilesStore.Version(files.files[2], in: files), in: key) == nil)
        // Counted once: on screen again, it isn't read again.
        await reader.hold(false)
        store.count(files.files[0], in: files, of: pullRequest, by: viewer)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 2)
    }

    @Test func saysWhyAFileCantBeCountedAndTriesAgainOnlyWhatMayPass() async throws {
        let reader = Reader()
        var now = Date()
        let (store, _, _, _) = makeStores(reader) { now }
        let files = Self.files(head: "c1")
        await reader.failDiff("A.cs", .binary)
        await reader.failDiff("B.cs", .unreadable(.offline))
        store.count(files.files[0], in: files, of: pullRequest, by: viewer)
        store.count(files.files[1], in: files, of: pullRequest, by: viewer)
        let b = PullRequestFilesStore.Version(files.files[1], in: files)
        try await settle { store.counts(of: b, in: key) != nil }
        #expect(store.counts(of: PullRequestFilesStore.Version(files.files[0], in: files), in: key) == .failure(.binary))
        #expect(store.counts(of: b, in: key) == .failure(.unreadable(.offline)))
        // On screen again: a picture stays one; offline, it's read again half a minute later.
        await reader.failDiff("B.cs", nil)
        store.count(files.files[0], in: files, of: pullRequest, by: viewer)
        store.count(files.files[1], in: files, of: pullRequest, by: viewer)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked == ["diff A.cs", "diff B.cs"])
        now = now.addingTimeInterval(PullRequestCodeStore.retryInterval)
        store.count(files.files[1], in: files, of: pullRequest, by: viewer)
        try await settle { store.counts(of: b, in: key) == .success(LineCounts(added: 2, removed: 1)) }
        #expect(store.counts(of: b, in: key) == .success(LineCounts(added: 2, removed: 1)))
    }

    @Test func triesTheFilesAgainWhenYouAskOrHalfAMinuteLater() async throws {
        let reader = Reader()
        var now = Date()
        let (store, _, _, _) = makeStores(reader) { now }
        await reader.failList(.unreadable(.offline))
        store.showList(of: pullRequest, scope: .whole)
        try await settle { store.list(of: key, .whole) == .failed(.unreadable(.offline)) }
        await reader.failList(nil)
        store.showList(of: pullRequest, scope: .whole)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 1)
        store.showList(of: pullRequest, scope: .whole, again: true)
        try await settle { readFiles(store) != nil }
        #expect(await reader.asked.count == 2)
        // What isn't there stays so.
        await reader.failList(.unreadable(.notFound))
        store.showList(of: pullRequest, scope: .since(1))
        try await settle { store.list(of: key, .since(1)) == .failed(.unreadable(.notFound)) }
        now = now.addingTimeInterval(PullRequestCodeStore.retryInterval)
        store.showList(of: pullRequest, scope: .since(1), again: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.asked.count == 3)
    }

    @Test func keepsTheDiffsThatShowAndAFewBefore() async throws {
        let reader = Reader()
        let (store, _, _, _) = makeStores(reader)
        let files = Self.files(head: "c1")
        let versions = files.files.map { PullRequestFilesStore.Version($0, in: files) }
        for (file, version) in zip(files.files, versions) {
            store.showDiff(of: file, in: files, of: pullRequest, by: viewer)
            try await settle { if case .read? = store.diff(of: version, in: key) { true } else { false } }
            store.hideDiff(version, of: key, by: viewer)
        }
        #expect(versions.map { store.diff(of: $0, in: key) != nil } == [false, false, true, true, true])
        // Every file's count stays.
        #expect(versions.allSatisfy { store.counts(of: $0, in: key) != nil })
    }

    @Test func callsEverythingOffWhileNoWindowShowsIt() async throws {
        let reader = Reader()
        let (store, code, _, _) = makeStores(reader)
        let files = Self.files(head: "c1")
        await reader.hold(true)
        store.showList(of: pullRequest, scope: .whole)
        store.showDiff(of: files.files[0], in: files, of: pullRequest, by: viewer)
        store.count(files.files[1], in: files, of: pullRequest, by: viewer)
        store.count(files.files[2], in: files, of: pullRequest, by: viewer)
        try await settle { await reader.asked.count == 3 }
        code.setVisible(false, for: "window.1")
        #expect(store.list(of: key, .whole) == nil)
        #expect(store.diff(of: PullRequestFilesStore.Version(files.files[0], in: files), in: key) == nil)
        await reader.release("files c1")
        await reader.release("diff A.cs")
        await reader.release("diff B.cs")
        try await Task.sleep(for: .milliseconds(50))
        // Nothing they answered shows, and C was never counted.
        #expect(store.list(of: key, .whole) == nil)
        #expect(store.counts.isEmpty || store.counts[key]?.isEmpty == true)
        #expect(await reader.asked.sorted() == ["diff A.cs", "diff B.cs", "files c1"])
        // Shown again, they're read again.
        await reader.hold(false)
        code.setVisible(true, for: "window.1")
        store.showList(of: pullRequest, scope: .whole)
        try await settle { readFiles(store) != nil }
        #expect(readFiles(store) != nil)
    }

    @Test func forgetsAPullRequestOnceNothingShowsIt() async throws {
        let reader = Reader()
        let (store, code, hold, _) = makeStores(reader)
        let files = Self.files(head: "c1")
        store.showList(of: pullRequest, scope: .whole)
        store.count(files.files[0], in: files, of: pullRequest, by: viewer)
        try await settle { readFiles(store) != nil && !store.counts.isEmpty }
        code.release(hold)
        #expect(store.lists.isEmpty && store.counts.isEmpty && store.diffs.isEmpty)
        // And reads nothing more of it.
        store.showList(of: pullRequest, scope: .whole)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.lists.isEmpty)
    }
}

/// A file's page in a pull request's details: opening it, going back to its row, and what else takes the details elsewhere.
@MainActor
@Suite struct PullRequestFileNavigationTests {
    private let items: [PRSnapshot]

    init() {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        items = PROrdering.sorted(DemoData.records(now: now).compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), dismissedCutoff: seen.dismissedCutoff(for: $0.id), now: now)
        })
    }

    private func item(_ number: Int) throws -> PRSnapshot {
        try #require(items.first { $0.key.number == number })
    }

    private let file = FileChange.ID(path: "/src/PaymentsClient.cs")
    private let workItem = ItemRef.workItem(organization: DemoData.organization, id: 5160)

    @Test func opensAFilesPageAndComesBackToItsRow() throws {
        let store = PullRequestDetailsStore()
        store.itemsChanged(items)
        store.show(try item(4102), at: .thread(11))
        #expect(!store.canGoBack)
        store.open(file: file, at: 11)
        #expect(store.file == .init(id: file, thread: 11))
        #expect(store.place == nil && store.trailThread == nil && store.canGoBack)
        store.reachedThread(11)
        #expect(store.file == .init(id: file, thread: nil))
        // A page over it, then back to it, then back to the details at its row.
        store.open(page: workItem)
        #expect(store.pages == [workItem] && store.file?.id == file)
        store.back()
        #expect(store.pages.isEmpty && store.file?.id == file)
        store.back()
        #expect(store.file == nil && store.place == .file(file) && !store.canGoBack)
        #expect(PullRequestDetailsStore.Place.file(file).anchor(in: []) == .file(file))
    }

    @Test func goingElsewhereClosesTheFile() throws {
        let store = PullRequestDetailsStore()
        store.itemsChanged(items)
        store.show(try item(4102))
        store.open(file: file)
        store.go(to: .section(.checks))
        #expect(store.file == nil)
        store.open(file: file)
        store.open(page: try item(4102).key.linkRef)
        #expect(store.file == nil)

        // Which change the Files show, and the room a file's page takes, stay with the pull request until another shows or
        // the details close.
        store.open(file: file)
        store.scope = .since(1)
        store.fillsPage = true
        store.show(try item(4102))
        #expect(store.file == nil && store.scope == .since(1) && store.fillsPage)
        store.show(try item(4088))
        #expect(store.scope == .whole && store.fillsPage)
        store.close()
        #expect(store.scope == .whole && !store.fillsPage && store.file == nil)
        // Without a pull request, nothing opens.
        store.open(file: file)
        #expect(store.file == nil)
    }

    @Test func remembersWhenYouLastLookedBeforeTheDetailsShowedIt() throws {
        let store = PullRequestDetailsStore()
        store.itemsChanged(items)
        var looked: [PRKey: Date] = [:]
        let earlier = Date().addingTimeInterval(-3_600)
        looked[try item(4102).key] = earlier
        store.cutoffs = { key in .init(seen: .distantPast, dismissed: .distantPast, looked: looked[key]) }
        store.markSeen = { looked[$0.key] = Date() }
        store.show(try item(4102))
        #expect(store.lastLooked == earlier)
        // Shown again, it's still the same look.
        store.show(try item(4102))
        #expect(store.lastLooked == earlier)
        store.show(try item(4088))
        #expect(store.lastLooked == nil)
    }
}
