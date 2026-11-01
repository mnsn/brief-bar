using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using BriefBar.Core.GitHub;

namespace BriefBar.Core.Tests.GitHub;

/// Reading GitHub: the one query, with the GitHub CLI's token, and what GitHub answers. The Swift tests' `ClientTests`.
public sealed class ClientTests
{
    static JsonObject Answer => GitHubFixture.Answer(
        reviewing: [GitHubFixture.PullRequest(number: 1, repository: "octo/api")],
        authored: [GitHubFixture.PullRequest(number: 2, author: GitHubFixture.Me, reviewDecision: "APPROVED", rollup: "SUCCESS")]);

    static Dictionary<string, string> Headers(params (string Name, string Value)[] headers) =>
        headers.ToDictionary(keySelector: header => header.Name, elementSelector: header => header.Value, comparer: StringComparer.OrdinalIgnoreCase);

    [Fact]
    public async Task SendsTheOneQueryWithTheCLIsToken()
    {
        var server = new GitHubStubServer();
        server.Reply(StubReply.Json(body: Answer));
        using var client = server.Client();

        var result = await client.PullRequestsAsync(cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: GitHubFixture.Me, actual: result.Data.Viewer.Login);
        Assert.Equal(expected: [1], actual: result.Data.Reviewing.Nodes.Select(selector: node => node.Number));
        Assert.Equal(expected: [2], actual: result.Data.Authored.Nodes.Select(selector: node => node.Number));
        Assert.Empty(collection: result.Errors);

        var request = Assert.Single(collection: server.Requests);
        Assert.Equal(expected: HttpMethod.Post, actual: request.Method);
        Assert.Equal(expected: GitHubClient.Endpoint, actual: request.Url);
        Assert.Equal(expected: "bearer token-0", actual: request.Authorization);
        Assert.Equal(expected: "application/json", actual: request.ContentType);
        Assert.Equal(expected: "application/json", actual: request.Accept);

        var sent = server.Sent(index: 0);
        Assert.Equal(expected: PullRequestQuery.Text, actual: (string?)sent["query"]);
        var variables = sent["variables"]!.AsObject();
        Assert.Equal(expected: PullRequestQuery.ReviewingSearch, actual: (string?)variables["reviewing"]);
        Assert.Equal(expected: PullRequestQuery.AuthoredSearch, actual: (string?)variables["authored"]);
        Assert.Equal(expected: PullRequestQuery.Count, actual: (int?)variables["count"]);
        Assert.Equal(expected: ["authored", "count", "reviewing"], actual: variables.Select(selector: variable => variable.Key).Order(comparer: StringComparer.Ordinal));
        Assert.Equal(expected: ["query", "variables"], actual: sent.Select(selector: member => member.Key).Order(comparer: StringComparer.Ordinal));
    }

