using System.Net;
using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

public sealed class ClientTests
{
    static JsonObject Me => new() { ["authenticatedUser"] = new JsonObject { ["id"] = "ME" } };

    [Fact]
    public void BuildsEndpointURLs()
    {
        Assert.Equal(expected: "https://dev.azure.com/contoso/_apis/connectionData", actual: ADOEndpoint.ConnectionData(organization: "contoso").AbsoluteUri);
        Assert.Equal(
            expected: "https://dev.azure.com/contoso/_apis/git/pullrequests?searchCriteria.creatorId=me&searchCriteria.status=active&$top=200&api-version=7.1",
            actual: ADOEndpoint.PullRequests(organization: "contoso", status: "active", creatorId: "me").AbsoluteUri);
        Assert.Equal(
            expected: "https://dev.azure.com/contoso/_apis/git/pullrequests?searchCriteria.creatorId=me&searchCriteria.status=completed"
                + "&searchCriteria.minTime=2026-10-18T10%3A00%3A00Z&searchCriteria.queryTimeRangeType=closed&$top=50&api-version=7.1",
            actual: ADOEndpoint.PullRequests(organization: "contoso", status: "completed", creatorId: "me", closedSince: TestTimes.T(seconds: 0), top: 50).AbsoluteUri);
        // The artifact ID is encoded completely, slashes and colons included.
        Assert.Equal(
            expected: "https://dev.azure.com/contoso/p1/_apis/policy/evaluations?artifactId=vstfs%3A%2F%2F%2FCodeReview%2FCodeReviewId%2Fp1%2F7&api-version=7.1-preview.1",
            actual: ADOEndpoint.PolicyEvaluations(organization: "contoso", projectId: "p1", pullRequestId: 7).AbsoluteUri);
        Assert.Equal(
            expected: "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/threads?api-version=7.1",
            actual: ADOEndpoint.Threads(organization: "contoso", projectId: "p1", repositoryId: "r1", pullRequestId: 7).AbsoluteUri);
        Assert.Equal(
            expected: "https://dev.azure.com/contoso/My%20Project/_git/web%20app/pullrequest/7",
            actual: ADOEndpoint.PullRequestPage(organization: "contoso", project: "My Project", repository: "web app", id: 7).AbsoluteUri);
        Assert.Equal(expected: "https://dev.azure.com/contoso/_pulls", actual: ADOEndpoint.MyPullRequestsPage(organization: "contoso").AbsoluteUri);
    }

    [Fact]
    public async Task SendsOnlyGETRequestsWithABearerToken()
    {
        var server = new StubServer();
        server.On(path: "/_apis/connectionData", json: Me);
        using var client = server.Client();
        var me = await client.GetAsync(url: ADOEndpoint.ConnectionData(organization: "contoso"), read: ADOConnectionData.Read, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: "ME", actual: me.AuthenticatedUser.Id);
        var request = Assert.Single(collection: server.Requests);
        Assert.Equal(expected: HttpMethod.Get, actual: request.Method);
        Assert.Equal(expected: "Bearer made-up-token", actual: request.Authorization);
        Assert.Equal(expected: "Suppress", actual: request.FedAuthRedirect);
        Assert.False(condition: request.HasBody);
    }

