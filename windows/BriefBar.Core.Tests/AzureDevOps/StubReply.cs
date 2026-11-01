using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// What a `StubServer` answers a request with: a status, headers and a body, or a failure to reach it.
internal sealed record StubReply(HttpStatusCode Status, IReadOnlyDictionary<string, string> Headers, byte[] Body, Exception? Failure = null)
{
    static readonly Dictionary<string, string> json = new(comparer: StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = "application/json; charset=utf-8" };

    /// `body`, as JSON, with `headers` besides its type.
    public static StubReply Json(JsonNode body, int status = 200, IReadOnlyDictionary<string, string>? headers = null) =>
        new(Status: (HttpStatusCode)status, Headers: With(headers: headers), Body: Encoding.UTF8.GetBytes(s: body.ToJsonString()));

    /// Just a status, with an empty JSON object.
    public static StubReply Code(int status, IReadOnlyDictionary<string, string>? headers = null) =>
        new(Status: (HttpStatusCode)status, Headers: With(headers: headers), Body: "{}"u8.ToArray());

    /// No connection at all, as when offline.
    public static StubReply Offline() =>
        new(Status: 0, Headers: json, Body: [], Failure: new HttpRequestException(
            httpRequestError: HttpRequestError.ConnectionError, message: "Made-up failure.", inner: new SocketException(errorCode: (int)SocketError.NetworkUnreachable)));

    /// No answer in time.
    public static StubReply TimedOut() =>
        new(Status: 0, Headers: json, Body: [], Failure: new TaskCanceledException(message: "Made-up timeout.", innerException: new TimeoutException()));

    static Dictionary<string, string> With(IReadOnlyDictionary<string, string>? headers)
    {
        var all = new Dictionary<string, string>(dictionary: json, comparer: StringComparer.OrdinalIgnoreCase);
        foreach (var (name, value) in headers ?? new Dictionary<string, string>())
        {
            all[name] = value;
        }
        return all;
    }
}
