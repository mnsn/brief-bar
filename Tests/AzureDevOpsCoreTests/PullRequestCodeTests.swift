import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore

// MARK: - Made-up code

/// The made-up pull request's files, and its threads' JSON.
enum CodeFixture {
    /// Ten lines.
    static let base = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
    /// The first iteration: line 5 changed, and a line added after line 7.
    static let first = base.replacingOccurrences(of: "line 5\n", with: "line five\n")
        .replacingOccurrences(of: "line 7\n", with: "line 7\nline 7½\n")
    /// The second: line 2 changed too.
    static let second = first.replacingOccurrences(of: "line 2\n", with: "line two\n")

    static func iteration(_ id: Int, source: String, common: String = "b1") -> [String: Any] {
        ["id": id, "createdDate": iso(t(Double(id) * hour)), "reason": id == 1 ? "create" : "push",
         "sourceRefCommit": ["commitId": source], "targetRefCommit": ["commitId": "t1"], "commonRefCommit": ["commitId": common]]
    }

    static func change(
        _ path: String, _ type: String = "edit", objectId: String? = nil, original: String? = nil, tracking: Int = 1,
        originalPath: String? = nil
    ) -> [String: Any] {
        var item: [String: Any] = ["path": path, "gitObjectType": "blob"]
        if let objectId { item["objectId"] = objectId }
        if let original { item["originalObjectId"] = original }
        var json: [String: Any] = ["changeTrackingId": tracking, "changeId": tracking, "item": item, "changeType": type]
        if let originalPath { json["originalPath"] = originalPath }
        return json
    }

    static func changes(_ entries: [Any], nextSkip: Int = 0) -> [String: Any] {
        ["changeEntries": entries, "nextSkip": nextSkip, "nextTop": nextSkip == 0 ? 0 : 2_000]
    }

    static func file(_ text: String, headers: [String: String] = [:]) -> StubServer.Reply {
        var reply = StubServer.Reply(status: 200, headers: ["Content-Type": "application/octet-stream"], body: Data(text.utf8))
        reply.headers.merge(headers) { $1 }
        return reply
    }

    /// A thread on a file, from the JSON Azure DevOps sends.
    static func thread(_ id: Int = 21, context: [String: Any]?, pullRequestContext: Any? = nil) throws -> ReviewThread {
        var json: [String: Any] = [
            "id": id, "publishedDate": iso(t(0)), "status": "active", "isDeleted": false,
            "comments": [Fixture.comment(1, People.sam, "Why this?", at: t(0))],
        ]
        if let context { json["threadContext"] = context }
        if let pullRequestContext { json["pullRequestThreadContext"] = pullRequestContext }
        return try #require(ReviewThread(try Fixture.decode(ADOThread.self, json), names: [:]))
    }

    static func position(_ line: Int, _ offset: Int = 1) -> [String: Any] {
        ["line": line, "offset": offset]
    }

    /// A thread on lines of the right side of a diff, made on `first` against `second`.
    static func location(
        _ path: String = "/src/Payments.cs", right: ClosedRange<Int>? = nil, left: ClosedRange<Int>? = nil, madeOn: (Int, Int)? = (1, 1),
        tracking: Int? = 1
    ) -> ReviewThread.Location {
        ReviewThread.Location(
            path: path, left: left.map(ReviewThread.Span.init(lines:)), right: right.map(ReviewThread.Span.init(lines:)),
            madeOn: madeOn.map { ReviewThread.Comparison(first: $0.0, second: $0.1) }, changeTrackingId: tracking
        )
    }

    static func thread(_ id: Int, at location: ReviewThread.Location) -> ReviewThread {
        ReviewThread(id: id, filePath: location.path, line: (location.right ?? location.left)?.start.line,
                     comments: [comment(1, People.sam, "Why this?", at: t(0))], location: location)
    }
}

/// A stub Azure DevOps that serves the made-up pull request's code: two iterations, where the first changed
/// /src/Payments.cs from the base, and the second changed it again.
private func codeServer() -> StubServer {
    let server = StubServer()
    server.on("/pullRequests/7/iterations", json: Fixture.list([
        CodeFixture.iteration(1, source: "s1"), CodeFixture.iteration(2, source: "abc"),
    ]))
    server.on("/iterations/1/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
        CodeFixture.change("/src/Payments.cs", objectId: "first", original: "base"),
    ]))
    server.on("/iterations/2/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
        CodeFixture.change("/src/Payments.cs", objectId: "second", original: "base"),
    ]))
    server.on("/iterations/2/changes", query: ["$compareTo": "1"], json: CodeFixture.changes([
        CodeFixture.change("/src/Payments.cs", objectId: "second", original: "first"),
    ]))
    server.on("/blobs/base") { _ in CodeFixture.file(CodeFixture.base) }
    server.on("/blobs/first") { _ in CodeFixture.file(CodeFixture.first) }
    server.on("/blobs/second") { _ in CodeFixture.file(CodeFixture.second) }
    return server
}

