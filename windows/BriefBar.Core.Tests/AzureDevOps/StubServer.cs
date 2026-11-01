using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// A made-up Azure DevOps: answers requests from routes, the latest added first, and 404 for anything else, and keeps every
/// request it got. As the Swift tests' `StubServer`, which `ADOClient`s reach through a handler of their own.
internal sealed class StubServer
{
    readonly Lock gate = new();
    readonly List<Func<StubRequest, StubReply?>> routes = [];
    readonly List<StubRequest> requests = [];

    public IReadOnlyList<StubRequest> Requests
    {
        get
        {
            lock (gate)
            {
                return [.. requests];
            }
        }
    }

    /// A client that reaches this server, with `tokens`, or tokens of its own.
    public ADOClient Client(IAccessTokenProvider? tokens = null, TimeProvider? time = null) =>
        new(tokens: tokens ?? new FakeTokens(value: "made-up-token"), handler: new StubHandler(handle: Handle), time: time);

    /// Answers requests whose path contains `path`, and whose query has every item of `query`, values in any case.
    public void On(string path, Func<StubRequest, StubReply> reply, IReadOnlyDictionary<string, string>? query = null)
    {
        lock (gate)
        {
            routes.Insert(index: 0, item: request =>
            {
                if (!request.Path.Contains(value: path, comparisonType: StringComparison.Ordinal))
                {
                    return null;
                }
                var items = request.Query;
                foreach (var (name, value) in query ?? new Dictionary<string, string>())
                {
                    if (!items.TryGetValue(key: name, value: out var found) || !string.Equals(a: found, b: value, comparisonType: StringComparison.OrdinalIgnoreCase))
                    {
                        return null;
                    }
                }
                return reply(arg: request);
            });
        }
    }

    public void On(string path, JsonNode json, IReadOnlyDictionary<string, string>? query = null)
    {
        var reply = StubReply.Json(body: json);
        On(path: path, reply: _ => reply, query: query);
    }

    /// Serves an organization: who you are, your pull request lists, and each pull request's details, none.
    public void ServeOrganization(
        string organization = Fixture.Org, string? me = null, IEnumerable<JsonNode>? mine = null, IEnumerable<JsonNode>? reviewing = null, IEnumerable<JsonNode>? completed = null)
    {
        var id = me ?? Fixture.Me;
        On(path: "/" + organization + "/_apis/connectionData", json: new JsonObject { ["authenticatedUser"] = new JsonObject { ["id"] = id.ToUpperInvariant() } });
        On(path: "/" + organization + "/_apis/git/pullrequests", json: Fixture.List(items: mine ?? []),
            query: new Dictionary<string, string> { ["searchCriteria.creatorId"] = id, ["searchCriteria.status"] = "active" });
        On(path: "/" + organization + "/_apis/git/pullrequests", json: Fixture.List(items: reviewing ?? []),
            query: new Dictionary<string, string> { ["searchCriteria.reviewerId"] = id, ["searchCriteria.status"] = "active" });
        On(path: "/" + organization + "/_apis/git/pullrequests", json: Fixture.List(items: completed ?? []),
            query: new Dictionary<string, string> { ["searchCriteria.creatorId"] = id, ["searchCriteria.status"] = "completed" });
        On(path: "/_apis/policy/evaluations", json: Fixture.List(items: []));
        On(path: "/threads", json: Fixture.List(items: []));
    }

    /// Notes `request`, with its `body`, and answers it.
    internal StubReply Handle(HttpRequestMessage request, byte[]? body)
    {
        var noted = StubRequest.Of(request: request, body: body);
        List<Func<StubRequest, StubReply?>> current;
        lock (gate)
        {
            requests.Add(item: noted);
            current = [.. routes];
        }
        foreach (var route in current)
        {
            if (route(arg: noted) is { } reply)
            {
                return reply;
            }
        }
        return StubReply.Code(status: 404);
    }
}
