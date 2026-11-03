import Foundation
import Testing
@testable import AzureDevOpsCore

// MARK: - Made-up change

/// The made-up pull request's change: two updates, where the latest edited /src/Payments.cs, added a policy and a picture,
/// deleted the README and renamed the invoices to billing.
private enum ChangeFixture {
    static let png = "\u{89}PNG\r\n\u{1A}\n\0\0\0\rIHDR"

    static func server() -> StubServer {
        let server = StubServer()
        server.on("/pullRequests/7/iterations", json: Fixture.list([
            CodeFixture.iteration(1, source: "s1"), CodeFixture.iteration(2, source: "abc"),
        ]))
        server.on("/iterations/2/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
            CodeFixture.change("/src/Payments.cs", objectId: "second", original: "base", tracking: 1),
            CodeFixture.change("/src/Retry/Policy.cs", "add", objectId: "policy", tracking: 2),
            CodeFixture.change("/README.md", "delete", original: "readme", tracking: 3),
            CodeFixture.change("/src/Billing.cs", "rename", objectId: "billing", original: "billing", tracking: 4,
                               originalPath: "/src/Invoices.cs"),
            CodeFixture.change("/docs/logo.png", "add", objectId: "logo", tracking: 5),
        ]))
        server.on("/iterations/1/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
            CodeFixture.change("/src/Payments.cs", objectId: "first", original: "base", tracking: 1),
        ]))
        server.on("/iterations/2/changes", query: ["$compareTo": "1"], json: CodeFixture.changes([
            CodeFixture.change("/src/Payments.cs", objectId: "second", original: "first", tracking: 1),
        ]))
        server.on("/blobs/base") { _ in CodeFixture.file(CodeFixture.base) }
        server.on("/blobs/first") { _ in CodeFixture.file(CodeFixture.first) }
        server.on("/blobs/second") { _ in CodeFixture.file(CodeFixture.second) }
        server.on("/blobs/policy") { _ in CodeFixture.file("class Policy\n{\n}\n") }
        server.on("/blobs/readme") { _ in CodeFixture.file("# Shop\n\nThe shop.\n") }
        server.on("/blobs/billing") { _ in CodeFixture.file("class Billing\n") }
        server.on("/blobs/logo") { _ in CodeFixture.file(png) }
        return server
    }

    /// The requests a stub Azure DevOps answered, from where they leave the pull request or the repository, with what they
    /// compare with: "/iterations/2/changes 1", "/blobs/base".
    static func requests(_ server: StubServer) -> [String] {
        server.requests.compactMap(\.url).map { url in
            var path = url.path
            for marker in ["/pullRequests/7", "/repositories/r1"] {
                if let range = path.range(of: marker) {
                    path = String(path[range.upperBound...])
                    break
                }
            }
            let comparedTo = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "$compareTo" }.map { " \($0.value ?? "")" } ?? ""
            return path + comparedTo
        }
    }

    /// A diff's lines as a diff writes them.
    static func text(_ lines: [DiffLine]) -> [String] {
        lines.map { line in
            switch line.kind {
            case .unchanged: " " + line.text
            case .removed: "-" + line.text
            case .added: "+" + line.text
            }
        }
    }

    /// `count` unchanged lines, with lines changed at `changed`, numbered as a diff numbers them.
    static func lines(_ count: Int, changed: Set<Int> = []) -> [DiffLine] {
        (0..<count).map { index in
            changed.contains(index)
                ? DiffLine(.added, "new \(index)", old: nil, new: index + 1)
                : DiffLine(.unchanged, "line \(index)", old: index + 1, new: index + 1)
        }
    }
}

// MARK: - Reading the change

@Suite struct ChangedFilesReadingTests {
    private let pr = makePR(7)