/// The requests a stub Azure DevOps answered, from where they leave the pull request or the repository, with what they
/// compare with: "/iterations/2/changes 1", "/blobs/base".
private func requests(_ server: StubServer) -> [String] {
    server.requests.compactMap(\.url).map { url in
        var path = url.path
        for marker in ["/pullRequests/7", "/pullRequests/8", "/repositories/r1"] {
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

/// An excerpt's lines as a diff writes them, with ">" before the thread's.
private func text(_ excerpt: ThreadExcerpt?) -> [String] {
    (excerpt?.lines ?? []).map { line in
        let mark = switch line.kind {
        case .unchanged: " "
        case .removed: "-"
        case .added: "+"
        }
        return (line.isCommented ? ">" : "") + mark + line.text
    }
}

/// Code with two files, unchanged by the pull request, whose paths differ only in how their "é" is written: as one
/// character, or as "e" and an accent. Read by their bytes, as Git reads paths.
private struct AccentedCode: CodeSource {
    static let composed = "/src/caf\u{E9}.cs"
    static let decomposed = "/src/cafe\u{301}.cs"

    func iterations(of pullRequest: PullRequest) async throws -> [PRIteration] {
        [PRIteration(id: 1, sourceCommit: "abc", commonCommit: "b1")]
    }

    func changes(of pullRequest: PullRequest, iteration: Int, comparedTo: Int) async throws -> FileChanges {
        FileChanges(files: [])
    }

    func file(of pullRequest: PullRequest, objectId: String, limit: Int) async throws -> FileText {
        throw ADOError.notFound
    }

    func file(of pullRequest: PullRequest, path: String, commit: String, limit: Int) async throws -> FileText {
        if path.utf8.elementsEqual(Self.composed.utf8) { return .text("composed\n") }
        if path.utf8.elementsEqual(Self.decomposed.utf8) { return .text("decomposed\n") }
        throw ADOError.notFound
    }
}

// MARK: - Decoding

@Suite struct ThreadLocationDecodingTests {
    @Test func decodesWhereAThreadIsInFull() throws {
        let thread = try CodeFixture.thread(
            context: ["filePath": "/src/Payments.cs",
                      "rightFileStart": CodeFixture.position(12, 5), "rightFileEnd": CodeFixture.position(14, 2),
                      "leftFileStart": CodeFixture.position(10), "leftFileEnd": CodeFixture.position(11, 9)],
            pullRequestContext: [
                "changeTrackingId": 3,
                "iterationContext": ["firstComparingIteration": 1, "secondComparingIteration": 2],
                "trackingCriteria": ["firstComparingIteration": 3, "secondComparingIteration": 4, "origFilePath": "/src/Old.cs",
                                     "origRightFileStart": CodeFixture.position(8), "origRightFileEnd": CodeFixture.position(9, 4)],
            ]
        )
        let location = try #require(thread.location)
        #expect(location.path == "/src/Payments.cs")
        #expect(location.right == ReviewThread.Span(start: .init(line: 12, offset: 5), end: .init(line: 14, offset: 2)))
        #expect(location.right?.lines == 12...14)
        #expect(location.left == ReviewThread.Span(start: .init(line: 10, offset: 1), end: .init(line: 11, offset: 9)))
        #expect(location.madeOn == ReviewThread.Comparison(first: 1, second: 2))
        #expect(location.madeOn?.isWithBase == false)
        #expect(location.changeTrackingId == 3)
        #expect(location.tracking == ReviewThread.Tracking(
            to: ReviewThread.Comparison(first: 3, second: 4), originalPath: "/src/Old.cs",
            originalRight: ReviewThread.Span(start: .init(line: 8, offset: 1), end: .init(line: 9, offset: 4))
        ))
        // What the panel showed before stays.
        #expect(thread.filePath == "/src/Payments.cs")
        #expect(thread.line == 12)
    }

    @Test func toleratesWhatItLeavesOut() throws {
        // Only a file and where the thread starts, as apps that add threads write them: no end, no offset and no diff.
        let bare = try CodeFixture.thread(context: ["filePath": "/src/a.cs", "rightFileStart": ["line": 3]])
        #expect(bare.location == ReviewThread.Location(path: "/src/a.cs", right: ReviewThread.Span(lines: 3...3)))

        // The diff's left side missing is the base; an end before the start ends at the start; an empty tracking is none.
        let partial = try CodeFixture.thread(
            context: ["filePath": "/src/a.cs", "leftFileStart": CodeFixture.position(7), "leftFileEnd": CodeFixture.position(2),
                      "rightFileStart": ["line": 0, "offset": 1]],
            pullRequestContext: ["iterationContext": ["secondComparingIteration": 2],
                                 "trackingCriteria": ["firstComparingIteration": 0, "secondComparingIteration": 0]]
        )
        #expect(partial.location?.left?.lines == 7...7)
        #expect(partial.location?.right == nil)
        #expect(partial.location?.madeOn == ReviewThread.Comparison(base: 2))
        #expect(partial.location?.madeOn?.isWithBase == true)
        #expect(partial.location?.tracking == nil)
        #expect(partial.location?.changeTrackingId == nil)

        // Values of unexpected types count as missing, rather than losing the thread.
        let odd = try CodeFixture.thread(
            context: ["filePath": "/src/a.cs", "rightFileStart": ["line": "12", "offset": "1"], "rightFileEnd": "end"],
            pullRequestContext: "context"
        )
        #expect(odd.location == ReviewThread.Location(path: "/src/a.cs"))
        let oddIterations = try CodeFixture.thread(
            context: ["filePath": "/src/a.cs", "rightFileStart": CodeFixture.position(4)],
            pullRequestContext: ["changeTrackingId": "3", "iterationContext": ["firstComparingIteration": "1", "secondComparingIteration": 2]]
        )
        #expect(oddIterations.location?.madeOn == ReviewThread.Comparison(base: 2))
        #expect(oddIterations.location?.changeTrackingId == nil)

        // A thread on the pull request, rather than a file, has no location.
        let general = try CodeFixture.thread(context: nil)
        #expect(general.location == nil)
        let noPath = try CodeFixture.thread(context: ["rightFileStart": CodeFixture.position(4)])
        #expect(noPath.location == nil)
    }

    @Test func keepsEveryThreadOfAListWhateverItsContext() throws {
        let threads = try Fixture.decode(ADOList<ADOThread>.self, Fixture.list([
            ["id": 1, "comments": [Fixture.comment(1, People.sam, "One", at: t(0))], "pullRequestThreadContext": 7,
             "threadContext": ["filePath": "/a.cs", "rightFileStart": "first"]],
            ["id": 2, "comments": [Fixture.comment(1, People.sam, "Two", at: t(0))], "threadContext": "here"],
        ]))
        #expect(threads.value.map(\.id) == [1, 2])
        #expect(threads.skipped == 0)
    }

    @Test func keepsTheWholeCommentInMarkdownWithMentionsAsNames() throws {
        let long = String(repeating: "Retry with backoff, and cap it. ", count: 40)
        let content = "@<\(People.sam.id.uppercased())> **Why** `200 ms`? @<\(People.alex.id)>\n\n" + long
        let threads = try Fixture.decode(ADOList<ADOThread>.self, Fixture.list([
            Fixture.thread(5, comments: [Fixture.comment(1, People.me, content, at: t(0))], published: t(0)),
        ]))
        let thread = try #require(PRDetails(fetchedAt: t(0), pullRequest: makePR(reviewers: [Reviewer(person: People.sam, vote: .none)]),
                                            evaluations: [], threads: threads.value).threads.first)
        let comment = try #require(thread.comments.first)
        // Someone the pull request doesn't name is "someone", as in its plain text.
        #expect(comment.markdown == "@Sam Rivera **Why** `200 ms`? @someone\n\n" + long)
        #expect(comment.text.count == 500)
        #expect(comment.markdown.count > 1_000)
        // Made without its Markdown, a comment's is its text.
        #expect(ReviewComment(id: 1, author: People.sam, text: "Plain", publishedAt: t(0)).markdown == "Plain")
    }

    @Test func decodesIterationsAndTheirChanges() throws {
        let iterations = try Fixture.decode(ADOList<ADOPullRequestIteration>.self, Fixture.list([
            CodeFixture.iteration(1, source: "s1"),
            ["id": 2, "sourceRefCommit": "not an object", "createdDate": "yesterday"],
            ["description": "No ID"],
        ]))
        #expect(iterations.skipped == 1)
        #expect(iterations.value.compactMap(PRIteration.init) == [
            PRIteration(id: 1, sourceCommit: "s1", targetCommit: "t1", commonCommit: "b1", createdAt: t(hour)),
            PRIteration(id: 2, sourceCommit: nil, commonCommit: nil),
        ])

        let page = try Fixture.decode(ADOIterationChanges.self, CodeFixture.changes([
            CodeFixture.change("/src/a.cs", objectId: "a2", original: "a1", tracking: 1),
            CodeFixture.change("/src/new.cs", "add", objectId: "n1", tracking: 2),
            CodeFixture.change("/src/renamed.cs", "edit, rename", objectId: "r2", original: "r1", tracking: 3, originalPath: "/src/old.cs"),
            CodeFixture.change("/src/moved.cs", "rename", objectId: "m1", original: "m1", tracking: 4, originalPath: "/lib/moved.cs"),
            CodeFixture.change("/src/gone.cs", "delete", original: "g1", tracking: 5),
            ["item": ["path": "/src", "gitObjectType": "tree"], "changeType": "add"],
            ["changeType": 7, "item": "none"],
            "not a change",
        ], nextSkip: 2_000))
        #expect(page.nextSkip == 2_000)
        #expect(page.changeEntries.count == 7)
        #expect(page.changeEntries.compactMap(FileChange.init) == [
            FileChange(path: "/src/a.cs", kind: .edit, objectId: "a2", originalObjectId: "a1", changeTrackingId: 1),
            FileChange(path: "/src/new.cs", kind: .add, objectId: "n1", changeTrackingId: 2),
            FileChange(path: "/src/renamed.cs", originalPath: "/src/old.cs", kind: [.edit, .rename], objectId: "r2",
                       originalObjectId: "r1", changeTrackingId: 3),
            FileChange(path: "/src/moved.cs", originalPath: "/lib/moved.cs", kind: .rename, objectId: "m1", originalObjectId: "m1",
                       changeTrackingId: 4),
            FileChange(path: "/src/gone.cs", kind: .delete, objectId: nil, originalObjectId: "g1", changeTrackingId: 5),
        ])
        #expect(FileChange.Kind("Edit, sourceRename") == [.edit, .rename])
        #expect(FileChange.Kind("undelete") == .add)
        #expect(FileChange.Kind("merge") == [])
        #expect(FileChange.Kind(nil) == [])
        // An empty page, and one that doesn't say whether more follow.
        #expect(try Fixture.decode(ADOIterationChanges.self, [String: Any]()).changeEntries.isEmpty)
    }

    @Test func buildsTheCodesEndpoints() {
        let base = "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1"
        #expect(ADOEndpoint.pullRequestIterations(organization: "contoso", projectId: "p1", repositoryId: "r1", pullRequestId: 7)
            .absoluteString == base + "/pullRequests/7/iterations?includeCommits=false&api-version=7.1")
        #expect(ADOEndpoint.iterationChanges(
            organization: "contoso", projectId: "p1", repositoryId: "r1", pullRequestId: 7, iteration: 3, comparedTo: 1, skip: 2_000
        ).absoluteString == base + "/pullRequests/7/iterations/3/changes?$top=2000&$skip=2000&$compareTo=1&api-version=7.1")
        #expect(ADOEndpoint.file(organization: "contoso", projectId: "p1", repositoryId: "r1", path: "/src/My File.cs", commit: "abc")
            .absoluteString == base + "/items?path=%2Fsrc%2FMy%20File.cs&versionDescriptor.version=abc"
            + "&versionDescriptor.versionType=commit&api-version=7.1")
        #expect(ADOEndpoint.blob(organization: "contoso", projectId: "p1", repositoryId: "r1", objectId: "0a1b")
            .absoluteString == base + "/blobs/0a1b?$format=octetstream&api-version=7.1")
    }
}

