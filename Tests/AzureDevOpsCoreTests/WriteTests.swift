import Foundation
import Testing
@testable import AzureDevOpsCore

/// What BriefBar changes in Azure DevOps, with Make Changes in Azure DevOps on: a reply in a thread and a thread's status
/// (`ADOWrite`), which only `ADOClient.send(_:)` sends; and nothing else, which every other request, a GET, can't.
@Suite struct WriteTests {
    let pullRequest = makePR(7)
    var address: ThreadAddress { ThreadAddress(pullRequest, thread: 12) }

    // MARK: What it can send

    /// Two changes, and only those: a new one comes with its kind, which fails this until it's tested here.
    @Test func makesOnlyTheChangesItLists() {
        #expect(ADOWrite.Kind.allCases == [.reply, .setStatus])
        for kind in ADOWrite.Kind.allCases {
            let write = sample(kind)
            #expect(write.kind == kind)
            switch kind {
            case .reply:
                #expect(write.method == "POST")
                #expect(write.url.absoluteString
                    == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/threads/12/comments?api-version=7.1")
                #expect(String(decoding: write.body, as: UTF8.self) == #"{"commentType":1,"content":"Thanks, done","parentCommentId":1}"#)
            case .setStatus:
                #expect(write.method == "PATCH")
                #expect(write.url.absoluteString
                    == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/threads/12?api-version=7.1")
                #expect(String(decoding: write.body, as: UTF8.self) == #"{"status":2}"#)
            }
        }
    }

    /// A reply says what you wrote as you wrote it: Markdown, quotes, slashes and all, which JSON encodes.
    @Test func aReplySaysWhatYouWroteAsYouWroteIt() throws {
        let markdown = "Fixed in `RetryOptions`: see https://example.invalid/a/b \"why\"\n\n- one\n- two ✓"
        let write = ADOWrite.reply(address, markdown: markdown, parentCommentId: 3)
        let body = try #require(JSONSerialization.jsonObject(with: write.body) as? [String: Any])
        #expect(body["content"] as? String == markdown)
        #expect(body["parentCommentId"] as? Int == 3)
        #expect(body["commentType"] as? Int == 1)
        #expect(body.count == 3)
    }

    /// Each status by the number Azure DevOps' API takes for it, as its samples send it (`CommentThreadStatus`).
    @Test func sendsEachStatusByItsNumber() throws {
        let numbers: [ThreadStatus: Int] = [.active: 1, .fixed: 2, .wontFix: 3, .closed: 4, .byDesign: 5, .pending: 6]
        for status in ThreadStatus.allCases {
            let body = try #require(JSONSerialization.jsonObject(with: ADOWrite.setStatus(address, status).body) as? [String: Any])
            #expect(body as? [String: Int] == ["status": try #require(numbers[status])], "\(status)")
        }
    }

    @Test func namesStatusesAsAzureDevOpsDoes() {
        #expect(ThreadStatus.allCases.map(\.title) == ["Active", "Pending", "Resolved", "Won't Fix", "Closed", "By Design"])
        #expect(ThreadStatus("fixed") == .fixed)
        #expect(ThreadStatus("unknown") == nil)
        #expect(ThreadStatus(nil) == nil)
        // Resolved as a thread says it is.
        for status in ThreadStatus.allCases {
            let thread = ReviewThread(id: 1, status: status.rawValue, comments: [comment(1, People.sam, at: t(0))])
            #expect(status.isResolved == thread.isResolved, "\(status)")
            #expect(thread.threadStatus == status)
        }
    }

    /// As Azure DevOps' own menu: By Design only for a thread that has it already.
    @Test func offersTheStatusesAzureDevOpsDoes() {
        #expect(ThreadStatus.choices(for: .active) == [.active, .pending, .fixed, .wontFix, .closed])
        #expect(ThreadStatus.choices(for: nil) == [.active, .pending, .fixed, .wontFix, .closed])
        #expect(ThreadStatus.choices(for: .byDesign) == [.active, .pending, .fixed, .wontFix, .closed, .byDesign])
    }

    // MARK: Sending

