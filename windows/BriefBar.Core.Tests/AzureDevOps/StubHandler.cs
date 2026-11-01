using System.Net.Http.Headers;

namespace BriefBar.Core.Tests.AzureDevOps;

/// The handler a client sends through: a new one each time, since a client disposes its own.
internal sealed class StubHandler(StubServer server) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var reply = server.Handle(request: request);
        if (reply.Failure is { } failure)
        {
            return Task.FromException<HttpResponseMessage>(exception: failure);
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
        return Task.FromResult(result: response);
    }
}