// MARK: - Files

@Suite struct FileReadingTests {
    private let address = ADOEndpoint.blob(organization: "contoso", projectId: "p1", repositoryId: "r1", objectId: "0a1b")

    @Test func readsAFilesTextAsGitTellsIt() {
        #expect(FileText(Data("héllo\n".utf8), isComplete: true) == .text("héllo\n"))
        #expect(FileText(Data(), isComplete: true) == .text(""))
        #expect(FileText(Data([0xEF, 0xBB, 0xBF]) + Data("marked".utf8), isComplete: true) == .text("marked"))
        #expect(FileText(Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]), isComplete: true) == .text("hi"))
        #expect(FileText(Data([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69]), isComplete: true) == .text("hi"))
        // Not UTF-8: Windows' Latin alphabet.
        #expect(FileText(Data([0x63, 0x61, 0x66, 0xE9]), isComplete: true) == .text("café"))
        #expect(FileText(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]), isComplete: true) == .binary)
        // With a byte order mark too.
        #expect(FileText(Data([0xEF, 0xBB, 0xBF, 0x61, 0x00, 0x62]), isComplete: true) == .binary)
        #expect(FileText(Data("cut".utf8), isComplete: false) == .tooLarge)
    }

    @Test func readsABlobWithAGETForItsBytes() async throws {
        let server = StubServer()
        server.on("/blobs/0a1b") { _ in CodeFixture.file("The file\n") }
        let bytes = try await server.client().file(address, limit: 100)
        #expect(bytes == FileBytes(data: Data("The file\n".utf8), isComplete: true))
        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "X-TFS-FedAuthRedirect") == "Suppress")
        // Whatever type of file it is.
        server.on("/blobs/0a1b") { _ in StubServer.Reply(status: 200, headers: ["Content-Type": "text/html"], body: Data("<p>".utf8)) }
        #expect(try await server.client().file(address, limit: 100) == FileBytes(data: Data("<p>".utf8), isComplete: true))
    }

    @Test func readsNoMoreThanItsLimit() async throws {
        let server = StubServer()
        let long = String(repeating: "x", count: 1_000)
        // Said to be longer: none of it is read.
        server.on("/blobs/0a1b") { _ in CodeFixture.file(long, headers: ["Content-Length": "1000"]) }
        #expect(try await server.client().file(address, limit: 100) == FileBytes(data: Data(), isComplete: false))
        // Not said: up to the limit.
        server.on("/blobs/0a1b") { _ in CodeFixture.file(long) }
        let cut = try await server.client().file(address, limit: 100)
        #expect(cut.data.count == 100)
        #expect(!cut.isComplete)
        #expect(try await server.client().file(address, limit: 1_000).isComplete)
    }

    @Test func failsAsOtherRequestsDo() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id)
        server.on("/blobs/0a1b") { _ in .status(404) }
        await #expect(throws: ADOError.notFound) { try await server.client().file(address, limit: 100) }
        // A sign-in page is a rejected token, once with a fresh one too.
        server.on("/blobs/0a1b") { _ in StubServer.Reply(status: 203, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)) }
        await #expect(throws: ADOError.unauthorized) { try await server.client(tokens: tokens).file(address, limit: 100) }
        #expect(await tokens.invalidations == 1)
        server.on("/blobs/0a1b") { _ in .status(429, headers: ["Retry-After": "30"]) }
        await #expect(throws: ADOError.throttled(retryAfter: 30)) { try await server.client().file(address, limit: 100) }
    }

    /// A file's request goes only where it's sent too.
    @Test(.timeLimit(.minutes(1)))
    func followsNoRedirect() async {
        let server = StubServer()
        server.on("/blobs/0a1b") { request in
            request.url?.host == "dev.azure.com" ? .redirect(to: "https://elsewhere.example/blobs/0a1b") : CodeFixture.file("Elsewhere")
        }
        await #expect(throws: ADOError.redirected) { try await server.client().file(address, limit: 100) }
        server.on("/blobs/0a1b") { request in
            request.url?.query?.contains("again") == true ? CodeFixture.file("Again") : .redirect(to: address.absoluteString + "&again")
        }
        await #expect(throws: ADOError.http(307)) { try await server.client().file(address, limit: 100) }
        #expect(server.requests.map(\.url) == [address, address])
    }
}

// MARK: - The reader

@Suite struct PullRequestCodeTests {
    private let pr = makePR(7)

