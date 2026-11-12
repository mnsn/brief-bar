import Foundation
import Testing
@testable import AzureDevOpsCore

/// What BriefBar changes in Azure DevOps, with Make Changes in Azure DevOps on: a reply in a thread, a thread's status, a
/// comment of yours edited or deleted, a pull request's tags, and the sprint a work item of yours is in (`ADOWrite`), which
/// only `ADOClient.send(_:as:)` sends; and nothing else, which every other request, a GET, can't.
@Suite struct WriteTests {
    let pullRequest = makePR(7)
    var address: ThreadAddress { ThreadAddress(pullRequest, thread: 12) }

    // MARK: What it can send

    /// Seven changes, and only those: a new one comes with its kind, which fails this until it's tested here.
    @Test func makesOnlyTheChangesItLists() {
        #expect(ADOWrite.Kind.allCases == [.reply, .setStatus, .editComment, .deleteComment, .addTag, .removeTag, .setIteration])
        for kind in ADOWrite.Kind.allCases {
            let write = sample(kind)
            #expect(write.kind == kind)
            // Each on the pull request it changes, or one of whose threads it does; or on the work item it moves.
            if kind.isWorkItem {
                #expect(write.pullRequest == nil)
                #expect(write.workItem == WorkItemKey("Contoso", 5052))
            } else {
                #expect(write.pullRequest == PullRequestAddress(pullRequest))
                #expect(write.workItem == nil)
                #expect(write.contentType == "application/json")
            }
            switch kind {
            case .reply:
                #expect(write.thread == address)
                #expect(write.method == "POST")
                #expect(write.url.absoluteString
                    == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/threads/12/comments?api-version=7.1")
                #expect(String(decoding: write.body, as: UTF8.self) == #"{"commentType":1,"content":"Thanks, done","parentCommentId":1}"#)
            case .setStatus:
                #expect(write.thread == address)
                #expect(write.method == "PATCH")
                #expect(write.url.absoluteString
                    == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/threads/12?api-version=7.1")
                #expect(String(decoding: write.body, as: UTF8.self) == #"{"status":2}"#)
            case .editComment:
                #expect(write.thread == address)
                #expect(write.kind.isComment)
                #expect(write.method == "PATCH")
                #expect(write.url.absoluteString
                    == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/threads/12/comments/3?api-version=7.1")
                #expect(String(decoding: write.body, as: UTF8.self) == #"{"content":"Capped it at 30 seconds."}"#)
            case .deleteComment:
                #expect(write.thread == address)
                #expect(write.kind.isComment)
                #expect(write.method == "DELETE")
                #expect(write.url.absoluteString
                    == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/threads/12/comments/3?api-version=7.1")
                #expect(write.body.isEmpty)
            case .addTag:
                #expect(write.thread == nil)
                #expect(write.kind.isTags)
                #expect(write.method == "POST")
                #expect(write.url.absoluteString
                    == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/labels?api-version=7.1")
                #expect(String(decoding: write.body, as: UTF8.self) == #"{"name":"deploy-eu"}"#)
            case .removeTag:
                #expect(write.thread == nil)
                #expect(write.kind.isTags)
                #expect(write.method == "DELETE")
                #expect(write.url.absoluteString
                    == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/labels/0f5d2c1e-tag?api-version=7.1")
                #expect(write.body.isEmpty)
            case .setIteration:
                #expect(write.thread == nil)
                #expect(write.method == "PATCH")
                #expect(write.url.absoluteString == "https://dev.azure.com/contoso/_apis/wit/workitems/5052?api-version=7.1")
                #expect(write.contentType == "application/json-patch+json")
                // Where it is first, so that Azure DevOps moves nothing that someone moved meanwhile; then where it goes.
                #expect(String(decoding: write.body, as: UTF8.self) == #"[{"op":"test","path":"/fields/System.IterationPath","value":"Storefront\\Sprint 41"},"#
                    + #"{"op":"add","path":"/fields/System.IterationPath","value":"Storefront\\Sprint 42"}]"#)
            }
        }
        #expect(!ADOWrite.Kind.reply.isTags)
        #expect(!ADOWrite.Kind.setStatus.isTags)
        #expect(ADOWrite.Kind.allCases.filter(\.isComment) == [.editComment, .deleteComment])
        #expect(ADOWrite.Kind.allCases.filter(\.isTags) == [.addTag, .removeTag])
        #expect(ADOWrite.Kind.allCases.filter(\.isWorkItem) == [.setIteration])
    }

    /// A move says where the work item is and where it goes, as their paths are, quotes and all, which JSON encodes, and
    /// nothing else of it.
    @Test func aMoveSaysWhereItWasAndWhereItGoesAndNothingElse() throws {
        let write = ADOWrite.setIteration(WorkItemKey("contoso", 5052), from: #"Shop\Q4 "Polish"\Sprint 41"#, to: "Shop")
        let body = try #require(JSONSerialization.jsonObject(with: write.body) as? [[String: String]])
        #expect(body == [
            ["op": "test", "path": "/fields/System.IterationPath", "value": #"Shop\Q4 "Polish"\Sprint 41"#],
            ["op": "add", "path": "/fields/System.IterationPath", "value": "Shop"],
        ])
    }

