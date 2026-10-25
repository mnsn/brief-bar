import BriefBarCore
import Foundation
import Testing
@testable import GitHubCore

@Suite struct ClientTests {
    private let answer = Fixture.answer(
        reviewing: [Fixture.pullRequest(1, repository: "octo/api")],
        authored: [Fixture.pullRequest(2, author: Fixture.me, reviewDecision: "APPROVED", rollup: "SUCCESS")]
    )

    @Test func sendsTheOneQueryWithTheCLIsToken() async throws {
        let server = StubServer()
        server.reply(.json(answer))

        let result = try await server.client().pullRequests()

        #expect(result.data.viewer.login == Fixture.me)
        #expect(result.data.reviewing.nodes.map(\.number) == [1])
        #expect(result.data.authored.nodes.map(\.number) == [2])
        #expect(result.errors.isEmpty)

        let received = try #require(server.received.first)
        #expect(server.received.count == 1)
        #expect(received.request.httpMethod == "POST")
        #expect(received.request.url == GitHubClient.endpoint)
        #expect(received.request.value(forHTTPHeaderField: "Authorization") == "bearer \(server.id):0")
        #expect(received.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(received.request.value(forHTTPHeaderField: "Accept") == "application/json")

        #expect(received.json["query"] as? String == PullRequestQuery.text)
        let variables = try #require(received.json["variables"] as? [String: Any])
        #expect(variables["reviewing"] as? String == PullRequestQuery.reviewingSearch)
        #expect(variables["authored"] as? String == PullRequestQuery.authoredSearch)
        #expect(variables["count"] as? Int == PullRequestQuery.count)
        #expect(Set(variables.keys) == ["reviewing", "authored", "count"])
    }

    /// GitHub's GraphQL API takes reads and writes the same way, so the query itself must only read.
    @Test func theQueryOnlyReads() {
        let text = PullRequestQuery.text.lowercased()
        #expect(text.hasPrefix("query "))
        #expect(!text.contains("mutation"))
        #expect(!text.contains("subscription"))
        // Requests to you by name only, not to your teams.
        let reviewing = PullRequestQuery.reviewingSearch.split(separator: " ")
        #expect(reviewing.contains("user-review-requested:@me"))
        #expect(!reviewing.contains("review-requested:@me"))
        #expect(PullRequestQuery.authoredSearch.split(separator: " ").contains("author:@me"))
        for search in [PullRequestQuery.reviewingSearch, PullRequestQuery.authoredSearch] {
            #expect(search.contains("is:pr"))
            #expect(search.contains("is:open"))
            #expect(search.contains("archived:false"))
        }
    }