    @Test func readsTheCodeAThreadWasMadeOnWithTheLinesAroundIt() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        let thread = CodeFixture.thread(21, at: CodeFixture.location(right: 5...5))
        let excerpt = try await code.excerpt(of: thread, in: pr).get()
        #expect(text(excerpt) == [" line 2", " line 3", " line 4", "-line 5", ">+line five", " line 6", " line 7", "+line 7½"])
        #expect(excerpt.lines.map(\.newNumber) == [2, 3, 4, nil, 5, 6, 7, 8])
        #expect(excerpt.lines.map(\.oldNumber) == [2, 3, 4, 5, nil, 6, 7, nil])
        #expect(excerpt.threadId == 21)
        #expect(excerpt.path == "/src/Payments.cs")
        #expect(excerpt.change == .edit)
        #expect(excerpt.side == .right)
        #expect(excerpt.iteration == 1)
        #expect(excerpt.latestIteration == 2)
        // The second push changed the file again.
        #expect(excerpt.changedSince == true)
        #expect(!excerpt.reachesStart && !excerpt.reachesEnd)
        #expect(requests(server) == ["/iterations", "/iterations/1/changes 0", "/blobs/first", "/blobs/base", "/iterations/2/changes 1"])

        // Asked again, or for another thread on the file, it reads nothing more.
        _ = try await code.excerpt(of: thread, in: pr).get()
        let other = try await code.excerpt(of: CodeFixture.thread(22, at: CodeFixture.location(right: 1...1)), in: pr).get()
        #expect(text(other) == ["> line 1", " line 2", " line 3", " line 4"])
        #expect(other.reachesStart)
        #expect(server.requests.count == 5)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func showsADiffOfTwoIterationsAsItWasMade() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        let excerpt = try await code.excerpt(of: CodeFixture.thread(21, at: CodeFixture.location(right: 2...2, madeOn: (1, 2))), in: pr).get()
        #expect(text(excerpt) == [" line 1", "-line 2", ">+line two", " line 3", " line 4", " line five"])
        #expect(excerpt.reachesStart)
        #expect(excerpt.iteration == 2)
        #expect(excerpt.changedSince == false)
        #expect(requests(server) == ["/iterations", "/iterations/2/changes 1", "/blobs/second", "/blobs/first"])
    }

    @Test func showsRemovedLinesOnTheLeft() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        let excerpt = try await code.excerpt(of: CodeFixture.thread(21, at: CodeFixture.location(left: 5...5, madeOn: (2, 2))), in: pr).get()
        #expect(excerpt.side == .left)
        // Three of the old file's lines on either side, with what was added between them.
        #expect(text(excerpt) == ["-line 2", "+line two", " line 3", " line 4", ">-line 5", "+line five", " line 6", " line 7", "+line 7½",
                                  " line 8"])
        #expect(excerpt.lines.first { $0.isCommented } == ThreadExcerpt.Line(kind: .removed, text: "line 5", oldNumber: 5, newNumber: nil,
                                                                             isCommented: true))
        #expect(excerpt.iteration == 2)
        #expect(excerpt.changedSince == false)
    }

    @Test func showsARenamedFileWithItsPathBefore() async throws {
        let server = codeServer()
        server.on("/iterations/2/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
            CodeFixture.change("/src/Billing.cs", "edit, rename", objectId: "second", original: "base", tracking: 4,
                               originalPath: "/src/Payments.cs"),
        ]))
        let code = PullRequestCode(pr, client: server.client())
        let thread = CodeFixture.thread(21, at: CodeFixture.location("/src/Billing.cs", right: 2...2, madeOn: (2, 2), tracking: 4))
        let excerpt = try await code.excerpt(of: thread, in: pr).get()
        #expect(excerpt.path == "/src/Billing.cs")
        #expect(excerpt.originalPath == "/src/Payments.cs")
        #expect(excerpt.change == [.edit, .rename])
        #expect(excerpt.lines.first { $0.isCommented }?.text == "line two")
    }

    @Test func findsAThreadsFileByItsTrackingIDThenWhereItIsNow() async throws {
        let server = codeServer()
        // The file at /src/Payments.cs moved to /src/Billing.cs, and another was added in its place.
        server.on("/iterations/2/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
            CodeFixture.change("/src/Billing.cs", "rename", objectId: "base", original: "base", tracking: 1, originalPath: "/src/Payments.cs"),
            CodeFixture.change("/src/Payments.cs", "add", objectId: "fresh", tracking: 2),
        ]))
        server.on("/blobs/fresh") { _ in CodeFixture.file("fresh\n") }
        let code = PullRequestCode(pr, client: server.client())
        let tracked = try await code.excerpt(of: CodeFixture.thread(21, at: CodeFixture.location(right: 1...1, madeOn: (2, 2), tracking: 2)),
                                             in: pr).get()
        #expect(text(tracked) == [">+fresh"])
        let untracked = try await code.excerpt(
            of: CodeFixture.thread(22, at: CodeFixture.location(right: 1...1, madeOn: (2, 2), tracking: nil)), in: pr
        ).get()
        #expect(text(untracked) == [">+fresh"])
        let moved = try await code.excerpt(of: CodeFixture.thread(23, at: CodeFixture.location(right: 1...1, madeOn: (2, 2), tracking: 1)),
                                           in: pr).get()
        #expect(moved.path == "/src/Billing.cs")
        #expect(moved.originalPath == "/src/Payments.cs")
    }

    @Test func tellsApartPathsThatOnlyLookTheSame() async throws {
        let (composed, decomposed) = (AccentedCode.composed, AccentedCode.decomposed)
        // Equal as Swift compares strings, but two paths, of two files, to Git.
        #expect(composed == decomposed)
        let changes = FileChanges(files: [
            FileChange(path: composed, kind: .edit, objectId: "one"), FileChange(path: decomposed, kind: .edit, objectId: "two"),
        ])
        #expect(changes.change(to: composed, trackingId: nil)?.objectId == "one")
        #expect(changes.change(to: decomposed, trackingId: nil)?.objectId == "two")
        let renamed = try Fixture.decode(ADOIterationChanges.self, CodeFixture.changes([
            CodeFixture.change(decomposed, "rename", objectId: "one", original: "one", originalPath: composed),
        ])).changeEntries.compactMap(FileChange.init)
        #expect(renamed.first?.originalPath.map { Array($0.utf8) } == Array(composed.utf8))
        #expect(FileChanges(files: renamed).change(to: composed, trackingId: nil)?.objectId == "one")
        #expect(FileChanges(files: [FileChange(path: decomposed, kind: .add, objectId: "two")]).change(to: composed, trackingId: nil) == nil)

        // Each read by its own path, at the same commit.
        let code = PullRequestCode(pr, source: AccentedCode())
        for (id, path, text) in [(1, composed, "composed"), (2, decomposed, "decomposed")] {
            let thread = CodeFixture.thread(id, at: CodeFixture.location(path, right: 1...1, madeOn: nil, tracking: nil))
            #expect(try await code.excerpt(of: thread, in: pr).get().lines.map(\.text) == [text])
        }
    }

    @Test func saysWhenItCantTellAmongMoreFilesThanItReads() async throws {
        let server = codeServer()
        // Pages of one file each, for as long as it reads them; each file with a tracking ID of its own.
        for (iteration, comparedTo) in [(1, 0), (2, 1)] {
            server.on("/iterations/\(iteration)/changes", query: ["$compareTo": String(comparedTo)]) { request in
                let skip = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "$skip" }?.value.flatMap { Int($0) } ?? 0
                let payments = skip == 0 && iteration == 1
                let change = CodeFixture.change(payments ? "/src/Payments.cs" : "/src/f\(iteration)-\(skip).cs", objectId: "first",
                                                original: "base", tracking: payments ? 1 : 100 * iteration + skip)
                return .json(CodeFixture.changes([change], nextSkip: skip + 1))
            }
        }
        let code = PullRequestCode(pr, source: AzureDevOpsCode(client: server.client(), maxPages: 2))
        // On a file among those read, which changed since unless it's among those left out.
        let found = try await code.excerpt(of: CodeFixture.thread(21, at: CodeFixture.location(right: 5...5, tracking: nil)), in: pr).get()
        #expect(found.lines.first { $0.isCommented }?.text == "line five")
        #expect(found.changedSince == nil)
        // On one of those left out.
        let elsewhere = CodeFixture.thread(22, at: CodeFixture.location("/src/Elsewhere.cs", right: 1...1, tracking: nil))
        #expect(await code.excerpt(of: elsewhere, in: pr) == .failure(.tooManyFiles))
        #expect(requests(server).filter { $0.hasPrefix("/iterations/1/changes") }.count == 2)
    }

    @Test func showsADeletedFilesLines() async throws {
        let server = codeServer()
        server.on("/iterations/2/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
            CodeFixture.change("/src/Payments.cs", "delete", original: "base"),
        ]))
        let code = PullRequestCode(pr, client: server.client())
        let excerpt = try await code.excerpt(of: CodeFixture.thread(21, at: CodeFixture.location(left: 9...10, madeOn: (2, 2))), in: pr).get()
        #expect(text(excerpt) == ["-line 6", "-line 7", "-line 8", ">-line 9", ">-line 10"])
        #expect(excerpt.change == .delete)
        #expect(excerpt.reachesEnd)
        // The deleted file has no lines after the change.
        let right = await code.excerpt(of: CodeFixture.thread(22, at: CodeFixture.location(right: 1...1, madeOn: (2, 2))), in: pr)
        #expect(right == .failure(.linesNotFound))
        #expect(!requests(server).contains { $0.hasPrefix("/blobs/second") || $0.contains("/items") })
    }

    @Test func readsAFileTheDiffDidntChangeAtItsCommit() async throws {
        let server = codeServer()
        server.on("/items", query: ["path": "/src/Other.cs", "versionDescriptor.version": "abc", "versionDescriptor.versionType": "commit"]) { _ in
            CodeFixture.file("one\ntwo\nthree\n")
        }
        let code = PullRequestCode(pr, client: server.client())
        let thread = CodeFixture.thread(21, at: CodeFixture.location("/src/Other.cs", right: 2...2, madeOn: (2, 2), tracking: nil))
        let excerpt = try await code.excerpt(of: thread, in: pr).get()
        #expect(text(excerpt) == [" one", "> two", " three"])
        #expect(excerpt.change == nil)
        #expect(requests(server).filter { $0.contains("/items") }.count == 1)
    }

    @Test func showsAThreadWithoutItsDiffOnTheLatestIteration() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        // As the demo's are, or a thread an app added with only its file and line.
        let excerpt = try await code.excerpt(
            of: ReviewThread(id: 21, filePath: "/src/Payments.cs", line: 2, comments: [comment(1, People.sam, "Why?", at: t(0))]), in: pr
        ).get()
        #expect(excerpt.iteration == 2)
        #expect(excerpt.lines.first { $0.isCommented }?.text == "line two")
        let bare = try await code.excerpt(of: CodeFixture.thread(22, at: CodeFixture.location(right: 2...2, madeOn: nil)), in: pr).get()
        #expect(bare.iteration == 2)
        #expect(bare.changedSince == false)
    }

    @Test func showsATrackedThreadWhereItWasMade() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        var location = CodeFixture.location("/src/Moved.cs", right: 9...9, madeOn: (1, 1))
        location.tracking = ReviewThread.Tracking(to: ReviewThread.Comparison(base: 2), originalPath: "/src/Payments.cs",
                                                  originalRight: ReviewThread.Span(lines: 5...5))
        let excerpt = try await code.excerpt(of: CodeFixture.thread(21, at: location), in: pr).get()
        #expect(excerpt.iteration == 1)
        #expect(excerpt.path == "/src/Payments.cs")
        #expect(excerpt.lines.first { $0.isCommented }?.text == "line five")
        // Without where it was made, it's where Azure DevOps followed it to.
        location.tracking = ReviewThread.Tracking(to: ReviewThread.Comparison(base: 2))
        location.path = "/src/Payments.cs"
        location.right = ReviewThread.Span(lines: 2...2)
        let followed = try await code.excerpt(of: CodeFixture.thread(22, at: location), in: pr).get()
        #expect(followed.iteration == 2)
        #expect(followed.lines.first { $0.isCommented }?.text == "line two")
    }

    @Test func readsTheIterationsAgainForAPushOrANewerThread() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        let thread = CodeFixture.thread(21, at: CodeFixture.location(right: 2...2, madeOn: (2, 2)))
        #expect(try await code.excerpt(of: thread, in: pr).get().changedSince == false)

        // A third iteration that changed the file again.
        server.on("/pullRequests/7/iterations", json: Fixture.list([
            CodeFixture.iteration(1, source: "s1"), CodeFixture.iteration(2, source: "s2"), CodeFixture.iteration(3, source: "s3"),
        ]))
        server.on("/iterations/3/changes", query: ["$compareTo": "2"], json: CodeFixture.changes([
            CodeFixture.change("/src/Payments.cs", objectId: "third", original: "second"),
        ]))
        server.on("/iterations/3/changes", query: ["$compareTo": "0"], json: CodeFixture.changes([
            CodeFixture.change("/src/Payments.cs", objectId: "second", original: "base"),
        ]))
        // A thread made on it is news: it reads them again, once.
        let newer = CodeFixture.thread(22, at: CodeFixture.location(right: 2...2, madeOn: (3, 3)))
        #expect(try await code.excerpt(of: newer, in: pr).get().iteration == 3)
        #expect(requests(server).filter { $0 == "/iterations" }.count == 2)

        // The push, once the pull request says so, is too: the first thread changed since.
        var pushed = pr
        pushed.sourceCommit = "s3"
        let after = try await code.excerpt(of: thread, in: pushed).get()
        #expect(after.latestIteration == 3)
        #expect(after.changedSince == true)
        #expect(requests(server).filter { $0 == "/iterations" }.count == 3)
    }

    @Test func readsTheIterationsAgainForWhereAThreadWasFollowedTo() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        let thread = CodeFixture.thread(21, at: CodeFixture.location(right: 2...2, madeOn: (2, 2)))
        #expect(try await code.excerpt(of: thread, in: pr).get().latestIteration == 2)

        // A third iteration that changed the file, before the pull request says so, and a thread made on the second
        // that Azure DevOps followed to it.
        server.on("/pullRequests/7/iterations", json: Fixture.list([
            CodeFixture.iteration(1, source: "s1"), CodeFixture.iteration(2, source: "abc"), CodeFixture.iteration(3, source: "s3"),
        ]))
        server.on("/iterations/3/changes", query: ["$compareTo": "2"], json: CodeFixture.changes([
            CodeFixture.change("/src/Payments.cs", objectId: "third", original: "second"),
        ]))
        var location = CodeFixture.location(right: 4...4, madeOn: (2, 2))
        location.tracking = ReviewThread.Tracking(to: ReviewThread.Comparison(base: 3), originalRight: ReviewThread.Span(lines: 2...2))
        let followed = try await code.excerpt(of: CodeFixture.thread(22, at: location), in: pr).get()
        // Shown where it was made, and changed since.
        #expect(followed.iteration == 2)
        #expect(followed.lines.first { $0.isCommented }?.text == "line two")
        #expect(followed.latestIteration == 3)
        #expect(followed.changedSince == true)
        #expect(requests(server).filter { $0 == "/iterations" }.count == 2)

        // Followed to an iteration they don't have even then, it reads them again once, not each time it's asked.
        location.tracking = ReviewThread.Tracking(to: ReviewThread.Comparison(base: 9), originalRight: ReviewThread.Span(lines: 2...2))
        let lost = CodeFixture.thread(23, at: location)
        #expect(try await code.excerpt(of: lost, in: pr).get().latestIteration == 3)
        #expect(try await code.excerpt(of: lost, in: pr).get().latestIteration == 3)
        #expect(requests(server).filter { $0 == "/iterations" }.count == 3)
    }

    @Test func readsTheIterationsAgainWhenThePullRequestMovesToAnotherBranch() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        let thread = CodeFixture.thread(21, at: CodeFixture.location(right: 2...2, madeOn: (2, 2)))
        #expect(try await code.excerpt(of: thread, in: pr).get().latestIteration == 2)
        // Moved to another target, with the same head: an iteration of its own.
        server.on("/pullRequests/7/iterations", json: Fixture.list([
            CodeFixture.iteration(1, source: "s1"), CodeFixture.iteration(2, source: "abc"), CodeFixture.iteration(3, source: "abc", common: "b2"),
        ]))
        server.on("/iterations/3/changes", query: ["$compareTo": "2"], json: CodeFixture.changes([]))
        var moved = pr
        moved.targetBranch = "release"
        let after = try await code.excerpt(of: thread, in: moved).get()
        #expect(after.latestIteration == 3)
        #expect(after.changedSince == false)
        #expect(requests(server).filter { $0 == "/iterations" }.count == 2)
    }

    @Test func saysWhyItCantShowTheCode() async throws {
        let server = codeServer()
        server.on("/blobs/first") { _ in StubServer.Reply(status: 200, headers: [:], body: Data([0x47, 0x49, 0x46, 0x00, 0x01])) }
        let code = PullRequestCode(pr, client: server.client())
        let thread = CodeFixture.thread(21, at: CodeFixture.location(right: 5...5))
        #expect(await code.excerpt(of: thread, in: pr) == .failure(.binary))
        #expect(await code.excerpt(of: CodeFixture.thread(22, at: CodeFixture.location(right: 40...41, madeOn: (2, 2))), in: pr)
            == .failure(.linesNotFound))

        let small = PullRequestCode(pr, source: AzureDevOpsCode(client: codeServer().client()), fileLimit: 16)
        #expect(await small.excerpt(of: thread, in: pr) == .failure(.tooLarge))

        // On the pull request, or on a whole file, it's on no lines.
        #expect(await code.excerpt(of: ReviewThread(id: 1, comments: []), in: pr) == .failure(.notOnLines))
        #expect(await code.excerpt(of: CodeFixture.thread(23, at: ReviewThread.Location(path: "/src/Payments.cs")), in: pr)
            == .failure(.notOnLines))

        let none = StubServer()
        none.on("/pullRequests/7/iterations", json: Fixture.list([]))
        #expect(await PullRequestCode(pr, client: none.client()).excerpt(of: thread, in: pr) == .failure(.noIterations))
    }

    @Test func readsAgainWhatFailedForAWhileButNotWhatIsntThere() async throws {
        let server = codeServer()
        server.on("/blobs/base") { _ in .failure(.notConnectedToInternet) }
        let code = PullRequestCode(pr, client: server.client())
        let thread = CodeFixture.thread(21, at: CodeFixture.location(right: 5...5))
        #expect(await code.excerpt(of: thread, in: pr) == .failure(.unreadable(.offline)))
        server.on("/blobs/base") { _ in CodeFixture.file(CodeFixture.base) }
        #expect(try await code.excerpt(of: thread, in: pr).get().changedSince == true)
        #expect(requests(server).filter { $0 == "/blobs/base" }.count == 2)

        let gone = codeServer()
        gone.on("/blobs/base") { _ in .status(404) }
        let missing = PullRequestCode(pr, client: gone.client())
        #expect(await missing.excerpt(of: thread, in: pr) == .failure(.unreadable(.notFound)))
        #expect(await missing.excerpt(of: thread, in: pr) == .failure(.unreadable(.notFound)))
        #expect(requests(gone).filter { $0 == "/blobs/base" }.count == 1)

        // Whether it changed since, when that couldn't be read, is unknown, and read again next time.
        let later = codeServer()
        later.on("/iterations/2/changes", query: ["$compareTo": "1"]) { _ in .status(500) }
        let unsure = PullRequestCode(pr, client: later.client())
        #expect(try await unsure.excerpt(of: thread, in: pr).get().changedSince == nil)
        later.on("/iterations/2/changes", query: ["$compareTo": "1"], json: CodeFixture.changes([]))
        #expect(try await unsure.excerpt(of: thread, in: pr).get().changedSince == false)
    }

    @Test func readsSeveralThreadsTogetherEachThingOnce() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        let threads = [
            CodeFixture.thread(21, at: CodeFixture.location(right: 5...5)),
            CodeFixture.thread(22, at: CodeFixture.location(right: 8...8)),
            CodeFixture.thread(23, at: CodeFixture.location(left: 5...5)),
            ReviewThread(id: 24, comments: [comment(1, People.sam, "On the pull request", at: t(0))]),
        ]
        let excerpts = await code.excerpts(of: threads, in: pr)
        #expect(Set(excerpts.keys) == [21, 22, 23])
        #expect(try excerpts[22]?.get().lines.first { $0.isCommented }?.text == "line 7½")
        #expect(requests(server).sorted() == ["/blobs/base", "/blobs/first", "/iterations", "/iterations/1/changes 0", "/iterations/2/changes 1"])
    }

    @Test func answersOnlyForItsOwnPullRequest() async throws {
        let server = codeServer()
        let code = PullRequestCode(pr, client: server.client())
        #expect(code.key == pr.key)
        let thread = CodeFixture.thread(21, at: CodeFixture.location(right: 1...1))
        let other = makePR(8)
        #expect(await code.excerpt(of: thread, in: other) == .failure(.otherPullRequest))
        #expect(await code.excerpts(of: [thread, thread], in: other) == [21: .failure(.otherPullRequest)])
        #expect(server.requests.isEmpty)
        // Its own still reads.
        #expect(try await code.excerpt(of: thread, in: pr).get().lines.first?.text == "line 1")
    }
}