    /// An edit says what you wrote instead, as you wrote it, and nothing else of the comment.
    @Test func anEditSaysWhatYouWroteAndNothingElse() throws {
        let markdown = "Capped at `RetryOptions.MaxDelay`: see https://example.invalid/a/b \"why\", @<\(People.sam.id)>\n\n- one ✓"
        let write = ADOWrite.editComment(address, comment: 3, markdown: markdown)
        let body = try #require(JSONSerialization.jsonObject(with: write.body) as? [String: Any])
        #expect(body as? [String: String] == ["content": markdown])
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
        let answer = try await server.client().send(sample(.reply), as: nil)
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
        let answer = try await server.client().send(sample(.setStatus), as: nil)
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
        _ = try await server.client(tokens: tokens).send(sample(.reply), as: nil)
        #expect(server.requests.count == 2)
        #expect(await tokens.invalidations == 1)

        for reply in [StubServer.Reply.status(500), .failure(.timedOut), .failure(.networkConnectionLost), .status(400)] {
            let failing = StubServer()
            failing.on("/threads/12/comments") { _ in reply }
            await #expect(throws: ADOError.self) { try await failing.client().send(sample(.reply), as: nil) }
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
            await #expect(throws: expected) { try await server.client().send(sample(.setStatus), as: nil) }
        }
        // What it said stays out of the log, where errors' descriptions go.
        #expect(ADOError.refused(nil, message: "A thread can have up to 500 comments.").description == "Azure DevOps refused the change.")
    }

    /// Made, but its answer can't be read: the answer says so, rather than that it failed, for the pull request to be read
    /// again instead.
    @Test func aChangeMadeWhoseAnswerCantBeReadIsMadeAllTheSame() async throws {
        // Any answer that says it was made, whatever it holds: not JSON, or nothing at all, never sends it again.
        let answers: [StubServer.Reply] = [
            .json(["unexpected": true]),
            StubServer.Reply(status: 201, headers: [:], body: Data("<html>Created</html>".utf8)),
            StubServer.Reply(status: 200, headers: ["Content-Type": "text/plain"], body: Data()),
            StubServer.Reply(status: 204, headers: [:], body: Data()),
        ]
        for reply in answers {
            let server = StubServer()
            server.on("/threads/12/comments") { _ in reply }
            let answer = try await server.client().send(sample(.reply), as: nil)
            guard case .unreadable = answer else {
                Issue.record("Expected an unreadable answer for \(reply.status), got \(answer)")
                continue
            }
            #expect(server.requests.count == 1, "\(reply.status)")
        }
    }