    @Test func aRejectedTokenIsReplacedOnce() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id)
        server.reply(.text("{\"message\":\"Bad credentials\"}", status: 401), .json(answer))

        let result = try await server.client(tokens: tokens).pullRequests()

        #expect(result.data.viewer.login == Fixture.me)
        #expect(server.received.map(\.token) == ["\(server.id):0", "\(server.id):1"])
        #expect(await tokens.invalidations == 1)
    }

    @Test func aFreshTokenRejectedToo() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id)
        server.always(.text("{\"message\":\"Bad credentials\"}", status: 401))

        await #expect(throws: GitHubError.unauthorized) { try await server.client(tokens: tokens).pullRequests() }
        #expect(server.received.count == 2)
        #expect(await tokens.invalidations == 1)
    }

    @Test func noTokenSendsNothing() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id, error: .signedOut("not logged in"))

        await #expect(throws: GitHubError.auth(.signedOut("not logged in"))) { try await server.client(tokens: tokens).pullRequests() }
        await #expect(throws: GitHubError.auth(.cliNotFound)) {
            try await server.client(tokens: FakeTokens(server.id, error: .cliNotFound)).pullRequests()
        }
        #expect(server.received.isEmpty)
    }

    @Test func waitsAsLongAsGitHubAsks() async throws {
        let server = StubServer()
        server.reply(.text("{\"message\":\"You have exceeded a secondary rate limit.\"}", status: 403, headers: ["Retry-After": "120"]))
        let client = server.client()

        await #expect(throws: GitHubError.throttled(retryAfter: 120)) { try await client.pullRequests() }
        // Asking again before then sends nothing.
        await #expect(throws: GitHubError.self) { try await client.pullRequests() }
        #expect(server.received.count == 1)
    }

    @Test func waitsForTheHourlyLimitToReset() async {
        let server = StubServer()
        let reset = Int(t(5 * minute).timeIntervalSince1970)
        server.reply(.text(
            "{\"message\":\"API rate limit exceeded\"}", status: 403,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"]
        ))

        await #expect(throws: GitHubError.throttled(retryAfter: 300)) { try await server.client().pullRequests() }
    }

    @Test func aRateLimitSaidOnlyInWordsWaitsAMinute() async {
        let server = StubServer()
        server.reply(.text("{\"message\":\"API rate limit exceeded for user\"}", status: 403))
        await #expect(throws: GitHubError.throttled(retryAfter: 60)) { try await server.client().pullRequests() }

        let tooMany = StubServer()
        tooMany.reply(.text("", status: 429))
        await #expect(throws: GitHubError.throttled(retryAfter: 60)) { try await tooMany.client().pullRequests() }
    }

    @Test func aRefusalThatIsntARateLimitDoesntHoldTheNextRequest() async throws {
        let server = StubServer()
        server.reply(.text("{\"message\":\"Resource not accessible by integration\"}", status: 403), .json(answer))
        let client = server.client()

        await #expect(throws: GitHubError.forbidden) { try await client.pullRequests() }
        #expect(try await client.pullRequests().data.viewer.login == Fixture.me)
        #expect(server.received.count == 2)
    }

    @Test func theLastRequestOfTheHourHoldsTheNext() async throws {
        let now = Locked(referenceDate)
        let server = StubServer()
        let reset = Int(t(10 * minute).timeIntervalSince1970)
        server.reply(.json(answer, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"]))
        server.always(.json(answer))
        let client = server.client(now: { now.value })

        #expect(try await client.pullRequests().data.viewer.login == Fixture.me)
        await #expect(throws: GitHubError.throttled(retryAfter: 600)) { try await client.pullRequests() }
        #expect(server.received.count == 1)

        now.set(t(10 * minute + 1))
        #expect(try await client.pullRequests().data.viewer.login == Fixture.me)
        #expect(server.received.count == 2)
    }

    @Test func aRateLimitedAnswerWaits() async {
        let server = StubServer()
        let reset = Int(t(2 * minute).timeIntervalSince1970)
        server.reply(.json(
            ["data": NSNull(), "errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded for user ID 1."]]],
            headers: ["x-ratelimit-reset": "\(reset)"]
        ))
        let client = server.client()

        await #expect(throws: GitHubError.throttled(retryAfter: 120)) { try await client.pullRequests() }
        await #expect(throws: GitHubError.throttled(retryAfter: 120)) { try await client.pullRequests() }
        #expect(server.received.count == 1)

        let noReset = StubServer()
        noReset.reply(.json(["errors": [["type": "RATE_LIMITED", "message": "slow down"]]]))
        await #expect(throws: GitHubError.throttled(retryAfter: 60)) { try await noReset.client().pullRequests() }
    }

    @Test func keepsWhatItCouldReadWithTheErrors() async throws {
        let server = StubServer()
        let saml = ["type": "FORBIDDEN", "message": "Resource protected by organization SAML enforcement."]
        server.reply(.json(Fixture.answer(authored: [Fixture.pullRequest(2)], errors: [saml])))

        let result = try await server.client().pullRequests()
        #expect(result.data.authored.nodes.count == 1)
        #expect(result.errors == [GraphQLError(type: "FORBIDDEN", message: "Resource protected by organization SAML enforcement.")])
    }

    @Test func errorsAndNothingReadFail() async {
        let server = StubServer()
        server.reply(.json(["data": NSNull(), "errors": [["message": "Something went wrong while executing your query."]]]))
        await #expect(throws: GitHubError.graphQL("Something went wrong while executing your query.")) {
            try await server.client().pullRequests()
        }

        let empty = StubServer()
        empty.reply(.json([String: Any]()))
        await #expect(throws: GitHubError.graphQL("no data")) { try await empty.client().pullRequests() }
    }

    @Test func skipsPullRequestsItCantRead() async throws {
        let server = StubServer()
        server.reply(.json(Fixture.answer(
            authored: [NSNull(), ["id": "PR_partial", "number": 9], Fixture.pullRequest(3), [String: Any]()], authoredCount: 4
        )))

        let result = try await server.client().pullRequests()
        #expect(result.data.authored.nodes.map(\.number) == [3])
        #expect(result.data.authored.issueCount == 4)
    }

    @Test func anUnexpectedAnswerIsADecodingError() async throws {
        let server = StubServer()
        server.reply(.text("<html>Unicorn!</html>", status: 200))
        await #expect(throws: GitHubError.self) { try await server.client().pullRequests() }

        let missing = StubServer()
        missing.reply(.json(["data": ["reviewing": ["issueCount": 0, "nodes": []]]]))
        do {
            _ = try await missing.client().pullRequests()
            Issue.record("Expected a decoding error")
        } catch let GitHubError.decoding(message) {
            #expect(message.contains("viewer"))
        }
    }

    @Test func otherStatusesAreHTTPErrors() async {
        for status in [404, 500, 502] {
            let server = StubServer()
            server.reply(.text("", status: status))
            await #expect(throws: GitHubError.http(status)) { try await server.client().pullRequests() }
        }
    }

    @Test func networkFailures() async {
        let cases: [(URLError.Code, GitHubError)] = [
            (.notConnectedToInternet, .offline),
            (.timedOut, .network("GitHub didn't answer in time.")),
            (.cannotFindHost, .network("Can't reach GitHub.")),
        ]
        for (code, expected) in cases {
            let server = StubServer()
            server.reply(.failure(code))
            await #expect(throws: expected) { try await server.client().pullRequests() }
        }
    }

    @Test func mapsURLErrors() {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff] {
            #expect(GitHubClient.map(URLError(code)) == .offline)
        }
        #expect(GitHubClient.map(URLError(.dnsLookupFailed)) == .network("Can't reach GitHub."))
        guard case .network = GitHubClient.map(URLError(.badServerResponse)) else {
            Issue.record("Expected a network error")
            return
        }
    }

    @Test func waitsAreBounded() throws {
        func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: GitHubClient.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        let now = referenceDate
        let epoch = Int(now.timeIntervalSince1970)

        #expect(GitHubClient.rateLimitWait(response(403, ["Retry-After": "99999"]), body: Data(), now: now) == 3_600)
        #expect(GitHubClient.rateLimitWait(response(403, ["Retry-After": "0"]), body: Data(), now: now) == nil)
        #expect(GitHubClient.rateLimitWait(response(403, ["Retry-After": "soon"]), body: Data(), now: now) == nil)
        #expect(GitHubClient.rateLimitWait(response(403, ["x-ratelimit-remaining": "3", "x-ratelimit-reset": "\(epoch + 60)"]), body: Data(), now: now) == nil)

        #expect(GitHubClient.resetWait(response(200, ["x-ratelimit-reset": "\(epoch - 60)"]), now: now) == 1)
        #expect(GitHubClient.resetWait(response(200, ["x-ratelimit-reset": "\(epoch + 86_400)"]), now: now) == 3_600)
        #expect(GitHubClient.resetWait(response(200, ["x-ratelimit-reset": "\(epoch + 90)"]), now: now) == 90)
        #expect(GitHubClient.resetWait(response(200, ["x-ratelimit-reset": "later"]), now: now) == nil)
        #expect(GitHubClient.resetWait(response(200, [:]), now: now) == nil)
    }

    @Test func requestsCarryNoCookiesOrCache() {
        let configuration = GitHubClient.makeSession().configuration
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpAdditionalHeaders?["User-Agent"] as? String == "BriefBar")
    }
}