// MARK: - Sharing, calling off and limiting reads

/// Code from memory: the made-up pull request's, counting what it's asked, and holding files back while told to.
private actor FakeCode: CodeSource {
    private(set) var asked: [String] = []
    private var holding = false
    private var held: [Int: CheckedContinuation<Void, Error>] = [:]
    private var lastHeld = 0

    func hold(_ holding: Bool) {
        self.holding = holding
        if !holding {
            for turn in held.values { turn.resume() }
            held = [:]
        }
    }

    func iterations(of pullRequest: PullRequest) async throws -> [PRIteration] {
        asked.append("iterations")
        return [PRIteration(id: 1, sourceCommit: "abc", commonCommit: "b1")]
    }

    /// Files added, and one edited that's now the same as "a".
    func changes(of pullRequest: PullRequest, iteration: Int, comparedTo: Int) async throws -> FileChanges {
        asked.append("changes")
        let added = ["a", "b", "c", "d", "f", "g"].map { (name: String) in FileChange(path: "/\(name).cs", kind: .add, objectId: name) }
        return FileChanges(files: added + [FileChange(path: "/e.cs", kind: .edit, objectId: "a", originalObjectId: "e1")])
    }

    func file(of pullRequest: PullRequest, objectId: String, limit: Int) async throws -> FileText {
        asked.append(objectId)
        if holding { try await waitForRelease() }
        return .text("\(objectId) 1\n\(objectId) 2\n")
    }

    func file(of pullRequest: PullRequest, path: String, commit: String, limit: Int) async throws -> FileText {
        throw ADOError.notFound
    }

    private func waitForRelease() async throws {
        lastHeld += 1
        let id = lastHeld
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { turn in held[id] = turn }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        held.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func count(_ name: String) -> Int {
        asked.filter { $0 == name }.count
    }
}

/// How many run at once, and the most that did.
private final class Running: Sendable {
    private let counts = Mutex((now: 0, most: 0))

    var most: Int { counts.withLock { $0.most } }

    func start() {
        counts.withLock {
            $0.now += 1
            $0.most = max($0.most, $0.now)
        }
    }

    func finish() {
        counts.withLock { $0.now -= 1 }
    }
}

/// Holds whatever passes it until it's released, counting them.
private actor Gate {
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var passes = 0

    func pass() async {
        passes += 1
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func release() {
        isOpen = true
        for turn in held { turn.resume() }
        held = []
    }
}

/// Waits for `condition`. `make test` runs every test on one thread, which a long test can keep for seconds on a slow
/// runner, so the deadline is long, and the condition is checked once more after it.
private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    if await condition() { return }
    throw TestError("Timed out waiting for \(what)")
}

/// Code for a pull request with two iterations, holding back what changed from the first to the second while told to.
private actor LaterCode: CodeSource {
    private(set) var asked: [String] = []
    private var held: CheckedContinuation<Void, Error>?

    func iterations(of pullRequest: PullRequest) async throws -> [PRIteration] {
        [PRIteration(id: 1, sourceCommit: "s1", commonCommit: "b"), PRIteration(id: 2, sourceCommit: "abc", commonCommit: "b")]
    }

    func changes(of pullRequest: PullRequest, iteration: Int, comparedTo: Int) async throws -> FileChanges {
        asked.append("changes \(iteration) \(comparedTo)")
        if iteration == 2 {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { held = $0 }
            } onCancel: {
                Task { await self.cancel() }
            }
        }
        return FileChanges(files: [FileChange(path: "/a.cs", kind: .add, objectId: "a")])
    }

    private func cancel() {
        held?.resume(throwing: CancellationError())
        held = nil
    }

    func file(of pullRequest: PullRequest, objectId: String, limit: Int) async throws -> FileText {
        .text("a 1\n")
    }

    func file(of pullRequest: PullRequest, path: String, commit: String, limit: Int) async throws -> FileText {
        throw ADOError.notFound
    }
}