    /// A change called off before it goes, as when Make Changes in Azure DevOps is turned off while a token comes, never
    /// goes.
    @Test func aChangeCalledOffBeforeItGoesNeverGoes() async throws {
        let server = StubServer()
        server.on("/threads/12") { _ in .json(Fixture.thread(12, comments: [], status: "fixed", published: t(0))) }
        let client = server.client()
        let write = sample(.setStatus)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(write, as: nil)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.isEmpty)
    }

    /// A 503, which Azure Front Door answers once Azure DevOps takes too long, may come after Azure DevOps made the change: it
    /// says what no answer in time does, after one request, for the thread to be read again before it goes again. A 429 asks
    /// to slow down, before anything was made; and a read's 503 does too.
    @Test func aChangeAnswered503MayHaveBeenMade() async throws {
        func problem(_ reply: StubServer.Reply) async -> (ADOWriteProblem?, requests: Int) {
            let server = StubServer()
            server.on("/threads/12/comments") { _ in reply }
            do {
                _ = try await server.client().send(sample(.reply), as: nil)
                return (nil, server.requests.count)
            } catch {
                return (ADOWriteProblem(error, now: t(0)), server.requests.count)
            }
        }
        let unavailable = await problem(.status(503))
        #expect(unavailable.0 == .unanswered)
        #expect(unavailable.0?.mayHaveGone == true)
        #expect(unavailable.requests == 1)
        let throttled = await problem(.status(429))
        #expect(throttled.0 == .slowedDown(until: t(ADOClient.retryAfterUnsaid)))
        #expect(throttled.0?.mayHaveGone == false)
        // A tag's change too, after which its pull request's tags are read again.
        for kind in [ADOWrite.Kind.addTag, .removeTag] {
            let server = StubServer()
            server.on("/pullRequests/7/labels") { _ in .status(503) }
            await #expect(throws: ADOError.network(ADOClient.unansweredMessage)) { try await server.client().send(sample(kind), as: nil) }
            #expect(server.requests.count == 1)
        }

        let reading = StubServer()
        reading.on("/pullRequests/7/threads") { _ in .status(503) }
        do {
            _ = try await reading.client().get(
                ADOEndpoint.threads(organization: Fixture.org, projectId: "p1", repositoryId: "r1", pullRequestId: 7), as: ADOList<ADOThread>.self
            )
            Issue.record("A read answered 503 read something")
        } catch {
            guard case ADOError.throttled? = error as? ADOError else {
                Issue.record("Expected a read answered 503 to slow down, got \(error)")
                return
            }
        }
    }

    /// A change goes only as whom it was asked for as, the account the list was read as: when someone else signed in to the
    /// Azure CLI since, as the list doesn't know yet, it sends nothing. When that isn't known, it goes.
    @Test func aChangeGoesOnlyAsWhomItWasAskedFor() async throws {
        let server = StubServer()
        server.on("/threads/12/comments") { _ in .json(Fixture.comment(4, People.me, "Thanks, done", at: t(0))) }
        let tokens = server.tokens
        await tokens.signIn(as: "home/robin")
        let client = server.client(tokens: tokens)
        _ = try await client.send(sample(.reply), as: "home/robin")
        #expect(server.requests.count == 1)

        await tokens.signIn(as: "home/sam")
        await #expect(throws: ADOError.otherAccount) { try await client.send(sample(.reply), as: "home/robin") }
        #expect(server.requests.count == 1)
        _ = try await client.send(sample(.reply), as: nil)
        #expect(server.requests.count == 2)
    }

    /// In an organization in another directory, a token is a guest's there, with an ID of its own, and may have been kept
    /// from before someone else signed in: whom your sign-in is for is read again, fresh, to tell.
    @Test func aChangeInAnotherDirectoryReadsWhoSignedInFresh() async throws {
        let server = StubServer()
        server.put(Fixture.org, in: Tenants.other)
        server.on("/threads/12/comments") { _ in .json(Fixture.comment(4, People.me, "Thanks, done", at: t(0))) }
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        let robin = "\(Tenants.home)/robin"
        await tokens.signIn(as: robin)
        await tokens.signIn(to: Tenants.other, as: "\(Tenants.other)/robin-guest")
        let client = server.client(tokens: tokens)
        // Your directory's token first, which Azure DevOps names the organization's directory for; then that one's, a guest's.
        _ = try await client.send(sample(.reply), as: robin)
        #expect(server.requests.map(\.tenant) == [Tenants.home, Tenants.other])
        let invalidations = await tokens.invalidations

        // Sam signed in since: the guest's token, read fresh, then your directory's, which says so.
        await tokens.signIn(as: "\(Tenants.home)/sam")
        await #expect(throws: ADOError.otherAccount) { try await client.send(sample(.reply), as: robin) }
        #expect(server.requests.count == 2)
        #expect(await tokens.invalidations == invalidations + 2)
    }

    /// A guest's token kept from before someone else signed in isn't used for a change: it's read again fresh, as the Azure
    /// CLI gets it for whom it's signed in to now, and your directory's after it says that's you.
    @Test func aGuestsTokenKeptFromBeforeIsntUsedForAChange() async throws {
        let server = StubServer()
        server.put(Fixture.org, in: Tenants.other)
        server.on("/threads/12/comments") { _ in .json(Fixture.comment(4, People.me, "Thanks, done", at: t(0))) }
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        let robin = "\(Tenants.home)/robin"
        await tokens.signIn(as: robin)
        await tokens.signIn(to: Tenants.other, as: "\(Tenants.other)/robin-guest")
        let client = server.client(tokens: tokens)
        _ = try await client.send(sample(.reply), as: robin)

        await tokens.keep("\(Tenants.other)/sam-guest", for: Tenants.other)
        let handed = await tokens.handedOut.count
        _ = try await client.send(sample(.reply), as: robin)
        #expect(Array(await tokens.handedOut.dropFirst(handed)) == ["\(Tenants.other)/sam-guest", "\(Tenants.other)/robin-guest", robin])
        #expect(server.requests.map(\.tenant) == [Tenants.home, Tenants.other, Tenants.other])
    }

    /// A change that has gone isn't called off with its caller, which wouldn't take it back: Azure DevOps' answer comes all
    /// the same, to say it was made.
    @Test(.timeLimit(.minutes(5)))
    func aChangeThatWentWhenCalledOffAnswersAllTheSame() async throws {
        let server = StubServer()
        let answers = Locked(false)
        var held = StubServer.Reply.json(Fixture.comment(4, People.me, "Thanks, done", at: t(0)))
        held.waitsFor = { answers.value }
        let reply = held
        server.on("/threads/12/comments") { _ in reply }
        let client = server.client()
        let write = sample(.reply)
        let sending = Task { try await client.send(write, as: nil) }
        try await waitUntil("the change to go") { server.requests.count == 1 }
        sending.cancel()
        answers.set(true)
        guard case .comment(let comment) = try await sending.value else {
            Issue.record("Expected Azure DevOps' answer")
            return
        }
        #expect(comment.id == 4)
        #expect(server.requests.count == 1)
    }

    /// A change goes only where it's sent, as a read does.
    @Test(.timeLimit(.minutes(5)))
    func followsNoRedirectWithAChange() async {
        let server = StubServer()
        server.on("/threads/12") { _ in .redirect(to: "https://elsewhere.example/contoso/_apis/threads/12") }
        await #expect(throws: ADOError.redirected) { try await server.client().send(sample(.setStatus), as: nil) }
        #expect(server.requests.count == 1)
    }

    // MARK: Your comments

    /// Editing a comment is a PATCH of what it says alone, with a read's sign-in and headers, and Azure DevOps answers with the
    /// comment as it keeps it now.
    @Test func editsACommentWithAPatchOfWhatItSays() async throws {
        let server = StubServer()
        server.on("/pullRequests/7/threads/12/comments/3") { _ in
            var comment = Fixture.comment(3, People.me, "Capped it at 30 seconds.", at: t(-hour))
            comment["lastContentUpdatedDate"] = iso(t(0))
            return .json(comment)
        }
        let answer = try await server.client().send(sample(.editComment), as: nil)
        guard case .comment(let comment) = answer else {
            Issue.record("Expected a comment, got \(answer)")
            return
        }
        #expect(comment.id == 3)
        #expect(comment.lastContentUpdatedDate == t(0))
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url == sample(.editComment).url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(server.id)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-TFS-FedAuthRedirect") == "Suppress")
        #expect(body(of: request) == Data(#"{"content":"Capped it at 30 seconds."}"#.utf8))
    }

    /// Deleting a comment sends nothing but its address, and whatever Azure DevOps answers it with, it was deleted: its
    /// reference says 200, with nothing.
    @Test func deletesACommentWithADeleteOfNothingMore() async throws {
        let replies: [StubServer.Reply] = [
            StubServer.Reply(status: 200, headers: [:], body: Data()),
            StubServer.Reply(status: 204, headers: [:], body: Data()),
            .json([String: Any]()),
        ]
        for reply in replies {
            let server = StubServer()
            server.on("/pullRequests/7/threads/12/comments/3") { _ in reply }
            let answer = try await server.client().send(sample(.deleteComment), as: nil)
            guard case .done = answer else {
                Issue.record("Expected it done, got \(answer) for \(reply.status)")
                continue
            }
            let request = try #require(server.requests.first)
            #expect(server.requests.count == 1)
            #expect(request.httpMethod == "DELETE")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
            #expect(body(of: request) == nil)
        }
    }

    /// Why an edit or a deletion didn't happen, as for a reply: no permission, a completed pull request, a comment gone,
    /// offline, slowed down; and one answered 503 may have been made, after one request.
    @Test func saysWhyAChangeToACommentDidntHappen() async throws {
        let cases: [(StubServer.Reply, ADOError)] = [
            (.json(["message": "TF401181: The pull request cannot be edited due to its state.", "typeKey": "GitPullRequestNotEditableException"],
                   status: 400), .refused(.notEditable, message: "TF401181: The pull request cannot be edited due to its state.")),
            (.status(403), .forbidden),
            (.status(404), .notFound),
            (.failure(.notConnectedToInternet), .offline),
            (StubServer.Reply(status: 429, headers: ["Retry-After": "120"], body: Data()), .throttled(retryAfter: 120)),
            (.status(503), .network(ADOClient.unansweredMessage)),
        ]
        for kind in [ADOWrite.Kind.editComment, .deleteComment] {
            for (reply, expected) in cases {
                let server = StubServer()
                server.on("/pullRequests/7/threads/12/comments/3") { _ in reply }
                await #expect(throws: expected) { try await server.client().send(sample(kind), as: nil) }
                #expect(server.requests.count == 1, "\(kind) \(reply.status)")
            }
        }
    }

    @Test func saysWhatHappenedToAChangeToACommentInASentence() {
        #expect(ADOWriteProblem.notAllowed.sentence(.editComment) == "Azure DevOps says you may not edit this comment.")
        #expect(ADOWriteProblem.notAllowed.sentence(.deleteComment) == "Azure DevOps says you may not delete this comment.")
        #expect(ADOWriteProblem.closed.sentence(.deleteComment)
            == "Azure DevOps takes no change to this pull request anymore: it's completed or abandoned.")
        #expect(ADOWriteProblem.gone.sentence(.editComment).hasPrefix("Azure DevOps doesn't have this comment anymore"))
        #expect(ADOWriteProblem.offline.sentence(.editComment) == "You're offline. Your edit is kept: save it once you're back.")
        #expect(ADOWriteProblem.offline.sentence(.deleteComment) == "You're offline: try again once you're back.")
        let until = Date(timeIntervalSinceReferenceDate: 60 * 1_000 + 40)
        #expect(ADOWriteProblem.slowedDown(until: until).sentence(.deleteComment)
            == "Azure DevOps asked BriefBar to slow down, until \(ADOWriteProblem.time(until)): try again then.")
        #expect(ADOWriteProblem.unanswered.sentence(.editComment).hasSuffix("won't save it twice."))
        #expect(ADOWriteProblem.unanswered.sentence(.deleteComment).contains("may have been deleted"))
        #expect(ADOWriteProblem.unconfirmed.sentence(.editComment).contains("didn't save it again"))
        #expect(ADOWriteProblem.unconfirmed.sentence(.deleteComment).contains("didn't delete it again"))
        #expect(ADOWriteProblem.otherAccount.sentence(.editComment).contains("sent nothing as them"))
        #expect(ADOWriteProblem.notListed.sentence(.editComment) == "This pull request is no longer in your lists, so your edit wasn't saved.")
        #expect(ADOWriteProblem.notListed.sentence(.deleteComment) == "This pull request is no longer in your lists, so your comment wasn't deleted.")
        #expect(ADOWriteProblem.failed("HTTP 500.").sentence(.editComment) == "Couldn't save your edit: HTTP 500.")
        #expect(ADOWriteProblem.failed("HTTP 500.").sentence(.deleteComment) == "Couldn't delete your comment: HTTP 500.")
        #expect(ADOWriteProblem.refused("Too long").sentence(.editComment) == "Azure DevOps refused it: Too long")
    }

    // MARK: Tags

    /// A tag's name goes as you typed it, in JSON, whatever it has in it; taking one off goes by the tag's ID, or else its
    /// name, which the address encodes.
    @Test func aTagGoesAsYouNamedIt() throws {
        let tagged = ADOWrite.addTag(PullRequestAddress(pullRequest), name: "deploy \"eu\"/west ✓")
        let body = try #require(JSONSerialization.jsonObject(with: tagged.body) as? [String: Any])
        #expect(body as? [String: String] == ["name": "deploy \"eu\"/west ✓"])
        let untagged = ADOWrite.removeTag(PullRequestAddress(pullRequest), tag: "team/payments v2")
        #expect(untagged.url.absoluteString.hasSuffix("/pullRequests/7/labels/team%2Fpayments%20v2?api-version=7.1"))
    }

    /// Adding a tag answers with it, as the project has it, and its spelling there.
    @Test func addsATagWithAPostOfItsName() async throws {
        let server = StubServer()
        server.on("/pullRequests/7/labels") { _ in
            .json(["id": "0f5d2c1e-tag", "name": "Deploy-EU", "active": true, "url": NSNull()])
        }
        let answer = try await server.client().send(sample(.addTag), as: nil)
        guard case .tag(let tag) = answer else {
            Issue.record("Expected a tag, got \(answer)")
            return
        }
        #expect(tag.name == "Deploy-EU")
        #expect(tag.id == "0f5d2c1e-tag")
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(body(of: request) == Data(#"{"name":"deploy-eu"}"#.utf8))
    }

    /// Taking a tag off sends nothing but its address, and whatever Azure DevOps answers it with, nothing (204), nothing in a
    /// 200 or JSON, it was taken off. A sign-in it didn't take still isn't: the change is sent again only then.
    @Test func removesATagWithADeleteOfNothingMore() async throws {
        let replies: [StubServer.Reply] = [
            StubServer.Reply(status: 204, headers: [:], body: Data()),
            StubServer.Reply(status: 200, headers: [:], body: Data()),
            .json([String: Any]()),
            StubServer.Reply(status: 200, headers: ["Content-Type": "text/plain"], body: Data("OK".utf8)),
        ]
        for reply in replies {
            let server = StubServer()
            server.on("/pullRequests/7/labels/0f5d2c1e-tag") { _ in reply }
            let answer = try await server.client().send(sample(.removeTag), as: nil)
            guard case .done = answer else {
                Issue.record("Expected it done, got \(answer) for \(reply.status)")
                continue
            }
            let request = try #require(server.requests.first)
            #expect(server.requests.count == 1)
            #expect(request.httpMethod == "DELETE")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
            #expect(body(of: request) == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(server.id)")
        }

        let signedOut = StubServer()
        let attempts = Locked(0)
        signedOut.on("/pullRequests/7/labels/0f5d2c1e-tag") { _ in
            attempts.increment() == 1 ? .status(401) : StubServer.Reply(status: 204, headers: [:], body: Data())
        }
        guard case .done = try await signedOut.client().send(sample(.removeTag), as: nil) else {
            Issue.record("Expected it done after a fresh sign-in")
            return
        }
        #expect(signedOut.requests.count == 2)
    }

    /// Moving a work item sends its JSON Patch as one, and answers with the work item as Azure DevOps has it now.
    @Test func movesAWorkItemWithAPatchThatTestsWhereItWas() async throws {
        let server = StubServer()
        server.on("/contoso/_apis/wit/workitems/5052") { _ in
            .json(WorkFixture.workItem(5052, "Task", "Remove the old cart cookie", iteration: "Storefront\\Sprint 42"))
        }
        let answer = try await server.client().send(sample(.setIteration), as: nil)
        guard case .workItem(let item) = answer else {
            Issue.record("Expected a work item, got \(answer)")
            return
        }
        #expect(item.id == 5052)
        #expect(item.fields.iterationPath == "Storefront\\Sprint 42")
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url == sample(.setIteration).url)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json-patch+json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(server.id)")
        #expect(body(of: request) == sample(.setIteration).body)
    }

    /// A change is asked whether it's still wanted before each try, once its token came: one that isn't, as what it changes
    /// moved while the token came, never goes; and after Azure DevOps turned down a token, it's asked again before the try
    /// with a fresh one.
    @Test func aChangeNoLongerWantedOnceItsTokenCameNeverGoes() async throws {
        let server = StubServer()
        server.on("/contoso/_apis/wit/workitems/5052") { _ in
            .json(WorkFixture.workItem(5052, "Task", "Remove the old cart cookie", iteration: "Storefront\\Sprint 42"))
        }
        await #expect(throws: CancellationError.self) {
            try await server.client().send(sample(.setIteration), as: nil, while: { false })
        }
        #expect(server.requests.isEmpty)

        let expired = StubServer()
        let attempts = Locked(0)
        expired.on("/contoso/_apis/wit/workitems/5052") { _ in
            attempts.increment() == 1 ? .status(401) : .json(WorkFixture.workItem(5052, "Task", "Remove the old cart cookie"))
        }
        let asked = Locked(0)
        await #expect(throws: CancellationError.self) {
            try await expired.client().send(sample(.setIteration), as: nil, while: { asked.increment() == 1 })
        }
        #expect(asked.value == 2)
        #expect(expired.requests.count == 1)
    }

    /// Why a move didn't happen: someone moved it meanwhile, which fails its test, as Azure DevOps says; no permission; a work
    /// item that isn't there, or you can't see. Each sent once.
    @Test func saysWhyAMoveDidntHappen() async throws {
        let cases: [(StubServer.Reply, ADOError)] = [
            (.json(["message": "Test operation failed for field 'System.IterationPath'."], status: 400),
             .refused(nil, message: "Test operation failed for field 'System.IterationPath'.")),
            (.status(403), .forbidden),
            (.status(404), .notFound),
            (.failure(.notConnectedToInternet), .offline),
            (.failure(.timedOut), .network(ADOClient.unansweredMessage)),
        ]
        for (reply, expected) in cases {
            let server = StubServer()
            server.on("/_apis/wit/workitems/5052") { _ in reply }
            await #expect(throws: expected) { try await server.client().send(sample(.setIteration), as: nil) }
            #expect(server.requests.count == 1)
        }
    }

    @Test func saysWhatHappenedToAMoveInASentence() {
        #expect(ADOWriteProblem.notAllowed.sentence(.setIteration) == "Azure DevOps says you may not change this work item.")
        #expect(ADOWriteProblem.gone.sentence(.setIteration).contains("doesn't have this work item anymore"))
        #expect(ADOWriteProblem.offline.sentence(.setIteration) == "You're offline: try again once you're back.")
        #expect(ADOWriteProblem.unanswered.sentence(.setIteration).contains("it may have moved"))
        #expect(ADOWriteProblem.refused("Test operation failed.").sentence(.setIteration) == "Azure DevOps refused it: Test operation failed.")
        #expect(ADOWriteProblem.failed("HTTP 500.").sentence(.setIteration) == "Couldn't move it: HTTP 500.")
        // Pull requests' sentences as they were.
        #expect(ADOWriteProblem.notAllowed.sentence(.addTag) == "Azure DevOps says you may not change this pull request's tags.")
    }

    /// Why a tag's change didn't happen, as for a thread's: a completed pull request, no permission, a tag that isn't on it.
    @Test func saysWhyATagsChangeDidntHappen() async throws {
        let cases: [(StubServer.Reply, ADOError)] = [
            (.json(["message": "TF401181: The pull request cannot be edited due to its state.", "typeKey": "GitPullRequestNotEditableException"],
                   status: 400), .refused(.notEditable, message: "TF401181: The pull request cannot be edited due to its state.")),
            (.status(403), .forbidden),
            (.status(404), .notFound),
            (.failure(.notConnectedToInternet), .offline),
        ]
        for kind in [ADOWrite.Kind.addTag, .removeTag] {
            for (reply, expected) in cases {
                let server = StubServer()
                server.on("/pullRequests/7/labels") { _ in reply }
                await #expect(throws: expected) { try await server.client().send(sample(kind), as: nil) }
                #expect(server.requests.count == 1)
            }
        }
    }

    @Test func saysWhatHappenedToATagsChangeInASentence() {
        #expect(ADOWriteProblem.notAllowed.sentence(.addTag) == "Azure DevOps says you may not change this pull request's tags.")
        #expect(ADOWriteProblem.notAllowed.sentence(.removeTag) == "Azure DevOps says you may not change this pull request's tags.")
        #expect(ADOWriteProblem.closed.sentence(.addTag)
            == "Azure DevOps takes no change to this pull request anymore: it's completed or abandoned.")
        #expect(ADOWriteProblem.offline.sentence(.addTag) == "You're offline: try again once you're back.")
        #expect(ADOWriteProblem.signedOut.sentence(.removeTag).hasPrefix("The Azure CLI isn't signed in"))
        #expect(ADOWriteProblem.gone.sentence(.removeTag).contains("doesn't have that tag on this pull request"))
        #expect(ADOWriteProblem.gone.sentence(.addTag).contains("doesn't have this pull request anymore"))
        #expect(ADOWriteProblem.unanswered.sentence(.addTag).contains("reads the tags again"))
        #expect(ADOWriteProblem.failed("HTTP 500.").sentence(.addTag) == "Couldn't add the tag: HTTP 500.")
        #expect(ADOWriteProblem.failed("HTTP 500.").sentence(.removeTag) == "Couldn't remove the tag: HTTP 500.")
        #expect(ADOWriteProblem.refused("Too long").sentence(.addTag) == "Azure DevOps refused it: Too long")
        #expect(ADOWriteProblem.notListed.sentence(.addTag) == "This pull request is no longer in your lists, so its tags didn't change.")
        #expect(ADOWriteProblem.notListed.sentence(.removeTag) == ADOWriteProblem.notListed.sentence(.addTag))
        // Threads' sentences as they were.
        #expect(ADOWriteProblem.notAllowed.sentence(.reply) == "Azure DevOps says you may not reply here.")
        #expect(ADOWriteProblem.offline.sentence(.setStatus) == "You're offline: try again once you're back.")
    }

    // MARK: Nothing else

    /// Every read is a GET, whatever it reads.
    @Test func everyReadIsAGET() {
        let urls = [
            ADOEndpoint.threads(organization: "contoso", projectId: "p1", repositoryId: "r1", pullRequestId: 7),
            ADOEndpoint.pullRequest(organization: "contoso", id: 7), ADOEndpoint.profile,
            ADOEndpoint.assignedToMe(organization: "contoso", project: "p1"),
            ADOEndpoint.teamIterations(team: WorkFixture.team),
        ]
        for url in urls {
            #expect(ADOClient.request(url, token: "t").httpMethod == "GET")
            #expect(ADOClient.request(url, token: "t", accept: "application/octet-stream").httpMethod == "GET")
            #expect(ADOClient.request(url, token: "t").httpBody == nil)
        }
    }

    /// Only the client makes requests in AzureDevOpsCore, and it sets a method only twice: GET for every read, and a change's
    /// own, one of `ADOWrite`'s, for `send(_:as:)`.
    @Test(.onTestThreads) func onlyTheClientMakesRequestsAndOnlyGETsOrTheChangesItLists() throws {
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

    /// An edit's answer is the comment as Azure DevOps keeps it now, in place of what it said, edited, mentions named, as it
    /// was published; the same twice is the same as once, and a comment that says it already, or that isn't there, stays.
    @Test func anEditReplacesWhatTheCommentSaid() throws {
        let thread = ReviewThread(id: 12, comments: [
            comment(1, People.sam, "Cap it?", at: t(-hour)), comment(3, People.me, "Done", at: t(-minute)),
        ])
        let details = makeDetails(for: pullRequest, threads: [thread])
        var json = Fixture.comment(3, People.me, "Done, @<\(People.sam.id.uppercased())>: capped at 30 seconds.", at: t(-minute))
        json["lastContentUpdatedDate"] = iso(t(0))
        let answer = try Fixture.decode(ADOComment.self, json)
        let write = ADOWrite.editComment(address, comment: 3, markdown: "Done")
        let change = try #require(ThreadChange(.comment(answer), to: write, pullRequest: pullRequest, known: thread, at: t(5)))
        #expect(change.thread == 12)
        #expect(change.comments.isEmpty)
        #expect(change.edited.map(\.markdown) == ["Done, @Sam Rivera: capped at 30 seconds."])
        #expect(change.edited.first?.editedAt == t(0))

        let changed = details.applying(change)
        #expect(changed.threads[0].comments.map(\.id) == [1, 3])
        #expect(changed.threads[0].comments[1].markdown == "Done, @Sam Rivera: capped at 30 seconds.")
        #expect(changed.threads[0].comments[1].publishedAt == t(-minute))
        #expect(changed.threads[0].comments[1].editedAt == t(0))
        #expect(changed.threads[0].comments[0] == thread.comments[0])
        #expect(changed.lastActivity == details.lastActivity)
        #expect(changed.applying(change) == changed)
        // Read with what it says now, though without when it was edited: it has it.
        var read = changed
        read.threads[0].comments[1].editedAt = nil
        #expect(read.applying(change) == read)
        // Edited, though Azure DevOps doesn't say when: as it answered.
        json["lastContentUpdatedDate"] = nil
        let undated = try #require(ThreadChange(
            .comment(try Fixture.decode(ADOComment.self, json)), to: write, pullRequest: pullRequest, known: thread, at: t(5)
        ))
        #expect(undated.edited.first?.editedAt == t(5))
        // Or, when it says when anything of it last changed, then, by its own clock.
        json["lastUpdatedDate"] = iso(t(3))
        let updated = try #require(ThreadChange(
            .comment(try Fixture.decode(ADOComment.self, json)), to: write, pullRequest: pullRequest, known: thread, at: t(5)
        ))
        #expect(updated.edited.first?.editedAt == t(3))
        // Not another comment's answer, nor a comment the thread doesn't have.
        #expect(ThreadChange(.comment(answer), to: .editComment(address, comment: 4, markdown: "Done"), pullRequest: pullRequest,
                             known: thread) == nil)
        #expect(details.applying(ThreadChange(thread: 12, edited: [comment(9, People.me, "New", at: t(0))])) == details)
    }

    /// An edit's answer never puts back what a later edit of the comment replaced, as one made elsewhere that a read had before
    /// the answer came: Azure DevOps dates each edit. It changes nothing then, so that the list is done with it. Over a comment
    /// edited before it, or never, it shows.
    @Test func anEditNeverReplacesALaterEditOfTheComment() throws {
        let thread = ReviewThread(id: 12, comments: [comment(1, People.sam, "Cap it?", at: t(-hour)), comment(3, People.me, "Done", at: t(-minute))])
        var json = Fixture.comment(3, People.me, "Done, capped.", at: t(-minute))
        json["lastContentUpdatedDate"] = iso(t(5))
        let write = ADOWrite.editComment(address, comment: 3, markdown: "Done, capped.")
        let change = try #require(ThreadChange(.comment(try Fixture.decode(ADOComment.self, json)), to: write, pullRequest: pullRequest,
                                               known: thread, at: t(6)))
        var later = thread
        later.comments[1].text = "Done, capped at 30 seconds."
        later.comments[1].markdown = "Done, capped at 30 seconds."
        later.comments[1].editedAt = t(10)
        let read = makeDetails(for: pullRequest, threads: [later])
        #expect(read.applying(change) == read)

        var earlier = later
        earlier.comments[1].editedAt = t(1)
        #expect(makeDetails(for: pullRequest, threads: [earlier]).applying(change).threads[0].comments[1].markdown == "Done, capped.")
        #expect(makeDetails(for: pullRequest, threads: [thread]).applying(change).threads[0].comments[1].markdown == "Done, capped.")
    }

    /// A deletion's answer says nothing: the comment leaves its thread, and the thread leaves too once none of its comments is
    /// left, as Azure DevOps deletes it then. The same twice is the same as once.
    @Test func aDeletionTakesTheCommentAndThenItsThread() throws {
        let thread = ReviewThread(id: 12, comments: [
            comment(1, People.me, "Cap it?", at: t(-hour)), comment(2, People.sam, "Done", at: t(-minute)),
        ])
        let other = ReviewThread(id: 13, comments: [comment(1, People.alex, at: t(-day))])
        let details = makeDetails(for: pullRequest, threads: [thread, other])
        let change = try #require(ThreadChange(.done, to: .deleteComment(address, comment: 1), pullRequest: pullRequest, known: thread))
        #expect(change == ThreadChange(thread: 12, deleted: [1]))
        let changed = details.applying(change)
        #expect(changed.threads.map(\.id) == [12, 13])
        #expect(changed.threads[0].comments.map(\.id) == [2])
        #expect(changed.applying(change) == changed)
        let emptied = changed.applying(ThreadChange(thread: 12, deleted: [2]))
        #expect(emptied.threads.map(\.id) == [13])
        #expect(emptied.applying(change) == emptied)
        // A tag's answer, the same, isn't a comment's.
        #expect(ThreadChange(.done, to: .setStatus(address, .fixed), pullRequest: pullRequest, known: thread) == nil)
    }

    /// Only a comment of yours that someone wrote, rather than a code change's, can be edited or deleted; system comments and
    /// deleted ones are never read. When it was edited is when what it says changed, a second after it was published or more.
    @Test func onlyYourOwnWrittenCommentsCanBeChanged() throws {
        var edited = Fixture.comment(4, People.me, "Edited", at: t(-hour))
        edited["lastContentUpdatedDate"] = iso(t(-minute))
        var unedited = Fixture.comment(5, People.me, "As it was", at: t(-hour + 1))
        unedited["lastContentUpdatedDate"] = iso(t(-hour + 1.4))
        let json = Fixture.thread(12, comments: [
            Fixture.comment(1, People.me, "Mine", at: t(-5 * hour)),
            Fixture.comment(2, People.sam, "Sam's", at: t(-4 * hour)),
            Fixture.comment(3, People.me, "Deleted", at: t(-3 * hour), deleted: true),
            Fixture.comment(6, People.me, "Policy says", at: t(-3 * hour), type: "system"),
            Fixture.comment(7, People.me, "Updated the code", at: t(-2 * hour), type: "codeChange"),
            edited, unedited,
        ], published: t(-5 * hour))
        let thread = try #require(ReviewThread(try Fixture.decode(ADOThread.self, json), names: [:]))
        #expect(thread.comments.map(\.id) == [1, 2, 7, 4, 5])
        let me = People.me.id.uppercased()
        #expect(thread.comments.filter { $0.isEditable(by: me) }.map(\.id) == [1, 4, 5])
        #expect(thread.comments.filter { $0.isEditable(by: People.sam.id) }.map(\.id) == [2])
        #expect(thread.comments.allSatisfy { !$0.isEditable(by: nil) })
        #expect(thread.comments.first { $0.id == 4 }?.editedAt == t(-minute))
        #expect(thread.comments.first { $0.id == 5 }?.editedAt == nil)
        #expect(thread.comments.first { $0.id == 1 }?.editedAt == nil)
        // The demo's, which say no type.
        #expect(comment(1, People.me, at: t(0)).isEditable(by: People.me.id))
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
            (ADOError.throttled(retryAfter: 30), .slowedDown(until: t(30))),
            (ADOError.network(ADOClient.unansweredMessage), .unanswered),
            (ADOError.otherAccount, .otherAccount),
            (ADOError.http(500), .failed("Azure DevOps answered with HTTP 500.")),
        ]
        for (error, problem) in cases {
            #expect(ADOWriteProblem(error, now: t(0)) == problem, "\(error)")
        }
        #expect(ADOWriteProblem.notAllowed.sentence(.reply) == "Azure DevOps says you may not reply here.")
        #expect(ADOWriteProblem.notAllowed.sentence(.setStatus) == "Azure DevOps says you may not change this thread's status.")
        #expect(ADOWriteProblem.offline.sentence(.reply) == "You're offline. Your reply is kept: send it once you're back.")
        #expect(ADOWriteProblem.refused("Too long").sentence(.reply) == "Azure DevOps refused it: Too long")
        // Slowed down, until when Azure DevOps asked, to the minute it ends in, never sooner.
        let until = Date(timeIntervalSinceReferenceDate: 60 * 1_000 + 40)
        #expect(ADOWriteProblem.time(until) == Date(timeIntervalSinceReferenceDate: 60 * 1_001).formatted(date: .omitted, time: .shortened))
        #expect(ADOWriteProblem.time(Date(timeIntervalSinceReferenceDate: 60 * 1_000)) == ADOWriteProblem.time(Date(timeIntervalSinceReferenceDate: 60 * 999 + 1)))
        #expect(ADOWriteProblem.slowedDown(until: until).sentence(.reply)
            == "Azure DevOps asked BriefBar to slow down, until \(ADOWriteProblem.time(until)): try again then.")
        #expect(ADOWriteProblem.slowedDown(until: until).sentence(.addTag).hasSuffix("until \(ADOWriteProblem.time(until)): try again then."))
        #expect(ADOWriteProblem.refused(nil).sentence(.setStatus) == "Azure DevOps refused it.")
        // A reply that may have gone isn't sent again until its thread was read again.
        #expect(ADOWriteProblem.unanswered.sentence(.reply).hasSuffix("won't send it twice."))
        #expect(ADOWriteProblem.unconfirmed.sentence(.reply).contains("didn't send it again"))
        // What may have been made all the same is read again.
        #expect(ADOWriteProblem.unanswered.mayHaveGone)
        #expect(ADOWriteProblem.unconfirmed.mayHaveGone)
        #expect(!ADOWriteProblem.notAllowed.mayHaveGone)
        #expect(!ADOWriteProblem.closed.mayHaveGone)
        // Nothing went as someone else, nor for a pull request that left your lists.
        #expect(!ADOWriteProblem.otherAccount.mayHaveGone)
        #expect(!ADOWriteProblem.notListed.mayHaveGone)
        #expect(ADOWriteProblem.notListed.sentence(.reply) == "This pull request is no longer in your lists, so your reply didn't go.")
        #expect(ADOWriteProblem.otherAccount.sentence(.reply).contains("sent nothing as them"))
    }

    // MARK: Helpers

    private func sample(_ kind: ADOWrite.Kind) -> ADOWrite {
        switch kind {
        case .reply: .reply(address, markdown: "Thanks, done", parentCommentId: 1)
        case .setStatus: .setStatus(address, .fixed)
        case .editComment: .editComment(address, comment: 3, markdown: "Capped it at 30 seconds.")
        case .deleteComment: .deleteComment(address, comment: 3)
        case .addTag: .addTag(PullRequestAddress(pullRequest), name: "deploy-eu")
        case .removeTag: .removeTag(PullRequestAddress(pullRequest), tag: "0f5d2c1e-tag")
        case .setIteration: .setIteration(WorkItemKey("Contoso", 5052), from: "Storefront\\Sprint 41", to: "Storefront\\Sprint 42")
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
