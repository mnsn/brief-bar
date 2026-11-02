using System.Net.Http.Headers;

namespace BriefBar.Core.Tests;

/// The handler a stub server's client sends through, a new one each time, since a client disposes its own: it reads each
/// request's body, then answers with what `handle` makes of the request and its body. As the Swift tests' `URLProtocol`
/// stubs.
internal sealed class StubHandler(Func<HttpRequestMessage, byte[]?, StubReply> handle) : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var body = request.Content is { } content ? await content.ReadAsByteArrayAsync(cancellationToken: cancellationToken) : null;
        var reply = handle(arg1: request, arg2: body);
        if (reply.Failure is { } failure)
        {
            throw failure;
        }
        var response = new HttpResponseMessage(statusCode: reply.Status) { Content = new ByteArrayContent(content: reply.Body), RequestMessage = request };
        foreach (var (name, value) in reply.Headers)
        {
            if (string.Equals(a: name, b: "Content-Type", comparisonType: StringComparison.OrdinalIgnoreCase))
            {
                response.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(input: value);
            }
            else
            {
                response.Headers.TryAddWithoutValidation(name: name, value: value);
            }
        }
        return response;
    }
}