@Suite struct PullRequestCodeSharingTests {
    private let pr = makePR(7)

    private func thread(_ id: Int, _ file: String, line: Int = 1) -> ReviewThread {
        CodeFixture.thread(id, at: CodeFixture.location("/\(file).cs", right: line...line, madeOn: nil, tracking: nil))
    }

    @Test func readsAFileOnceForThreadsThatWaitOnItTogether() async throws {
        let fake = FakeCode()
        await fake.hold(true)
        let code = PullRequestCode(pr, source: fake)
        async let first = code.excerpt(of: thread(1, "a"), in: pr)
        async let second = code.excerpt(of: thread(2, "a", line: 2), in: pr)
        try await waitUntil("the file's read") { await fake.count("a") == 1 }
        await fake.hold(false)
        let (one, two) = await (first, second)
        #expect(try one.get().lines.first { $0.isCommented }?.text == "a 1")
        #expect(try two.get().lines.first { $0.isCommented }?.text == "a 2")
        #expect(await fake.count("a") == 1)
        #expect(await fake.count("iterations") == 1)
    }

    @Test func callsOffAReadThatNoThreadWaitsOnAnymore() async throws {
        let fake = FakeCode()
        await fake.hold(true)
        let code = PullRequestCode(pr, source: fake)
        let asked = Task { await code.excerpt(of: thread(1, "a"), in: pr) }
        try await waitUntil("the file's read") { await fake.count("a") == 1 }
        asked.cancel()
        guard case .failure(.unreadable) = await asked.value else {
            Issue.record("A thread no one waits on anymore still showed its code")
            return
        }
        // It wasn't kept: asked again, it's read again.
        await fake.hold(false)
        #expect(try await code.excerpt(of: thread(1, "a"), in: pr).get().lines.count == 2)
        #expect(await fake.count("a") == 2)
    }