    @Test func readsTheFilesTheWholeChangeTouchedAsTheFilesPageListsThem() async throws {
        let server = ChangeFixture.server()
        let code = PullRequestCode(pr, client: server.client())
        let files = try await code.changedFiles(of: pr).get()
        #expect(files.files.map(\.path) == ["/docs/logo.png", "/src/Retry/Policy.cs", "/src/Billing.cs", "/src/Payments.cs", "/README.md"])
        #expect(files.scope == .whole)
        #expect(files.comparison == ReviewThread.Comparison(base: 2))
        #expect(files.comparison.isWithBase)
        #expect(files.isComplete)
        #expect(files.iterations.map(\.id) == [1, 2])
        #expect(files.file(FileChange.ID(path: "/src/Billing.cs"))?.originalPath == "/src/Invoices.cs")
        // By its path before the rename too.
        #expect(files.file(atPath: "/src/Invoices.cs")?.path == "/src/Billing.cs")
        #expect(files.file(atPath: "/src/None.cs") == nil)
        #expect(files.index(of: FileChange.ID(path: "/README.md")) == 4)
        #expect(ChangeFixture.requests(server) == ["/iterations", "/iterations/2/changes 0"])

        // Read once: asked again, it reads nothing more, and a thread's code reads what it didn't.
        _ = try await code.changedFiles(of: pr).get()
        _ = try await code.excerpt(of: CodeFixture.thread(21, at: CodeFixture.location(right: 2...2, madeOn: (2, 2))), in: pr).get()
        #expect(ChangeFixture.requests(server) == ["/iterations", "/iterations/2/changes 0", "/blobs/second", "/blobs/base"])
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func saysWhenAFileChangedInMorePlacesThanItLinesUpExactly() async throws {
        let server = ChangeFixture.server()
        let code = PullRequestCode(
            pr, source: AzureDevOpsCode(client: server.client()), comparison: { LineDiff.comparison($0, $1, maxChanges: 1) }
        )
        let files = try await code.changedFiles(of: pr).get()
        let edited = try await code.diff(of: try #require(files.file(FileChange.ID(path: "/src/Payments.cs"))), in: files, of: pr).get()
        // Past the limit: lined up at the lines each version has once, as the fewest changes would be here, and said so.
        #expect(!edited.isLinedUp)
        #expect(edited.lines == LineDiff.compare(CodeFixture.base, CodeFixture.second))
        #expect(edited.counts == LineCounts(added: 3, removed: 2, isApproximate: true))
        // A file added whole is lined up.
        let added = try await code.diff(of: try #require(files.file(FileChange.ID(path: "/src/Retry/Policy.cs"))), in: files, of: pr).get()
        #expect(added.isLinedUp && !added.counts.isApproximate)
    }

    @Test func readsWhatChangedSinceAnUpdate() async throws {
        let server = ChangeFixture.server()
        let code = PullRequestCode(pr, client: server.client())
        let since = try await code.changedFiles(of: pr, scope: .since(1)).get()
        #expect(since.scope == .since(1))
        #expect(since.comparison == ReviewThread.Comparison(first: 1, second: 2))
        #expect(!since.comparison.isWithBase)
        #expect(since.files.map(\.path) == ["/src/Payments.cs"])
        #expect(since.files.first?.originalObjectId == "first")
        #expect(ChangeFixture.requests(server) == ["/iterations", "/iterations/2/changes 1"])

        // Since the latest, nothing: it reads nothing for it.
        let none = try await code.changedFiles(of: pr, scope: .since(2)).get()
        #expect(none.files.isEmpty && none.scope == .since(2))
        #expect(server.requests.count == 2)

        // Since an update it doesn't know of, it reads the updates again, once, and it's the whole change.
        let unknown = try await code.changedFiles(of: pr, scope: .since(5)).get()
        #expect(unknown.scope == .whole)
        #expect(unknown.files.count == 5)
        #expect(ChangeFixture.requests(server) == ["/iterations", "/iterations/2/changes 1", "/iterations", "/iterations/2/changes 0"])
    }

    @Test func comparesAFilesTwoVersions() async throws {
        let server = ChangeFixture.server()
        let code = PullRequestCode(pr, client: server.client())
        let files = try await code.changedFiles(of: pr).get()
        func diff(_ path: String) async throws -> FileDiff {
            let file = try #require(files.file(FileChange.ID(path: path)))
            return try await code.diff(of: file, in: files, of: pr).get()
        }

        let edited = try await diff("/src/Payments.cs")
        #expect(ChangeFixture.text(edited.lines) == [
            " line 1", "-line 2", "+line two", " line 3", " line 4", "-line 5", "+line five", " line 6", " line 7", "+line 7½",
            " line 8", " line 9", " line 10",
        ])
        #expect(edited.counts == LineCounts(added: 3, removed: 2))
        #expect(edited.file.path == "/src/Payments.cs")

        let added = try await diff("/src/Retry/Policy.cs")
        #expect(ChangeFixture.text(added.lines) == ["+class Policy", "+{", "+}"])
        #expect(added.lines.map(\.newNumber) == [1, 2, 3])
        #expect(added.counts == LineCounts(added: 3, removed: 0))

        let deleted = try await diff("/README.md")
        #expect(ChangeFixture.text(deleted.lines) == ["-# Shop", "-", "-The shop."])
        #expect(deleted.counts == LineCounts(added: 0, removed: 3))

        // Renamed as it was: the same lines on both sides.
        let renamed = try await diff("/src/Billing.cs")
        #expect(ChangeFixture.text(renamed.lines) == [" class Billing"])
        #expect(renamed.counts == LineCounts(added: 0, removed: 0))

        // A file is read once, whichever side it's on.
        #expect(ChangeFixture.requests(server).filter { $0.hasPrefix("/blobs/") }.sorted()
            == ["/blobs/base", "/blobs/billing", "/blobs/policy", "/blobs/readme", "/blobs/second"])
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func comparesAFileWithTheUpdateItsSince() async throws {
        let server = ChangeFixture.server()
        let code = PullRequestCode(pr, client: server.client())
        let since = try await code.changedFiles(of: pr, scope: .since(1)).get()
        let file = try #require(since.files.first)
        let diff = try await code.diff(of: file, in: since, of: pr).get()
        #expect(diff.lines.filter { $0.kind != .unchanged }.map(\.text) == ["line 2", "line two"])
        #expect(ChangeFixture.requests(server).filter { $0.hasPrefix("/blobs/") } == ["/blobs/second", "/blobs/first"])
    }

    @Test func readsAFileWithoutItsObjectIDsAtItsCommits() async throws {
        let server = ChangeFixture.server()
        server.on("/iterations/2/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
            CodeFixture.change("/src/Payments.cs", tracking: 1),
        ]))
        server.on("/items", query: ["versionDescriptor.version": "abc"]) { _ in CodeFixture.file(CodeFixture.second) }
        server.on("/items", query: ["versionDescriptor.version": "b1"]) { _ in CodeFixture.file(CodeFixture.base) }
        let code = PullRequestCode(pr, client: server.client())
        let files = try await code.changedFiles(of: pr).get()
        let diff = try await code.diff(of: try #require(files.files.first), in: files, of: pr).get()
        #expect(diff.counts == LineCounts(added: 3, removed: 2))
        // After the change at the latest update's head; before it where its branch left its target.
        let versions = server.requests.compactMap(\.url).filter { $0.path.hasSuffix("/items") }.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "versionDescriptor.version" }?.value
        }
        #expect(versions == ["abc", "b1"])
    }

    @Test func saysWhyItCantCompareAFile() async throws {
        let server = ChangeFixture.server()
        let code = PullRequestCode(pr, source: AzureDevOpsCode(client: server.client()), fileLimit: 20)
        let files = try await code.changedFiles(of: pr).get()
        func problem(_ path: String) async throws -> ThreadExcerpt.Problem? {
            let file = try #require(files.file(FileChange.ID(path: path)))
            guard case .failure(let problem) = await code.diff(of: file, in: files, of: pr) else { return nil }
            return problem
        }
        #expect(try await problem("/docs/logo.png") == .binary)
        // Longer than it reads.
        #expect(try await problem("/src/Payments.cs") == .tooLarge)
        server.on("/blobs/policy") { _ in .status(404) }
        #expect(try await problem("/src/Retry/Policy.cs") == .unreadable(.notFound))
        // Another pull request's.
        let other = makePR(8)
        #expect(await code.changedFiles(of: other) == .failure(.otherPullRequest))
        let file = try #require(files.files.first)
        #expect(await code.diff(of: file, in: files, of: other) == .failure(.otherPullRequest))
    }

    @Test func readsTheUpdatesAgainAfterAPush() async throws {
        let server = ChangeFixture.server()
        let code = PullRequestCode(pr, client: server.client())
        _ = try await code.changedFiles(of: pr).get()
        var pushed = pr
        pushed.sourceCommit = "def0"
        server.on("/pullRequests/7/iterations", json: Fixture.list([
            CodeFixture.iteration(1, source: "s1"), CodeFixture.iteration(2, source: "abc"), CodeFixture.iteration(3, source: "def0"),
        ]))
        server.on("/iterations/3/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
            CodeFixture.change("/src/Payments.cs", objectId: "first", original: "base", tracking: 1),
        ]))
        let files = try await code.changedFiles(of: pushed).get()
        #expect(files.comparison == ReviewThread.Comparison(base: 3))
        #expect(files.files.map(\.path) == ["/src/Payments.cs"])
        #expect(ChangeFixture.requests(server) == ["/iterations", "/iterations/2/changes 0", "/iterations", "/iterations/3/changes 0"])
    }
}