    /// GitHub's GraphQL API takes reads and writes the same way, so the query itself must only read.
    [Fact]
    public void TheQueryOnlyReads()
    {
        var text = PullRequestQuery.Text.ToLowerInvariant();
        Assert.StartsWith(expectedStartString: "query ", actualString: text, comparisonType: StringComparison.Ordinal);
        Assert.DoesNotContain(expectedSubstring: "mutation", actualString: text, comparisonType: StringComparison.Ordinal);
        Assert.DoesNotContain(expectedSubstring: "subscription", actualString: text, comparisonType: StringComparison.Ordinal);
        // Its lines end as the Mac's do, whatever the checkout's line endings.
        Assert.DoesNotContain(expectedSubstring: "\r", actualString: PullRequestQuery.Text, comparisonType: StringComparison.Ordinal);
        // Requests to you by name only, not to your teams.
        var reviewing = PullRequestQuery.ReviewingSearch.Split(separator: ' ');
        Assert.Contains(expected: "user-review-requested:@me", collection: reviewing);
        Assert.DoesNotContain(expected: "review-requested:@me", collection: reviewing);
        Assert.Contains(expected: "author:@me", collection: PullRequestQuery.AuthoredSearch.Split(separator: ' '));
        foreach (var search in new[] { PullRequestQuery.ReviewingSearch, PullRequestQuery.AuthoredSearch })
        {
            Assert.Contains(expectedSubstring: "is:pr", actualString: search, comparisonType: StringComparison.Ordinal);
            Assert.Contains(expectedSubstring: "is:open", actualString: search, comparisonType: StringComparison.Ordinal);
            Assert.Contains(expectedSubstring: "archived:false", actualString: search, comparisonType: StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task ARejectedTokenIsReplacedOnce()
    {
        var server = new GitHubStubServer();
        var tokens = new FakeGitHubTokens();
        server.Reply(GitHubStubServer.Text(text: """{"message":"Bad credentials"}""", status: 401), StubReply.Json(body: Answer));
        using var client = server.Client(tokens: tokens);

        var result = await client.PullRequestsAsync(cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: GitHubFixture.Me, actual: result.Data.Viewer.Login);
        Assert.Equal(expected: ["bearer token-0", "bearer token-1"], actual: server.Tokens);
        Assert.Equal(expected: 1, actual: tokens.Invalidations);
    }

    [Fact]
    public async Task AFreshTokenRejectedToo()
    {
        var server = new GitHubStubServer();
        var tokens = new FakeGitHubTokens();
        server.Always(reply: GitHubStubServer.Text(text: """{"message":"Bad credentials"}""", status: 401));
        using var client = server.Client(tokens: tokens);

        var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: GitHubError.Unauthorized, actual: error.Error);
        Assert.Equal(expected: 2, actual: server.Requests.Count);
        Assert.Equal(expected: 1, actual: tokens.Invalidations);
    }

    [Fact]
    public async Task NoTokenSendsNothing()
    {
        var server = new GitHubStubServer();
        var cancellationToken = TestContext.Current.CancellationToken;
        using (var signedOut = server.Client(tokens: new FakeGitHubTokens(error: GitHubAuthError.SignedOut(message: "not logged in"))))
        {
            var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => signedOut.PullRequestsAsync(cancellationToken: cancellationToken));
            Assert.Equal(expected: GitHubError.FromAuth(error: GitHubAuthError.SignedOut(message: "not logged in")), actual: error.Error);
        }
        using (var withoutCli = server.Client(tokens: new FakeGitHubTokens(error: GitHubAuthError.CliNotFound)))
        {
            var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => withoutCli.PullRequestsAsync(cancellationToken: cancellationToken));
            Assert.Equal(expected: GitHubError.FromAuth(error: GitHubAuthError.CliNotFound), actual: error.Error);
        }
        Assert.Empty(collection: server.Requests);
    }