    @Test func keepsReadingWhatAnotherThreadStillWaitsOn() async throws {
        let fake = FakeCode()
        await fake.hold(true)
        let code = PullRequestCode(pr, source: fake)
        let gaveUp = Task { await code.excerpt(of: thread(1, "a"), in: pr) }
        let waits = Task { await code.excerpt(of: thread(2, "a", line: 2), in: pr) }
        try await waitUntil("both threads waiting on the file") { await code.waiting(.object("a")) == 2 }
        gaveUp.cancel()
        try await waitUntil("one thread waiting on the file") { await code.waiting(.object("a")) == 1 }
        await fake.hold(false)
        #expect(try await waits.value.get().lines.first { $0.isCommented }?.text == "a 2")
        #expect(await fake.count("a") == 1)
    }

    @Test func showsNothingToAThreadThatStoppedWaitingAtTheEnd() async throws {
        let fake = LaterCode()
        let code = PullRequestCode(pr, source: fake)
        let location = CodeFixture.location("/a.cs", right: 1...1, madeOn: (1, 1), tracking: nil)
        let asked = Task { await code.excerpt(of: CodeFixture.thread(1, at: location), in: pr) }
        try await waitUntil("what changed since") { await fake.asked.contains("changes 2 1") }
        asked.cancel()
        guard case .failure(.unreadable) = await asked.value else {
            Issue.record("A thread that stopped waiting showed its code, without whether it changed since")
            return
        }
    }

    @Test func comparesAFileOnceForTheThreadsOnIt() async throws {
        let fake = FakeCode()
        let code = PullRequestCode(pr, source: fake)
        let together = await code.excerpts(of: [thread(1, "a"), thread(2, "a", line: 2), thread(3, "b")], in: pr)
        #expect(try together[2]?.get().lines.first { $0.isCommented }?.text == "a 2")
        _ = try await code.excerpt(of: thread(4, "a", line: 2), in: pr).get()
        #expect(await code.comparisonsMade == 2)
    }