// MARK: - The files, by folder, and what happened to each

@Suite struct ChangedFilesTests {
    private let files = ChangedFiles(
        scope: .whole, comparison: ReviewThread.Comparison(base: 2),
        iterations: [PRIteration(id: 1, sourceCommit: "s1", commonCommit: "b1", createdAt: t(-5 * hour)),
                     PRIteration(id: 2, sourceCommit: "abc", commonCommit: "b1", createdAt: t(-1 * hour))],
        files: [
            FileChange(path: "/README.md", kind: .delete, objectId: nil, originalObjectId: "r"),
            FileChange(path: "/src/Payments.cs", kind: .edit, objectId: "p2", originalObjectId: "p1"),
            FileChange(path: "/src/Retry/Policy.cs", kind: .add, objectId: "c"),
            FileChange(path: "/src/Billing.cs", originalPath: "/src/Invoices.cs", kind: .rename, objectId: "b", originalObjectId: "b"),
            FileChange(path: "/src/Ledger.cs", originalPath: "/lib/Ledger.cs", kind: [.rename, .edit], objectId: "l2", originalObjectId: "l1"),
            FileChange(path: "/docs/logo.png", kind: .add, objectId: "logo"),
        ]
    )

    @Test func listsTheFilesFolderByFolder() {
        #expect(files.files.map(\.path) == [
            "/docs/logo.png", "/src/Retry/Policy.cs", "/src/Billing.cs", "/src/Ledger.cs", "/src/Payments.cs", "/README.md",
        ])
        #expect(files.folders.map(\.path) == ["docs", "src/Retry", "src", nil])
        #expect(files.folders.map { $0.files.map(\.name) } == [["logo.png"], ["Policy.cs"], ["Billing.cs", "Ledger.cs", "Payments.cs"], ["README.md"]])
        #expect(Set(files.folders.map(\.id)).count == 4)
        // Made with the list, and again as it changes.
        var fewer = files
        fewer.files.removeFirst()
        #expect(fewer.folders.map(\.path) == ["src/Retry", "src", nil])
    }

    @Test func tellsApartFoldersThatOnlyLookTheSame() {
        let accented = ChangedFiles(scope: .whole, comparison: ReviewThread.Comparison(base: 1), iterations: [], files: [
            FileChange(path: "/caf\u{E9}/a.cs", kind: .edit, objectId: "a"),
            FileChange(path: "/cafe\u{301}/b.cs", kind: .edit, objectId: "b"),
        ])
        #expect(accented.folders.count == 2)
        #expect(accented.files[0].id != accented.files[1].id)
    }

    @Test func saysWhatHappenedToEachFile() {
        #expect(files.files.map(\.what) == [
            "Added", "Added", "Renamed from Invoices.cs", "Renamed from lib/Ledger.cs and edited", "Edited", "Deleted",
        ])
        #expect(files.files.map(\.folder) == ["docs", "src/Retry", "src", "src", "src", nil])
    }

    @Test func countsTheLinesAFileAddsAndRemoves() {
        let counts = LineCounts(ChangeFixture.lines(5, changed: [1, 3]) + [DiffLine(.removed, "old", old: 9, new: nil)])
        #expect(counts == LineCounts(added: 2, removed: 1))
        #expect(counts.text == "+2 −1")
        #expect(counts.spoken == "2 lines added, 1 removed")
        #expect(LineCounts(added: 1, removed: 0).text == "+1")
        #expect(LineCounts(added: 1, removed: 0).spoken == "1 line added")
        #expect(LineCounts(added: 0, removed: 4).text == "−4")
        #expect(LineCounts(added: 0, removed: 4).spoken == "4 lines removed")
        #expect(LineCounts(added: 0, removed: 0).text == "No changes to its lines")
        // Of a file that changed in more places than it lines up exactly: about right.
        let file = FileChange(path: "/src/Payments.cs", kind: .edit, objectId: "a")
        let lines = ChangeFixture.lines(5, changed: [1, 3]) + [DiffLine(.removed, "old", old: 9, new: nil)]
        #expect(!FileDiff(file: file, lines: lines).counts.isApproximate && FileDiff(file: file, lines: lines).isLinedUp)
        let about = FileDiff(file: file, lines: lines, isLinedUp: false)
        #expect(about.counts == LineCounts(added: 2, removed: 1, isApproximate: true))
        #expect(about.counts.text == "~+2 −1")
        #expect(about.counts.spoken == "About 2 lines added, 1 removed")
    }

    @Test func findsTheUpdateYouSawWhenYouLastLooked() {
        // Between the two updates: what the second changed is new.
        #expect(files.lastSeenUpdate(at: t(-2 * hour)) == 1)
        #expect(files.updates(since: 1) == 1)
        // After the latest, or before the first, or never: nothing to show since.
        #expect(files.lastSeenUpdate(at: t(0)) == nil)
        #expect(files.lastSeenUpdate(at: t(-6 * hour)) == nil)
        #expect(files.lastSeenUpdate(at: nil) == nil)
        // An update without its time doesn't count.
        var untimed = files
        untimed.iterations[0].createdAt = nil
        #expect(untimed.lastSeenUpdate(at: t(-2 * hour)) == nil)
    }

    @Test func linksToAFileOnTheFilesPage() throws {
        let snapshot = try #require(PRClassifier.snapshot(
            for: PRRecord(pullRequest: makePR(7), role: .author, details: nil, me: People.me.id), seenCutoff: t(0), dismissedCutoff: t(0),
            now: t(0), options: ClassifierOptions()
        ))
        let file = try #require(files.files.first)
        let whole = files.filePageURL(of: file, in: snapshot).absoluteString
        #expect(whole == "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7?_a=files&path=%2Fdocs%2Flogo.png&iteration=2&base=0")
        var since = files
        since.comparison = ReviewThread.Comparison(first: 1, second: 2)
        #expect(since.filePageURL(of: file, in: snapshot).absoluteString.hasSuffix("iteration=2&base=1"))
    }
}