    [Fact]
    public async Task WaitsAsLongAsGitHubAsks()
    {
        var server = new GitHubStubServer();
        server.Reply(GitHubStubServer.Text(text: """{"message":"You have exceeded a secondary rate limit."}""", status: 403, headers: Headers(("Retry-After", "120"))));
        using var client = server.Client();
        var cancellationToken = TestContext.Current.CancellationToken;

        var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: GitHubError.Throttled(retryAfter: TimeSpan.FromSeconds(value: 120)), actual: error.Error);
        // Asking again before then sends nothing.
        await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: cancellationToken));
        Assert.Single(collection: server.Requests);
    }

    [Fact]
    public async Task WaitsForTheHourlyLimitToReset()
    {
        var server = new GitHubStubServer();
        var reset = TestTimes.T(seconds: 5 * GitHubFixture.Minute).ToUnixTimeSeconds().ToString(provider: System.Globalization.CultureInfo.InvariantCulture);
        server.Reply(GitHubStubServer.Text(text: """{"message":"API rate limit exceeded"}""", status: 403, headers: Headers(("x-ratelimit-remaining", "0"), ("x-ratelimit-reset", reset))));
        using var client = server.Client();

        var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: GitHubError.Throttled(retryAfter: TimeSpan.FromSeconds(value: 300)), actual: error.Error);
    }

    [Fact]
    public async Task ARateLimitSaidOnlyInWordsWaitsAMinute()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var server = new GitHubStubServer();
        server.Reply(GitHubStubServer.Text(text: """{"message":"API rate limit exceeded for user"}""", status: 403));
        using (var client = server.Client())
        {
            var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: cancellationToken));
            Assert.Equal(expected: GitHubError.Throttled(retryAfter: TimeSpan.FromMinutes(value: 1)), actual: error.Error);
        }

        var tooMany = new GitHubStubServer();
        tooMany.Reply(GitHubStubServer.Text(text: string.Empty, status: 429));
        using var other = tooMany.Client();
        var throttled = await Assert.ThrowsAsync<GitHubException>(testCode: () => other.PullRequestsAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: GitHubError.Throttled(retryAfter: TimeSpan.FromMinutes(value: 1)), actual: throttled.Error);
    }

    [Fact]
    public async Task ARefusalThatIsntARateLimitDoesntHoldTheNextRequest()
    {
        var server = new GitHubStubServer();
        server.Reply(GitHubStubServer.Text(text: """{"message":"Resource not accessible by integration"}""", status: 403), StubReply.Json(body: Answer));
        using var client = server.Client();
        var cancellationToken = TestContext.Current.CancellationToken;

        var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: GitHubError.Forbidden, actual: error.Error);
        Assert.Equal(expected: GitHubFixture.Me, actual: (await client.PullRequestsAsync(cancellationToken: cancellationToken)).Data.Viewer.Login);
        Assert.Equal(expected: 2, actual: server.Requests.Count);
    }

    [Fact]
    public async Task TheLastRequestOfTheHourHoldsTheNext()
    {
        var clock = new TestClock(start: TestTimes.Reference);
        var server = new GitHubStubServer();
        var reset = TestTimes.T(seconds: 10 * GitHubFixture.Minute).ToUnixTimeSeconds().ToString(provider: System.Globalization.CultureInfo.InvariantCulture);
        server.Reply(StubReply.Json(body: Answer, headers: Headers(("x-ratelimit-remaining", "0"), ("x-ratelimit-reset", reset))));
        server.Always(reply: StubReply.Json(body: Answer));
        using var client = server.Client(time: clock);
        var cancellationToken = TestContext.Current.CancellationToken;

        Assert.Equal(expected: GitHubFixture.Me, actual: (await client.PullRequestsAsync(cancellationToken: cancellationToken)).Data.Viewer.Login);
        var held = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: GitHubError.Throttled(retryAfter: TimeSpan.FromSeconds(value: 600)), actual: held.Error);
        Assert.Single(collection: server.Requests);

        clock.Set(time: TestTimes.T(seconds: (10 * GitHubFixture.Minute) + 1));
        Assert.Equal(expected: GitHubFixture.Me, actual: (await client.PullRequestsAsync(cancellationToken: cancellationToken)).Data.Viewer.Login);
        Assert.Equal(expected: 2, actual: server.Requests.Count);
    }

    [Fact]
    public async Task ARateLimitedAnswerWaits()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var server = new GitHubStubServer();
        var reset = TestTimes.T(seconds: 2 * GitHubFixture.Minute).ToUnixTimeSeconds().ToString(provider: System.Globalization.CultureInfo.InvariantCulture);
        server.Reply(StubReply.Json(
            body: new JsonObject { ["data"] = null, ["errors"] = new JsonArray(GitHubFixture.Error(message: "API rate limit exceeded for user ID 1.", type: "RATE_LIMITED")) },
            headers: Headers(("x-ratelimit-reset", reset))));
        using (var client = server.Client())
        {
            var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: cancellationToken));
            Assert.Equal(expected: GitHubError.Throttled(retryAfter: TimeSpan.FromSeconds(value: 120)), actual: error.Error);
            var held = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: cancellationToken));
            Assert.Equal(expected: GitHubError.Throttled(retryAfter: TimeSpan.FromSeconds(value: 120)), actual: held.Error);
            Assert.Single(collection: server.Requests);
        }

        var noReset = new GitHubStubServer();
        noReset.Reply(StubReply.Json(body: new JsonObject { ["errors"] = new JsonArray(GitHubFixture.Error(message: "slow down", type: "RATE_LIMITED")) }));
        using var other = noReset.Client();
        var throttled = await Assert.ThrowsAsync<GitHubException>(testCode: () => other.PullRequestsAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: GitHubError.Throttled(retryAfter: TimeSpan.FromMinutes(value: 1)), actual: throttled.Error);
    }

    [Fact]
    public async Task KeepsWhatItCouldReadWithTheErrors()
    {
        var server = new GitHubStubServer();
        server.Reply(StubReply.Json(body: GitHubFixture.Answer(
            authored: [GitHubFixture.PullRequest(number: 2)],
            errors: [GitHubFixture.Error(message: "Resource protected by organization SAML enforcement.", type: "FORBIDDEN")])));
        using var client = server.Client();

        var result = await client.PullRequestsAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Single(collection: result.Data.Authored.Nodes);
        Assert.Equal(expected: [new GraphQLError(Message: "Resource protected by organization SAML enforcement.", Type: "FORBIDDEN")], actual: result.Errors);
    }

    [Fact]
    public async Task ErrorsAndNothingReadFail()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var server = new GitHubStubServer();
        server.Reply(StubReply.Json(body: new JsonObject
        {
            ["data"] = null,
            ["errors"] = new JsonArray(GitHubFixture.Error(message: "Something went wrong while executing your query.")),
        }));
        using (var client = server.Client())
        {
            var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: cancellationToken));
            Assert.Equal(expected: GitHubError.GraphQL(message: "Something went wrong while executing your query."), actual: error.Error);
        }

        var empty = new GitHubStubServer();
        empty.Reply(StubReply.Json(body: new JsonObject()));
        using var other = empty.Client();
        var nothing = await Assert.ThrowsAsync<GitHubException>(testCode: () => other.PullRequestsAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: GitHubError.GraphQL(message: "no data"), actual: nothing.Error);
    }

    [Fact]
    public async Task SkipsPullRequestsItCantRead()
    {
        var server = new GitHubStubServer();
        server.Reply(StubReply.Json(body: GitHubFixture.Answer(
            authored: [null, new JsonObject { ["id"] = "PR_partial", ["number"] = 9 }, GitHubFixture.PullRequest(number: 3), new JsonObject()], authoredCount: 4)));
        using var client = server.Client();

        var result = await client.PullRequestsAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: [3], actual: result.Data.Authored.Nodes.Select(selector: node => node.Number));
        Assert.Equal(expected: 4, actual: result.Data.Authored.IssueCount);
    }

    [Fact]
    public async Task AnUnexpectedAnswerIsADecodingError()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var server = new GitHubStubServer();
        server.Reply(GitHubStubServer.Text(text: "<html>Unicorn!</html>", status: 200));
        using (var client = server.Client())
        {
            var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: cancellationToken));
            Assert.Equal(expected: GitHubErrorKind.Decoding, actual: error.Error.Kind);
        }

        var missing = new GitHubStubServer();
        missing.Reply(StubReply.Json(body: new JsonObject { ["data"] = new JsonObject { ["reviewing"] = new JsonObject { ["issueCount"] = 0, ["nodes"] = new JsonArray() } } }));
        using var other = missing.Client();
        var decoding = await Assert.ThrowsAsync<GitHubException>(testCode: () => other.PullRequestsAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: GitHubErrorKind.Decoding, actual: decoding.Error.Kind);
        Assert.Contains(expectedSubstring: "viewer", actualString: decoding.Error.Message, comparisonType: StringComparison.Ordinal);

        // An error without a message isn't a GraphQL answer, as the Mac can't decode it either.
        var unnamed = new GitHubStubServer();
        unnamed.Reply(StubReply.Json(body: new JsonObject { ["errors"] = new JsonArray(new JsonObject { ["type"] = "FORBIDDEN" }) }));
        using var third = unnamed.Client();
        var unread = await Assert.ThrowsAsync<GitHubException>(testCode: () => third.PullRequestsAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: GitHubErrorKind.Decoding, actual: unread.Error.Kind);
    }

    [Theory]
    [InlineData(404)]
    [InlineData(500)]
    [InlineData(502)]
    public async Task OtherStatusesAreHTTPErrors(int status)
    {
        var server = new GitHubStubServer();
        server.Reply(GitHubStubServer.Text(text: string.Empty, status: status));
        using var client = server.Client();
        var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: GitHubError.Http(status: status), actual: error.Error);
    }

    [Fact]
    public async Task NetworkFailures()
    {
        (StubReply Reply, GitHubError Expected)[] cases =
        [
            (StubReply.Offline(), GitHubError.Offline),
            (StubReply.TimedOut(), GitHubError.Network(message: "GitHub didn't answer in time.")),
            (Failure(error: HttpRequestError.NameResolutionError), GitHubError.Network(message: "Can't reach GitHub.")),
            (Failure(error: HttpRequestError.ProxyTunnelError), GitHubError.Network(message: "The proxy didn't let BriefBar reach GitHub.")),
            (Failure(error: HttpRequestError.SecureConnectionError), GitHubError.Network(message: "Couldn't connect to GitHub securely.")),
            (Failure(error: HttpRequestError.ConnectionError), GitHubError.Network(message: "Couldn't connect to GitHub.")),
        ];
        foreach (var (reply, expected) in cases)
        {
            var server = new GitHubStubServer();
            server.Reply(reply);
            using var client = server.Client();
            var error = await Assert.ThrowsAsync<GitHubException>(testCode: () => client.PullRequestsAsync(cancellationToken: TestContext.Current.CancellationToken));
            Assert.Equal(expected: expected, actual: error.Error);
        }

        static StubReply Failure(HttpRequestError error) => StubReply.Offline() with
        {
            Failure = new HttpRequestException(httpRequestError: error, message: "Made-up failure.", inner: new SocketException(errorCode: (int)SocketError.ConnectionRefused)),
        };
    }

    [Fact]
    public void WaitsAreBounded()
    {
        static HttpResponseMessage Response(int status, params (string Name, string Value)[] headers)
        {
            var response = new HttpResponseMessage(statusCode: (HttpStatusCode)status);
            foreach (var (name, value) in headers)
            {
                response.Headers.TryAddWithoutValidation(name: name, value: value);
            }
            return response;
        }
        var now = TestTimes.Reference;
        var epoch = now.ToUnixTimeSeconds();
        string Epoch(long offset) => (epoch + offset).ToString(provider: System.Globalization.CultureInfo.InvariantCulture);

        using var long429 = Response(status: 403, ("Retry-After", "99999"));
        Assert.Equal(expected: TimeSpan.FromHours(value: 1), actual: GitHubClient.RateLimitWait(response: long429, body: [], now: now));
        using var zero = Response(status: 403, ("Retry-After", "0"));
        Assert.Null(@object: GitHubClient.RateLimitWait(response: zero, body: [], now: now));
        using var words = Response(status: 403, ("Retry-After", "soon"));
        Assert.Null(@object: GitHubClient.RateLimitWait(response: words, body: [], now: now));
        using var someLeft = Response(status: 403, ("x-ratelimit-remaining", "3"), ("x-ratelimit-reset", Epoch(offset: 60)));
        Assert.Null(@object: GitHubClient.RateLimitWait(response: someLeft, body: [], now: now));

        using var past = Response(status: 200, ("x-ratelimit-reset", Epoch(offset: -60)));
        Assert.Equal(expected: TimeSpan.FromSeconds(value: 1), actual: GitHubClient.ResetWait(response: past, now: now));
        using var tomorrow = Response(status: 200, ("x-ratelimit-reset", Epoch(offset: 86_400)));
        Assert.Equal(expected: TimeSpan.FromHours(value: 1), actual: GitHubClient.ResetWait(response: tomorrow, now: now));
        using var soon = Response(status: 200, ("x-ratelimit-reset", Epoch(offset: 90)));
        Assert.Equal(expected: TimeSpan.FromSeconds(value: 90), actual: GitHubClient.ResetWait(response: soon, now: now));
        using var later = Response(status: 200, ("x-ratelimit-reset", "later"));
        Assert.Null(@object: GitHubClient.ResetWait(response: later, now: now));
        using var none = Response(status: 200);
        Assert.Null(@object: GitHubClient.ResetWait(response: none, now: now));
    }

    /// Its requests keep no cookies, send no Windows credentials, and say they're BriefBar's. `HttpClient` keeps no cache,
    /// which the Mac has to turn off.
    [Fact]
    public async Task RequestsCarryNoCookiesOrCache()
    {
        using var handler = GitHubClient.MakeHandler();
        Assert.False(condition: handler.UseCookies);
        Assert.Null(@object: handler.Credentials);

        var server = new GitHubStubServer();
        server.Reply(StubReply.Json(body: Answer));
        using var client = server.Client();
        await client.PullRequestsAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: "BriefBar", actual: Assert.Single(collection: server.Requests).UserAgent);
    }
}