    @Test func sendsAReplyWithTheSignInAndHeadersOfARead() async throws {
        let server = StubServer()
        server.on("/pullRequests/7/threads/12/comments") { _ in
            .json(Fixture.comment(4, People.me, "Thanks, done", at: t(0)))
        }
        let answer = try await server.client().send(sample(.reply))
        guard case .comment(let comment) = answer else {
            Issue.record("Expected a comment, got \(answer)")
            return
        }
        #expect(comment.id == 4)
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url == sample(.reply).url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(server.id)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-TFS-FedAuthRedirect") == "Suppress")
        #expect(body(of: request) == sample(.reply).body)
    }

    @Test func setsAStatusWithAPatchOfItAlone() async throws {
        let server = StubServer()
        server.on("/pullRequests/7/threads/12") { _ in
            .json(Fixture.thread(12, comments: [Fixture.comment(1, People.sam, "Cap it?", at: t(-hour))], status: "fixed", published: t(-hour)))
        }
        let answer = try await server.client().send(sample(.setStatus))
        guard case .thread(let thread) = answer else {
            Issue.record("Expected a thread, got \(answer)")
            return
        }
        #expect(thread.status == "fixed")
        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(body(of: request) == Data(#"{"status":2}"#.utf8))
    }

    /// Azure DevOps acts on no request whose sign-in it rejects, so a change is sent again only then, with a fresh token; a
    /// change that fails otherwise isn't sent twice, which could make it twice.
    @Test func sendsAChangeAgainOnlyForASignInAzureDevOpsRejected() async throws {
        let server = StubServer()
        let attempts = Locked(0)
        server.on("/threads/12/comments") { _ in
            attempts.increment() == 1 ? .status(401) : .json(Fixture.comment(4, People.me, "Thanks, done", at: t(0)))
        }
        let tokens = server.tokens
        _ = try await server.client(tokens: tokens).send(sample(.reply))
        #expect(server.requests.count == 2)
        #expect(await tokens.invalidations == 1)

        for reply in [StubServer.Reply.status(500), .failure(.timedOut), .failure(.networkConnectionLost), .status(400)] {
            let failing = StubServer()
            failing.on("/threads/12/comments") { _ in reply }
            await #expect(throws: ADOError.self) { try await failing.client().send(sample(.reply)) }
            #expect(failing.requests.count == 1)
        }
    }

    /// When Azure DevOps refuses a change, the error says why, as Azure DevOps said it, which the thread shows; a pull request
    /// that's completed or abandoned is one it knows.
    @Test func saysWhyAzureDevOpsRefusedAChange() async throws {
        let cases: [(StubServer.Reply, ADOError)] = [
            (.json([
                "message": "TF401181: The pull request cannot be edited due to its state.",
                "typeKey": "GitPullRequestNotEditableException",
            ], status: 400), .refused(.notEditable, message: "TF401181: The pull request cannot be edited due to its state.")),
            (.json(["message": "TF401181: The pull request cannot be edited due to its state."], status: 409),
             .refused(.notEditable, message: "TF401181: The pull request cannot be edited due to its state.")),
            (.json(["message": "A thread can have up to 500 comments.", "typeKey": "InvalidArgumentValueException"], status: 400),
             .refused(nil, message: "A thread can have up to 500 comments.")),
            (StubServer.Reply(status: 400, headers: [:], body: Data("Bad".utf8)), .refused(nil, message: nil)),
            (.status(403), .forbidden),
            (.status(404), .notFound),
            (.status(500), .http(500)),
            (.failure(.notConnectedToInternet), .offline),
            (.failure(.timedOut), .network(ADOClient.unansweredMessage)),
        ]
        for (reply, expected) in cases {
            let server = StubServer()
            server.on("/threads/12") { _ in reply }
            await #expect(throws: expected) { try await server.client().send(sample(.setStatus)) }
        }
        // What it said stays out of the log, where errors' descriptions go.
        #expect(ADOError.refused(nil, message: "A thread can have up to 500 comments.").description == "Azure DevOps refused the change.")
    }

    /// Made, but its answer can't be read: the answer says so, rather than that it failed, for the pull request to be read
    /// again instead.
    @Test func aChangeMadeWhoseAnswerCantBeReadIsMadeAllTheSame() async throws {
        let server = StubServer()
        server.on("/threads/12/comments") { _ in .json(["unexpected": true]) }
        let answer = try await server.client().send(sample(.reply))
        guard case .unreadable = answer else {
            Issue.record("Expected an unreadable answer, got \(answer)")
            return
        }
    }

    /// A change goes only where it's sent, as a read does.
    @Test(.timeLimit(.minutes(1)))
    func followsNoRedirectWithAChange() async {
        let server = StubServer()
        server.on("/threads/12") { _ in .redirect(to: "https://elsewhere.example/contoso/_apis/threads/12") }
        await #expect(throws: ADOError.redirected) { try await server.client().send(sample(.setStatus)) }
        #expect(server.requests.count == 1)
    }

    // MARK: Nothing else

    /// Every read is a GET, whatever it reads.
    @Test func everyReadIsAGET() {
        let urls = [
            ADOEndpoint.threads(organization: "contoso", projectId: "p1", repositoryId: "r1", pullRequestId: 7),
            ADOEndpoint.pullRequest(organization: "contoso", id: 7), ADOEndpoint.profile,
        ]
        for url in urls {
            #expect(ADOClient.request(url, token: "t").httpMethod == "GET")
            #expect(ADOClient.request(url, token: "t", accept: "application/octet-stream").httpMethod == "GET")
            #expect(ADOClient.request(url, token: "t").httpBody == nil)
        }
    }

    /// Only the client makes requests in AzureDevOpsCore, and it sets a method only twice: GET for every read, and a change's
    /// own, one of `ADOWrite`'s, for `send(_:)`.
    @Test func onlyTheClientMakesRequestsAndOnlyGETsOrTheChangesItLists() throws {
        let sources = try coreSources()
        #expect(sources.filter { $0.text.contains("URLRequest(") }.map(\.name) == ["ADOClient.swift"])
        let methods = sources.flatMap { file in file.text.matches(of: /\.httpMethod\s*=\s*([^\n]+)/).map { (file.name, String($0.output.1)) } }
        #expect(methods.map(\.0) == ["ADOClient.swift", "ADOClient.swift"])
        #expect(Set(methods.map(\.1)) == [#""GET""#, "write.method"])
        // No other way to send something: an upload, or a task of its own.
        for pattern in [#"upload("#, #"uploadTask("#, #"dataTask("#, #"httpBodyStream"#] {
            #expect(sources.filter { $0.text.contains(pattern) }.isEmpty, "\(pattern)")
        }
        #expect(sources.filter { $0.text.contains("httpBody =") }.map(\.name) == ["ADOClient.swift"])
    }

    // MARK: What it changes

    /// A reply's answer adds its comment, as Azure DevOps keeps it, mentions named; the same change twice is the same as once.
    @Test func aReplyAddsItsCommentOnce() throws {
        let thread = ReviewThread(id: 12, comments: [comment(1, People.sam, "Cap it?", at: t(-hour))])
        let details = makeDetails(for: pullRequest, threads: [thread, ReviewThread(id: 13, comments: [comment(1, People.alex, at: t(-day))])])
        let answer = try Fixture.decode(
            ADOComment.self, Fixture.comment(2, People.me, "Done, @<\(People.sam.id.uppercased())>", at: t(0))
        )
        let write = ADOWrite.reply(address, markdown: "Done", parentCommentId: 1)
        let change = try #require(ThreadChange(.comment(answer), to: write, pullRequest: pullRequest, known: thread))
        #expect(change.thread == 12)
        #expect(change.status == nil)
        #expect(change.comments.map(\.markdown) == ["Done, @Sam Rivera"])

        let changed = details.applying(change)
        #expect(changed.threads[0].comments.map(\.id) == [1, 2])
        #expect(changed.threads[0].comments.last?.author.id == People.me.id)
        #expect(changed.threads[0].status == "active")
        #expect(changed.threads[1] == details.threads[1])
        #expect(changed.lastActivity == t(0))
        #expect(changed.applying(change) == changed)
    }

    /// A status's answer is the thread as Azure DevOps has it now: its status, and a reply that came meanwhile.
    @Test func aStatusSetsItAndBringsWhatCameMeanwhile() throws {
        let thread = ReviewThread(id: 12, comments: [comment(1, People.sam, "Cap it?", at: t(-hour))])
        let details = makeDetails(for: pullRequest, threads: [thread])
        let answer = try Fixture.decode(ADOThread.self, Fixture.thread(12, comments: [
            Fixture.comment(1, People.sam, "Cap it?", at: t(-hour)),
            Fixture.comment(2, People.priya, "Or make it configurable", at: t(-minute)),
        ], status: "wontFix", published: t(-hour)))
        let change = try #require(ThreadChange(.thread(answer), to: .setStatus(address, .wontFix), pullRequest: pullRequest, known: thread))
        let changed = details.applying(change)
        #expect(changed.threads[0].status == "wontFix")
        #expect(changed.threads[0].comments.map(\.id) == [1, 2])
        #expect(changed.threads[0].isResolved)
        // Not another thread's answer, nor one that can't be read.
        #expect(ThreadChange(.thread(answer), to: .setStatus(ThreadAddress(pullRequest, thread: 13), .fixed), pullRequest: pullRequest, known: nil) == nil)
        #expect(ThreadChange(.unreadable("missing id"), to: .setStatus(address, .fixed), pullRequest: pullRequest, known: thread) == nil)
    }

    /// A thread the details don't have stays out: reading the pull request again brings it.
    @Test func aChangeToAThreadItDoesntHaveChangesNothing() {
        let details = makeDetails(for: pullRequest, threads: [ReviewThread(id: 13, comments: [comment(1, People.alex, at: t(-day))])])
        #expect(details.applying(ThreadChange(thread: 12, comments: [comment(2, People.me, at: t(0))], status: "fixed")) == details)
    }

    // MARK: What it says when it can't

    @Test func saysWhyAChangeDidntHappen() {
        let cases: [(Error, ADOWriteProblem)] = [
            (ADOError.forbidden, .notAllowed),
            (ADOError.refused(.notEditable, message: "TF401181"), .closed),
            (ADOError.refused(nil, message: "Too long"), .refused("Too long")),
            (ADOError.notFound, .gone),
            (ADOError.offline, .offline),
            (ADOError.unauthorized, .signedOut),
            (ADOError.auth(.signedOut("Run az login")), .signedOut),
            (ADOError.throttled(retryAfter: 30), .slowedDown),
            (ADOError.network(ADOClient.unansweredMessage), .unanswered),
            (ADOError.http(500), .failed("Azure DevOps answered with HTTP 500.")),
        ]
        for (error, problem) in cases {
            #expect(ADOWriteProblem(error) == problem, "\(error)")
        }
        #expect(ADOWriteProblem.notAllowed.sentence(.reply) == "Azure DevOps says you may not reply here.")
        #expect(ADOWriteProblem.notAllowed.sentence(.setStatus) == "Azure DevOps says you may not change this thread's status.")
        #expect(ADOWriteProblem.offline.sentence(.reply) == "You're offline. Your reply is kept: send it once you're back.")
        #expect(ADOWriteProblem.refused("Too long").sentence(.reply) == "Azure DevOps refused it: Too long")
        #expect(ADOWriteProblem.refused(nil).sentence(.setStatus) == "Azure DevOps refused it.")
        // What may have been made all the same is read again.
        #expect(ADOWriteProblem.unanswered.mayHaveGone)
        #expect(!ADOWriteProblem.notAllowed.mayHaveGone)
        #expect(!ADOWriteProblem.closed.mayHaveGone)
    }

    // MARK: Helpers

    private func sample(_ kind: ADOWrite.Kind) -> ADOWrite {
        switch kind {
        case .reply: .reply(address, markdown: "Thanks, done", parentCommentId: 1)
        case .setStatus: .setStatus(address, .fixed)
        }
    }

    /// What a request sent, which reaches the stub as a stream.
    private func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// AzureDevOpsCore's sources, by file name.
    private func coreSources(filePath: String = #filePath) throws -> [(name: String, text: String)] {
        let folder = URL(fileURLWithPath: filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/AzureDevOpsCore")
            .standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
}