// MARK: - Comment threads on a file, and where they show

@Suite struct FileCommentsTests {
    private let file = FileChange(path: "/src/Payments.cs", originalPath: "/src/Pay.cs", kind: [.rename, .edit], objectId: "a",
                                  changeTrackingId: 4)

    private func thread(
        _ id: Int, path: String? = "/src/Payments.cs", line: Int? = 5, status: String = "active", tracking: Int? = nil
    ) -> ReviewThread {
        let location = path.map { ReviewThread.Location(path: $0, right: line.map { ReviewThread.Span(lines: $0...$0) }, changeTrackingId: tracking) }
        return ReviewThread(id: id, status: status, filePath: path, line: line, comments: [comment(1, People.sam, at: t(Double(id)))],
                            location: location)
    }

    @Test func countsTheThreadsOnAFileOpenOnesFirst() {
        let threads = PullRequestPanel.Threads(
            waitingOnYou: [PullRequestPanel.Thread(thread: thread(1, line: 30), waitsOnYou: true, isNew: true)],
            open: [PullRequestPanel.Thread(thread: thread(2, line: 40), waitsOnYou: false, isNew: false),
                   PullRequestPanel.Thread(thread: thread(3, path: "/src/Other.cs"), waitsOnYou: false, isNew: false),
                   // Before the rename.
                   PullRequestPanel.Thread(thread: thread(4, path: "/src/Pay.cs", line: 2), waitsOnYou: false, isNew: false),
                   // Tracked on another file, whatever its path.
                   PullRequestPanel.Thread(thread: thread(5, tracking: 9), waitsOnYou: false, isNew: false),
                   PullRequestPanel.Thread(thread: thread(6, path: "/src/Elsewhere.cs", tracking: 4), waitsOnYou: false, isNew: false)],
            resolved: [PullRequestPanel.Thread(thread: thread(7, line: 1, status: "fixed"), waitsOnYou: false, isNew: false)]
        )
        let comments = threads.comments(on: file)
        #expect(comments.threads.map(\.id) == [1, 4, 6, 2, 7])
        #expect(comments.open == 4)
        #expect(comments.resolved == 1)
        #expect(comments.waitingOnYou == 1)
        #expect(comments.spoken == "4 open comments, 1 of them waiting on you, and 1 resolved")
        #expect(threads.comments(on: FileChange(path: "/src/None.cs", kind: .add, objectId: "n")).spoken == "No comments")
        #expect(PullRequestPanel.FileComments(threads: [threads.resolved[0]]).spoken == "1 resolved comment")
    }