    @Test func keepsEveryComparisonUnderWayHoweverMany() async throws {
        let gate = Gate()
        let code = PullRequestCode(pr, source: FakeCode(), comparison: { old, new in
            await gate.pass()
            return LineDiff.comparison(old, new)
        })
        // A's comparison first, then five more files', more than it keeps once made, all held under way.
        let first = Task { await code.excerpt(of: thread(1, "a"), in: pr) }
        try await waitUntil("a's comparison") { await code.comparisonsMade == 1 }
        let others = Task { await code.excerpts(of: ["b", "c", "d", "f", "g"].enumerated().map { thread(2 + $0.offset, $0.element) }, in: pr) }
        try await waitUntil("every comparison") { await code.comparisonsMade == 6 }
        // Another thread on A shares the comparison under way.
        let again = Task { await code.excerpt(of: thread(10, "a", line: 2), in: pr) }
        try await waitUntil("the other thread on A waiting") { await code.waitingOnComparisons == 7 }
        await gate.release()
        #expect(try await again.value.get().lines.first { $0.isCommented }?.text == "a 2")
        _ = await (first.value, others.value)
        #expect(await code.comparisonsMade == 6)
    }

    @Test func callsOffAComparisonNoThreadWaitsOnAnymore() async throws {
        let gate = Gate()
        let code = PullRequestCode(pr, source: FakeCode(), comparison: { old, new in
            await gate.pass()
            return LineDiff.comparison(old, new)
        })
        // Two comparisons under way, as many as run at once, and a third waiting its turn.
        let a = Task { await code.excerpt(of: thread(1, "a"), in: pr) }
        let b = Task { await code.excerpt(of: thread(2, "b"), in: pr) }
        try await waitUntil("two comparisons under way") { await gate.passes == 2 }
        let c = Task { await code.excerpt(of: thread(3, "c"), in: pr) }
        try await waitUntil("a third waiting its turn") { await code.waitingOnComparisons == 3 }
        c.cancel()
        try await waitUntil("the third called off") { await code.waitingOnComparisons == 2 }
        await gate.release()
        _ = await (a.value, b.value)
        guard case .failure(.unreadable) = await c.value else {
            Issue.record("A thread that stopped waiting still showed its code")
            return
        }
        #expect(await gate.passes == 2)
        // Asked again, it's made.
        _ = try await code.excerpt(of: thread(4, "c"), in: pr).get()
        #expect(await gate.passes == 3)
    }

    @Test func forgetsTheFilesReadFirstPastTheMemoryItMayUse() async throws {
        let fake = FakeCode()
        let code = PullRequestCode(pr, source: fake, memoryLimit: 20)
        _ = try await code.excerpt(of: thread(1, "a"), in: pr).get()
        _ = try await code.excerpt(of: thread(2, "b"), in: pr).get()
        _ = try await code.excerpt(of: thread(3, "c"), in: pr).get()
        // The excerpts are kept, but "a" is read again for another thread.
        _ = try await code.excerpt(of: thread(4, "a", line: 2), in: pr).get()
        #expect(await fake.count("a") == 2)
        #expect(await fake.count("c") == 1)
    }

    @Test func letsOnlyAFewRequestsGoAtATime() async throws {
        let limiter = RequestLimiter(limit: 2)
        let running = Running()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await limiter.run {
                        running.start()
                        try await Task.sleep(for: .milliseconds(20))
                        running.finish()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(running.most == 2)
    }

    @Test func aRequestCancelledWhileItWaitsNeverGoesOut() async throws {
        let limiter = RequestLimiter(limit: 1)
        let release = Locked(false)
        let ran = Locked(0)
        let first = Task {
            try await limiter.run {
                while !release.value { try await Task.sleep(for: .milliseconds(5)) }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await limiter.run { ran.increment() } }
        try await Task.sleep(for: .milliseconds(20))
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        release.set(true)
        try await first.value
        #expect(ran.value == 0)
        // The place it waited for went to no one: the next one goes out at once.
        _ = try await limiter.run { ran.increment() }
        #expect(ran.value == 1)
    }
}

// MARK: - The demo

@Suite struct DemoCodeTests {
    @Test func showsTheCodeOfEachOfTheDemosThreadsOnAFile() async throws {
        let now = Date()
        let snapshot = DemoData.update(DemoData.snapshot(now: now), at: now)
        var shown: [Int: ThreadExcerpt] = [:]
        for record in snapshot.records {
            let code = PullRequestCode.demo(record.pullRequest)
            for thread in record.details?.threads ?? [] where thread.filePath != nil {
                let excerpt = try await code.excerpt(of: thread, in: record.pullRequest).get()
                // Its lines, on the side it's on: before the change for one only on lines there.
                let isLeft = thread.location.map { $0.right == nil && $0.left != nil } ?? false
                let lines = try #require(thread.location.flatMap { $0.right ?? $0.left }?.lines ?? thread.line.map { $0...$0 })
                #expect(excerpt.lines.filter(\.isCommented).map { isLeft ? $0.oldNumber : $0.newNumber } == lines.map(Optional.some))
                // Made on a push before the latest, it's on code that changed since.
                #expect(excerpt.changedSince == (excerpt.iteration < excerpt.latestIteration))
                shown[thread.id] = excerpt
            }
        }
        // 4102's backoff, attempts, retry policy, old check, tests and retry options, 4088's delivery estimate, and 4091's
        // rounding and coupons.
        #expect(Set(shown.keys) == [11, 13, 14, 16, 17, 18, 43, 63, 67])
        #expect(shown[16]?.changedSince == true)
        func commented(_ id: Int) -> String? {
            shown[id]?.lines.first { $0.isCommented }?.text
        }
        let backoff = try #require(shown[11])
        #expect(commented(11)?.contains("delay *= 2") == true)
        #expect(backoff.lines.first { $0.isCommented }?.kind == .added)
        #expect(backoff.change == .edit)
        #expect(backoff.latestIteration == 2)
        #expect(commented(13)?.contains("retryOptions.Value.MaxAttempts") == true)
        #expect(commented(14)?.contains("class RetryPolicy") == true)
        #expect(commented(18)?.contains("MaxAttempts") == true)
        #expect(shown[14]?.change == .add)
        #expect(commented(43)?.contains("warehouse.TimeZone") == true)
        #expect(commented(63)?.contains("MidpointRounding.AwayFromZero") == true)
        #expect(shown[63]?.lines.contains { $0.kind == .removed && $0.text.contains("Math.Round(amount, 2);") } == true)
        #expect(commented(67)?.contains("MidpointRounding.AwayFromZero") == true)
        #expect(shown[67]?.lines.contains { $0.kind == .removed && $0.text.contains("Math.Truncate") } == true)
    }

    @Test func comparesTheDemosIterations() async throws {
        let pr = try #require(DemoData.records(now: Date()).first { $0.pullRequest.key.number == 4102 }?.pullRequest)
        let code = PullRequestCode.demo(pr)
        // Made on the first push, which retried 200 ms apart: the second changed it since.
        let location = ReviewThread.Location(path: "/src/PaymentsClient.cs", right: ReviewThread.Span(lines: 74...74),
                                             madeOn: ReviewThread.Comparison(base: 1), changeTrackingId: 1)
        let excerpt = try await code.excerpt(of: CodeFixture.thread(1, at: location), in: pr).get()
        #expect(excerpt.lines.first { $0.isCommented }?.text.contains("RetryDelay") == true)
        #expect(excerpt.changedSince == true)
        // The tests the second push added.
        let added = ReviewThread.Location(path: "/tests/PaymentsClientTests.cs", right: ReviewThread.Span(lines: 1...1),
                                          madeOn: ReviewThread.Comparison(base: 2))
        let tests = try await code.excerpt(of: CodeFixture.thread(2, at: added), in: pr).get()
        #expect(tests.change == .add)
        #expect(tests.lines.allSatisfy { $0.kind == .added })
    }
}
