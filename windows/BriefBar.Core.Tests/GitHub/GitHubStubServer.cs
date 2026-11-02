using System.Text.Json.Nodes;
using BriefBar.Core.GitHub;

namespace BriefBar.Core.Tests.GitHub;

/// A made-up GitHub: answers each request with the next reply it was given, then with its fallback, a 404 unless told
/// otherwise, and keeps every request it got. As the Swift tests' `StubServer` for GitHub.
internal sealed class GitHubStubServer
{
    readonly Lock gate = new();
    readonly Queue<StubReply> replies = new();
    readonly List<StubRequest> requests = [];
    StubReply fallback = StubReply.Code(status: 404);

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

    /// The tokens its requests carried, in order.
    public IReadOnlyList<string?> Tokens => [.. Requests.Select(selector: request => request.Authorization)];

    /// A client that reaches this server, with `tokens`, or tokens of its own.
    public GitHubClient Client(IGitHubTokenProvider? tokens = null, TimeProvider? time = null) =>
        new(tokens: tokens ?? new FakeGitHubTokens(), handler: new StubHandler(handle: Handle), time: time ?? new TestClock(start: TestTimes.Reference));

    /// The next requests get these replies, in order; after them, `Always`'s.
    public void Reply(params StubReply[] next)
    {
        lock (gate)
        {
            foreach (var reply in next)
            {
                replies.Enqueue(item: reply);
            }
        }
    }

    public void Always(StubReply reply)
    {
        lock (gate)
        {
            fallback = reply;
        }
    }

    /// A reply with `text` as its body, which needn't be JSON.
    public static StubReply Text(string text, int status, IReadOnlyDictionary<string, string>? headers = null) =>
        StubReply.Code(status: status, headers: headers) with { Body = System.Text.Encoding.UTF8.GetBytes(s: text) };

    /// What request `index` sent, as JSON.
    public JsonObject Sent(int index) => JsonNode.Parse(utf8Json: Requests[index].Body)!.AsObject();

    StubReply Handle(HttpRequestMessage request, byte[]? body)
    {
        lock (gate)
        {
            requests.Add(item: StubRequest.Of(request: request, body: body));
            return replies.Count > 0 ? replies.Dequeue() : fallback;
        }
    }
}