    @Test func saysHowManyThreadsThereAreWithoutCountingAnyTwice() {
        func comments(waiting: Int, open: Int, resolved: Int) -> PullRequestPanel.FileComments {
            let waitingThreads = (0..<waiting).map { PullRequestPanel.Thread(thread: thread($0), waitsOnYou: true, isNew: false) }
            let openThreads = (0..<open).map { PullRequestPanel.Thread(thread: thread(100 + $0), waitsOnYou: false, isNew: false) }
            let resolvedThreads = (0..<resolved).map {
                PullRequestPanel.Thread(thread: thread(200 + $0, status: "fixed"), waitsOnYou: false, isNew: false)
            }
            return PullRequestPanel.FileComments(threads: waitingThreads + openThreads + resolvedThreads)
        }
        // Those waiting on you are among the open ones.
        #expect(comments(waiting: 1, open: 0, resolved: 2).spoken == "1 open comment, waiting on you, and 2 resolved")
        #expect(comments(waiting: 1, open: 2, resolved: 0).spoken == "3 open comments, 1 of them waiting on you")
        #expect(comments(waiting: 2, open: 0, resolved: 0).spoken == "2 open comments, both waiting on you")
        #expect(comments(waiting: 3, open: 0, resolved: 1).spoken == "3 open comments, all waiting on you, and 1 resolved")
        #expect(comments(waiting: 0, open: 2, resolved: 1).spoken == "2 open comments and 1 resolved")
        #expect(comments(waiting: 0, open: 1, resolved: 0).spoken == "1 open comment")
        #expect(comments(waiting: 0, open: 0, resolved: 3).spoken == "3 resolved comments")
    }

    @Test func findsEachFilesThreadsAtOnceAsItDoesForOneFile() {
        // Pay.cs renamed to Payments.cs, tracked as 4; a new Pay.cs, tracked as 8; and two files without tracking IDs.
        let replacement = FileChange(path: "/src/Pay.cs", kind: .add, objectId: "p", changeTrackingId: 8)
        let untracked = FileChange(path: "/src/Other.cs", kind: .edit, objectId: "o")
        let none = FileChange(path: "/src/None.cs", kind: .edit, objectId: "n")
        let changes = ChangedFiles(
            scope: .whole, comparison: ReviewThread.Comparison(base: 2), iterations: [], files: [replacement, file, untracked, none]
        )
        let threads = PullRequestPanel.Threads(
            waitingOnYou: [PullRequestPanel.Thread(thread: thread(1, line: 30), waitsOnYou: true, isNew: true)],
            open: [
                // By its path alone: the new Pay.cs, and Payments.cs, renamed from it.
                PullRequestPanel.Thread(thread: thread(2, path: "/src/Pay.cs", line: 2), waitsOnYou: false, isNew: false),
                // Tracked on Payments.cs, and on the new Pay.cs.
                PullRequestPanel.Thread(thread: thread(3, path: "/src/Pay.cs", tracking: 4), waitsOnYou: false, isNew: false),
                PullRequestPanel.Thread(thread: thread(4, path: "/src/Pay.cs", tracking: 8), waitsOnYou: false, isNew: false),
                // Tracked, on a file without a tracking ID: by its path.
                PullRequestPanel.Thread(thread: thread(5, path: "/src/Other.cs", tracking: 9), waitsOnYou: false, isNew: false),
                PullRequestPanel.Thread(thread: thread(6, path: nil), waitsOnYou: false, isNew: false),
            ],
            resolved: [PullRequestPanel.Thread(thread: thread(7, line: 1, status: "fixed"), waitsOnYou: false, isNew: false)]
        )
        let byFile = threads.comments(in: changes)
        for file in changes.files {
            let one = threads.comments(on: file)
            #expect(byFile[file.id] == (one.isEmpty ? nil : one))
        }
        #expect(byFile[none.id] == nil)
        #expect(byFile[file.id]?.threads.map(\.id) == [1, 2, 3, 7])
        #expect(byFile[replacement.id]?.threads.map(\.id) == [2, 4])
        #expect(byFile[untracked.id]?.threads.map(\.id) == [5])
    }

