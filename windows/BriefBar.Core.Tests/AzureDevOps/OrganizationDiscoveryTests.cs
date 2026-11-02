using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

public sealed class OrganizationDiscoveryTests
{
    static JsonObject Me => new() { ["authenticatedUser"] = new JsonObject { ["id"] = "ME" } };

    static JsonObject Profile => new() { ["id"] = "profile-id", ["publicAlias"] = "alias" };

    static Dictionary<string, string> Alias => new() { ["memberId"] = "alias" };

    [Fact]
    public void ValidatesOrganizationNames()
    {
        Assert.True(condition: OrganizationDiscovery.IsValidName(name: "contoso"));
        Assert.True(condition: OrganizationDiscovery.IsValidName(name: "contoso-2"));
        Assert.False(condition: OrganizationDiscovery.IsValidName(name: ""));
        Assert.False(condition: OrganizationDiscovery.IsValidName(name: "-contoso"));
        Assert.False(condition: OrganizationDiscovery.IsValidName(name: "con toso"));
        Assert.False(condition: OrganizationDiscovery.IsValidName(name: "contoso/web"));
    }

    [Fact]
    public void MergesOrganizationNamesIgnoringCase()
    {
        Assert.Equal(expected: ["Contoso", "Fabrikam", "zeta"], actual: OrganizationDiscovery.Merged(names: ["contoso", "zeta"], preferred: ["Contoso", "Fabrikam"]));
        // "a" is "A" again, and the rest are in BriefBar's order for names: the Mac's localizedCaseInsensitiveCompare, NameOrder here.
        string[] kept = ["b", "A"];
        Assert.Equal(expected: kept.Order(comparer: OrganizationDiscovery.NameOrder), actual: OrganizationDiscovery.Merged(names: ["b", "A", "a"], preferred: []));
    }

    [Theory]
    [InlineData("contoso", "contoso")]
    [InlineData("  contoso \n", "contoso")]
    [InlineData("https://dev.azure.com/contoso", "contoso")]
    [InlineData("dev.azure.com/contoso/Shop/_git/web/pullrequest/7", "contoso")]
    [InlineData("https://contoso.visualstudio.com/Shop/_git/web", "contoso")]
    [InlineData("contoso.visualstudio.com", "contoso")]
    [InlineData("https://dev.azure.com", null)]
    [InlineData("", null)]
    [InlineData("not an org", null)]
    [InlineData("https://github.com/contoso/web", null)]
    public void ReadsOrganizationNamesFromLinks(string input, string? expected) =>
        Assert.Equal(expected: expected, actual: OrganizationDiscovery.NameFrom(input: input));

    [Fact]
    public async Task DiscoversOrganizationsWithPullRequests()
    {
        var server = new StubServer();
        server.On(path: "/_apis/profile/profiles/me", json: Profile);
        server.On(
            path: "/_apis/accounts",
            json: Fixture.List(items: [Account(name: "fabrikam"), Account(name: "Contoso"), Account(name: "northwind"), Account(name: "locked")]),
            query: Alias);
        foreach (var organization in new[] { "fabrikam", "Contoso", "northwind" })
        {
            server.On(path: "/" + organization + "/_apis/connectionData", json: Me);
        }
        server.On(path: "/locked/_apis/connectionData", reply: _ => StubReply.Code(status: 401));
        server.On(path: "/fabrikam/_apis/git/pullrequests", json: Fixture.List(items: []));
        server.On(
            path: "/northwind/_apis/git/pullrequests",
            json: Fixture.List(items: [Fixture.PullRequest(id: 3)]),
            query: new Dictionary<string, string> { ["searchCriteria.reviewerId"] = "ME" });
        server.On(path: "/northwind/_apis/git/pullrequests", json: Fixture.List(items: []), query: new Dictionary<string, string> { ["searchCriteria.creatorId"] = "ME" });
        server.On(path: "/Contoso/_apis/git/pullrequests", json: Fixture.List(items: [Fixture.PullRequest(id: 1)]));

        using var client = server.Client();
        var found = await OrganizationDiscovery.DiscoverAsync(client: client, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: ["Contoso", "fabrikam", "locked", "northwind"], actual: found.All);
        // locked can't be read: you have nothing there.
        Assert.Equal(expected: ["Contoso", "northwind"], actual: found.WithPullRequests);
        Assert.All(collection: server.Requests, action: request => Assert.Equal(expected: HttpMethod.Get, actual: request.Method));
    }