    [Fact]
    public async Task NoContentIsNothingThereNotASignInProblem()
    {
        var server = new StubServer();
        server.On(path: "/timeline", reply: _ => new StubReply(Status: HttpStatusCode.NoContent, Headers: new Dictionary<string, string>(), Body: []));
        var tokens = new FakeTokens(value: "made-up-token");
        using var client = server.Client(tokens: tokens);
        var error = await Assert.ThrowsAsync<ADOException>(testCode: () => client.GetAsync(
            url: ADOEndpoint.Timeline(organization: "contoso", projectId: "p1", buildId: 7), read: ADOTimeline.Read, cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: ADOError.NotFound, actual: error.Error);
        Assert.Equal(expected: 0, actual: tokens.Invalidations);
        Assert.Single(collection: server.Requests);
    }

    [Fact]
    public async Task RetriesOnceWithAFreshTokenWhenTheTokenIsRejected()
    {
        var server = new StubServer();
        var attempts = 0;
        server.On(path: "/_apis/connectionData", reply: _ => Interlocked.Increment(location: ref attempts) == 1 ? StubReply.Code(status: 401) : StubReply.Json(body: Me));
        var tokens = new FakeTokens(value: "made-up-token");
        using (var client = server.Client(tokens: tokens))
        {
            _ = await client.GetAsync(url: ADOEndpoint.ConnectionData(organization: "contoso"), read: ADOConnectionData.Read, cancellationToken: TestContext.Current.CancellationToken);
        }
        Assert.Equal(expected: 1, actual: tokens.Invalidations);
        Assert.Equal(expected: 2, actual: tokens.Fetches);

        // A sign-in page instead of JSON means the same; twice in a row is an error.
        server.On(path: "/_apis/connectionData", reply: _ => new StubReply(
            Status: HttpStatusCode.NonAuthoritativeInformation, Headers: new Dictionary<string, string> { ["Content-Type"] = "text/html" }, Body: "<html>"u8.ToArray()));
        using var signedOut = server.Client();
        var error = await Assert.ThrowsAsync<ADOException>(testCode: () => signedOut.GetAsync(
            url: ADOEndpoint.ConnectionData(organization: "contoso"), read: ADOConnectionData.Read, cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: ADOError.Unauthorized, actual: error.Error);
    }

    [Fact]
    public async Task MapsFailures()
    {
        var server = new StubServer();
        using var client = server.Client();
        var url = ADOEndpoint.ConnectionData(organization: "contoso");
        (StubReply Reply, ADOError Expected)[] cases =
        [
            (StubReply.Code(status: 403), ADOError.Forbidden),
            (StubReply.Code(status: 404), ADOError.NotFound),
            (StubReply.Code(status: 500), ADOError.Http(status: 500)),
            (StubReply.Offline(), ADOError.Offline),
            (StubReply.TimedOut(), ADOError.Network(message: "Azure DevOps didn't answer in time.")),
        ];
        foreach (var (reply, expected) in cases)
        {
            server.On(path: "/_apis/connectionData", reply: _ => reply);
            var error = await Assert.ThrowsAsync<ADOException>(testCode: () => client.GetAsync(url: url, read: ADOConnectionData.Read, cancellationToken: TestContext.Current.CancellationToken));
            Assert.Equal(expected: expected, actual: error.Error);
        }
    }

    [Fact]
    public async Task HonorsRetryAfter()
    {
        var server = new StubServer();
        server.On(path: "/_apis/connectionData", reply: _ => StubReply.Code(status: 429, headers: new Dictionary<string, string> { ["Retry-After"] = "30" }));
        var clock = new TestClock(start: TestTimes.T(seconds: 0));
        using var client = server.Client(time: clock);
        var url = ADOEndpoint.ConnectionData(organization: "contoso");
        var cancellationToken = TestContext.Current.CancellationToken;
        var error = await Assert.ThrowsAsync<ADOException>(testCode: () => client.GetAsync(url: url, read: ADOConnectionData.Read, cancellationToken: cancellationToken));
        Assert.Equal(expected: ADOError.Throttled(retryAfter: TimeSpan.FromSeconds(value: 30)), actual: error.Error);

        // Until then, nothing is sent.
        server.On(path: "/_apis/connectionData", json: Me);
        var sent = server.Requests.Count;
        clock.Set(time: TestTimes.T(seconds: 2));
        var held = await Assert.ThrowsAsync<ADOException>(testCode: () => client.GetAsync(url: url, read: ADOConnectionData.Read, cancellationToken: cancellationToken));
        Assert.Equal(expected: ADOError.Throttled(retryAfter: TimeSpan.FromSeconds(value: 28)), actual: held.Error);
        Assert.Equal(expected: sent, actual: server.Requests.Count);

        // Then it is.
        clock.Set(time: TestTimes.T(seconds: 30));
        var me = await client.GetAsync(url: url, read: ADOConnectionData.Read, cancellationToken: cancellationToken);
        Assert.Equal(expected: "ME", actual: me.AuthenticatedUser.Id);
        Assert.Equal(expected: sent + 1, actual: server.Requests.Count);
    }

    [Fact]
    public async Task ReportsAuthFailures()
    {
        var server = new StubServer();
        using var client = server.Client(tokens: new FakeTokens(value: "made-up-token", error: AuthError.SignedOut(message: "Run az login")));
        var error = await Assert.ThrowsAsync<ADOException>(testCode: () => client.GetAsync(
            url: ADOEndpoint.ConnectionData(organization: "contoso"), read: ADOConnectionData.Read, cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: ADOError.FromAuth(error: AuthError.SignedOut(message: "Run az login")), actual: error.Error);
        // Nothing goes out without a token.
        Assert.Empty(collection: server.Requests);
    }
}