    @Test func findsTheFileAThreadIsTrackedOnThoughAnotherTookItsPath() {
        // Pay.cs renamed to Payments.cs, tracked as 4, and a new Pay.cs, tracked as 8.
        let replacement = FileChange(path: "/src/Pay.cs", kind: .add, objectId: "p", changeTrackingId: 8)
        let changes = ChangedFiles(
            scope: .whole, comparison: ReviewThread.Comparison(base: 2), iterations: [], files: [replacement, file]
        )
        #expect(changes.file(of: thread(1, path: "/src/Pay.cs", tracking: 4))?.path == "/src/Payments.cs")
        #expect(changes.file(of: thread(2, path: "/src/Pay.cs", tracking: 8))?.path == "/src/Pay.cs")
        #expect(changes.file(of: thread(3, path: "/src/Payments.cs"))?.path == "/src/Payments.cs")
        #expect(changes.file(of: thread(4, path: "/src/None.cs")) == nil)
    }

    @Test func findsTheFilesWithOpenThreadsToGoThrough() {
        let other = FileChange(path: "/src/Other.cs", kind: .edit, objectId: "o")
        let none = FileChange(path: "/src/None.cs", kind: .add, objectId: "n")
        let changes = ChangedFiles(scope: .whole, comparison: ReviewThread.Comparison(base: 2), iterations: [], files: [other, none, file])
        let threads = PullRequestPanel.Threads(
            waitingOnYou: [PullRequestPanel.Thread(thread: thread(1, line: 30), waitsOnYou: true, isNew: false)],
            open: [PullRequestPanel.Thread(thread: thread(2, line: 4), waitsOnYou: false, isNew: false),
                   PullRequestPanel.Thread(thread: thread(3, path: "/src/Other.cs"), waitsOnYou: false, isNew: false)],
            resolved: [PullRequestPanel.Thread(thread: thread(4, path: "/src/None.cs", status: "fixed"), waitsOnYou: false, isNew: false)]
        )
        let found = threads.openOnFiles(of: changes)
        // As the change lists its files, but not the one whose only thread is resolved; each file's from its top down,
        // whoever they wait on.
        #expect(found.map { changes.files[$0.index].path } == ["/src/Other.cs", "/src/Payments.cs"])
        let ids: [[Int]] = found.map { $0.threads.map(\.id) }
        #expect(ids == [[3], [2, 1]])
        #expect(PullRequestPanel.Threads(waitingOnYou: [], open: [], resolved: threads.resolved).openOnFiles(of: changes).isEmpty)
    }

    /// The diff of CodeFixture's file, from the base to the second update.
    private var diff: FileDiff {
        FileDiff(file: FileChange(path: "/src/Payments.cs", kind: .edit, objectId: "second", originalObjectId: "base", changeTrackingId: 1),
                 lines: LineDiff.compare(CodeFixture.base, CodeFixture.second))
    }

    private let whole = ChangedFiles(scope: .whole, comparison: ReviewThread.Comparison(base: 2), iterations: [], files: [])

    @Test func placesAThreadUnderTheLastLineItsOn() {
        // On lines 5 to 8 after the change, made on the latest update's diff: under line 8, "line 7½".
        let made = CodeFixture.thread(1, at: CodeFixture.location(right: 5...8, madeOn: (2, 2)))
        #expect(diff.row(of: made, in: whole) == 9)
        #expect(diff.rows(of: made, in: whole) == 6...9)
        // Made on a diff of two updates: the same version after the change.
        #expect(diff.row(of: CodeFixture.thread(2, at: CodeFixture.location(right: 2...2, madeOn: (1, 2))), in: whole) == 2)
        // On lines the change removed, in the same diff: under line 5 before it.
        let removed = CodeFixture.thread(3, at: CodeFixture.location(left: 5...5, madeOn: (2, 2)))
        #expect(diff.row(of: removed, in: whole) == 5)
        #expect(diff.rows(of: removed, in: whole) == 5...5)
        // Without its location, as the demo's: its line in the latest diff.
        #expect(diff.row(of: ReviewThread(id: 4, filePath: "/src/Payments.cs", line: 8, comments: []), in: whole) == 9)
    }