    [Fact]
    public async Task AnOrganizationThatCouldntBeCheckedIsntOneWithoutPullRequests()
    {
        var server = new StubServer();
        server.On(path: "/_apis/profile/profiles/me", json: Profile);
        server.On(path: "/_apis/accounts", json: Fixture.List(items: [Account(name: "contoso"), Account(name: "fabrikam")]), query: Alias);
        server.On(path: "/contoso/_apis/connectionData", reply: _ => StubReply.Offline());
        server.On(path: "/fabrikam/_apis/connectionData", reply: _ => StubReply.Code(status: 403));
        using var client = server.Client();
        var cancellationToken = TestContext.Current.CancellationToken;

        var probe = await OrganizationDiscovery.ProbeAsync(organizations: ["contoso", "fabrikam"], client: client, cancellationToken: cancellationToken);
        Assert.Empty(collection: probe.WithPullRequests);
        Assert.Equal(expected: new Dictionary<string, ADOError> { ["contoso"] = ADOError.Offline }, actual: probe.Failures);
        // Finding none because it couldn't tell is an error, so discovery tries again rather than settling on none.
        var error = await Assert.ThrowsAsync<ADOException>(testCode: () => OrganizationDiscovery.DiscoverAsync(client: client, cancellationToken: cancellationToken));
        Assert.Equal(expected: ADOError.Offline, actual: error.Error);

        // Once contoso answers, its pull request is found.
        server.On(path: "/contoso/_apis/connectionData", json: Me);
        server.On(path: "/contoso/_apis/git/pullrequests", json: Fixture.List(items: [Fixture.PullRequest(id: 1)]));
        Assert.Equal(expected: ["contoso"], actual: (await OrganizationDiscovery.DiscoverAsync(client: client, cancellationToken: cancellationToken)).WithPullRequests);
    }

    /// Asked to slow down partway, it can't tell for the organizations it hadn't checked: it finds nothing, rather than
    /// only the ones it checked before, so that nothing partial is saved, and it's tried again once BriefBar may send.
    [Fact]
    public async Task FindsNothingWhenAskedToSlowDownPartway()
    {
        var clock = new TestClock(start: TestTimes.T(seconds: 0));
        var server = new StubServer();
        server.On(path: "/_apis/profile/profiles/me", json: Profile);
        server.On(path: "/_apis/accounts", json: Fixture.List(items: [Account(name: "contoso"), Account(name: "fabrikam"), Account(name: "northwind")]), query: Alias);
        foreach (var organization in new[] { "contoso", "northwind" })
        {
            server.On(path: "/" + organization + "/_apis/connectionData", json: Me);
            server.On(path: "/" + organization + "/_apis/git/pullrequests", json: Fixture.List(items: [Fixture.PullRequest(id: 1)]));
        }
        server.On(path: "/fabrikam/_apis/connectionData", reply: _ => StubReply.Code(status: 503));
        using var client = server.Client(time: clock);
        var cancellationToken = TestContext.Current.CancellationToken;
        var error = await Assert.ThrowsAsync<ADOException>(testCode: () => OrganizationDiscovery.DiscoverAsync(client: client, cancellationToken: cancellationToken));
        Assert.Equal(expected: ADOError.Throttled(retryAfter: TimeSpan.FromSeconds(value: 60)), actual: error.Error);

        // Once it may send again, it finds them all.
        server.On(path: "/fabrikam/_apis/connectionData", json: Me);
        server.On(path: "/fabrikam/_apis/git/pullrequests", json: Fixture.List(items: []));
        clock.Set(time: TestTimes.T(seconds: 61));
        var found = await OrganizationDiscovery.DiscoverAsync(client: client, cancellationToken: cancellationToken);
        Assert.Equal(expected: ["contoso", "fabrikam", "northwind"], actual: found.All);
        Assert.Equal(expected: ["contoso", "northwind"], actual: found.WithPullRequests);
    }

    static JsonObject Account(string name) => new() { ["accountName"] = name };
}