    @Test func marksOnlyTheLinesOfTheVersionAThreadIsOn() {
        // Line 4 changed: a thread on lines 3 and 4 after the change doesn't mark the line removed between them.
        let diff = FileDiff(file: FileChange(path: "/src/Payments.cs", kind: .edit, objectId: "b", originalObjectId: "a"), lines: [
            DiffLine(.unchanged, "1", old: 1, new: 1), DiffLine(.unchanged, "2", old: 2, new: 2), DiffLine(.unchanged, "3", old: 3, new: 3),
            DiffLine(.removed, "old 4", old: 4, new: nil), DiffLine(.added, "new 4", old: nil, new: 4), DiffLine(.unchanged, "5", old: 5, new: 5),
        ])
        let after = CodeFixture.thread(1, at: CodeFixture.location(right: 3...4, madeOn: (2, 2)))
        #expect(diff.rows(of: after, in: whole) == 2...4)
        #expect(diff.markedRows(of: after, in: whole) == IndexSet([2, 4]))
        // Before it, on lines 3 and 4: both, with nothing added between them.
        let before = CodeFixture.thread(2, at: CodeFixture.location(left: 3...4, madeOn: (2, 2)))
        #expect(diff.markedRows(of: before, in: whole) == IndexSet([2, 3]))
        #expect(diff.markedRows(of: CodeFixture.thread(3, at: CodeFixture.location(right: 9...9, madeOn: (2, 2))), in: whole).isEmpty)
    }

    @Test func placesAThreadAzureDevOpsFollowedWhereItIsNow() {
        var location = CodeFixture.location(right: 2...2, madeOn: (1, 1))
        location.tracking = ReviewThread.Tracking(to: ReviewThread.Comparison(base: 2), originalRight: ReviewThread.Span(lines: 4...4))
        #expect(diff.row(of: CodeFixture.thread(1, at: location), in: whole) == 2)
    }

    @Test func leavesOutAThreadOnAVersionTheDiffDoesntShow() {
        // Made on the first update, and not followed since.
        #expect(diff.row(of: CodeFixture.thread(1, at: CodeFixture.location(right: 5...5, madeOn: (1, 1))), in: whole) == nil)
        // Before the change, in another diff.
        #expect(diff.row(of: CodeFixture.thread(2, at: CodeFixture.location(left: 5...5, madeOn: (1, 2))), in: whole) == nil)
        let since = ChangedFiles(scope: .since(1), comparison: ReviewThread.Comparison(first: 1, second: 2), iterations: [], files: [])
        #expect(diff.row(of: CodeFixture.thread(3, at: CodeFixture.location(left: 5...5, madeOn: (2, 2))), in: since) == nil)
        // On a line the file doesn't have, on the whole file, or on the pull request.
        #expect(diff.row(of: CodeFixture.thread(4, at: CodeFixture.location(right: 40...40, madeOn: (2, 2))), in: whole) == nil)
        #expect(diff.row(of: ReviewThread(id: 5, filePath: "/src/Payments.cs", comments: [], location: .init(path: "/src/Payments.cs")),
                         in: whole) == nil)
        #expect(diff.row(of: ReviewThread(id: 6, comments: []), in: whole) == nil)
    }
}

// MARK: - What a diff shows

@Suite struct DiffLayoutTests {
    @Test func showsTheChangesWithAFewLinesAroundThemAndFoldsTheRest() {
        // Forty lines, changed at 20: lines 17 to 23 show.
        let lines = ChangeFixture.lines(40, changed: [20])
        #expect(DiffLayout.blocks(of: lines) == [.folded(0..<17), .lines(17..<24), .folded(24..<40)])
        // Two changes close together share a run; a single line between their runs shows with them; farther apart, the
        // lines between them fold.
        #expect(DiffLayout.blocks(of: ChangeFixture.lines(40, changed: [10, 16])) == [.folded(0..<7), .lines(7..<20), .folded(20..<40)])
        #expect(DiffLayout.blocks(of: ChangeFixture.lines(40, changed: [10, 18])) == [.folded(0..<7), .lines(7..<22), .folded(22..<40)])
        #expect(DiffLayout.blocks(of: ChangeFixture.lines(40, changed: [10, 20])) == [
            .folded(0..<7), .lines(7..<14), .folded(14..<17), .lines(17..<24), .folded(24..<40),
        ])
    }

    @Test func showsASingleFoldedLineRatherThanFoldingIt() {
        // Changed at 4 and 12: lines 1 to 7 and 9 to 15 show, and line 8 between them takes no more room shown.
        #expect(DiffLayout.blocks(of: ChangeFixture.lines(16, changed: [4, 12])) == [.lines(0..<16)])
        // Line 0 alone above the first change's lines.
        #expect(DiffLayout.blocks(of: ChangeFixture.lines(10, changed: [4])) == [.lines(0..<8), .folded(8..<10)])
    }

    @Test func showsTheLinesThreadsAreOnAndWhatYouUnfold() {
        let lines = ChangeFixture.lines(60, changed: [20])
        // A thread on line 50, unchanged, shows with the lines around it.
        #expect(DiffLayout.blocks(of: lines, anchors: [50]) == [.folded(0..<17), .lines(17..<24), .folded(24..<47), .lines(47..<54),
                                                                .folded(54..<60)])
        // Unfolding the first fold's last 5 lines, up from the change, and the last fold's first 2, down from it.
        var revealed = DiffLayout.reveal(0..<17, .up(5), in: [])
        revealed = DiffLayout.reveal(24..<60, .down(2), in: revealed)
        #expect(DiffLayout.blocks(of: lines, revealed: revealed) == [.folded(0..<12), .lines(12..<26), .folded(26..<60)])
        // All of it.
        #expect(DiffLayout.blocks(of: lines, revealed: DiffLayout.reveal(26..<60, .all, in: revealed)) == [.folded(0..<12), .lines(12..<60)])
        // More than a fold has unfolds all of it.
        #expect(DiffLayout.reveal(0..<3, .up(20), in: []) == IndexSet(integersIn: 0..<3))
    }

    @Test func endsARunUnderTheLinesThreadsShowUnder() {
        let lines = ChangeFixture.lines(10, changed: [2, 6])
        #expect(DiffLayout.blocks(of: lines, breaks: [3, 9]) == [.lines(0..<4), .lines(4..<10)])
        #expect(DiffLayout.blocks(of: lines, breaks: [3, 5]) == [.lines(0..<4), .lines(4..<6), .lines(6..<10)])
    }

    @Test func foldsAFileWhoseLinesDidntChange() {
        #expect(DiffLayout.blocks(of: ChangeFixture.lines(30)) == [.folded(0..<30)])
        #expect(DiffLayout.blocks(of: ChangeFixture.lines(1)) == [.lines(0..<1)])
        #expect(DiffLayout.blocks(of: []) == [])
        // A file added, all of it.
        let added = (0..<5).map { DiffLine(.added, "\($0)", old: nil, new: $0 + 1) }
        #expect(DiffLayout.blocks(of: added) == [.lines(0..<5)])
    }
}

// MARK: - The demo

@Suite struct DemoFilesTests {
    @Test func showsEachWayAFileCanChangeInTheDemo() async throws {
        let pr = try #require(DemoData.records(now: Date()).first { $0.pullRequest.key.number == 4102 }?.pullRequest)
        let code = PullRequestCode.demo(pr)
        let files = try await code.changedFiles(of: pr).get()
        #expect(files.files.map(\.path) == [
            "/docs/retry-backoff.png", "/src/Config/PaymentsSettings.cs", "/src/LegacyRetry.cs", "/src/PaymentsClient.cs",
            "/src/RetryOptions.cs", "/src/RetryPolicy.cs", "/tests/PaymentsClientTests.cs", "/appsettings.json", "/README.md",
        ])
        #expect(files.files.map(\.what) == [
            "Added", "Renamed from src/PaymentsConfig.cs and edited", "Deleted", "Edited", "Added", "Added", "Added", "Edited", "Edited",
        ])
        var counts: [String: LineCounts] = [:]
        for file in files.files {
            switch await code.diff(of: file, in: files, of: pr) {
            case .success(let diff): counts[file.name] = diff.counts
            case .failure(let problem): #expect(file.name == "retry-backoff.png" && problem == .binary)
            }
        }
        #expect(counts.count == 8)
        #expect(counts["LegacyRetry.cs"]?.added == 0)
        #expect(counts["PaymentsSettings.cs"].map { $0.added > 0 && $0.removed > 0 } == true)
        #expect(counts["appsettings.json"] == LineCounts(added: 4, removed: 1))

        // Since the first update: what the second changed, the renamed file as it was then.
        let since = try await code.changedFiles(of: pr, scope: .since(1)).get()
        #expect(since.files.map(\.name) == ["retry-backoff.png", "PaymentsClient.cs", "RetryOptions.cs", "PaymentsClientTests.cs",
                                            "appsettings.json", "README.md"])
    }

    @Test func showsALockFileThatChangedInMorePlacesThanItLinesUpExactly() async throws {
        let pr = try #require(DemoData.records(now: Date()).first { $0.pullRequest.key.number == 4110 }?.pullRequest)
        let code = PullRequestCode.demo(pr)
        let files = try await code.changedFiles(of: pr).get()
        #expect(files.files.map(\.path) == ["/agents/BuildAgent.csproj", "/agents/global.json", "/agents/packages.lock.json"])
        // Four in five of its 520 packages moved to another version: their requested and resolved versions and their
        // hashes, as many lines as the fewest changes would take, past the most it lines up exactly.
        let lock = try await code.diff(of: try #require(files.files.last), in: files, of: pr).get()
        #expect(!lock.isLinedUp)
        #expect(lock.counts == LineCounts(added: 1_249, removed: 1_249, isApproximate: true))
        let project = try await code.diff(of: try #require(files.files.first), in: files, of: pr).get()
        #expect(project.isLinedUp && project.counts == LineCounts(added: 1, removed: 1))
    }
}
