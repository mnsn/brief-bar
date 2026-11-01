namespace BriefBar.Core.Tests;

/// A request a stub server got: its method, URL, the headers BriefBar sets, whether it had a body, and what it was.
internal sealed record StubRequest(HttpMethod Method, Uri Url, string? Authorization, string? FedAuthRedirect, bool HasBody)
{
    public string? ContentType { get; init; }

    public string? Accept { get; init; }

    public string? UserAgent { get; init; }

    public byte[] Body { get; init; } = [];

    /// What `request` with `body` says, as a stub server notes it.
    public static StubRequest Of(HttpRequestMessage request, byte[]? body)
    {
        ArgumentNullException.ThrowIfNull(argument: request);
        return new StubRequest(
            Method: request.Method,
            Url: request.RequestUri!,
            Authorization: request.Headers.Authorization?.ToString(),
            FedAuthRedirect: request.Headers.TryGetValues(name: "X-TFS-FedAuthRedirect", values: out var values) ? values.FirstOrDefault() : null,
            HasBody: request.Content is not null)
        {
            ContentType = request.Content?.Headers.ContentType?.ToString(),
            Accept = request.Headers.Accept.ToString(),
            UserAgent = request.Headers.UserAgent.ToString(),
            Body = body ?? [],
        };
    }
    /// Its path, decoded.
    public string Path => Uri.UnescapeDataString(stringToUnescape: Url.AbsolutePath);

    /// Its query's items, decoded.
    public IReadOnlyDictionary<string, string> Query
    {
        get
        {
            var items = new Dictionary<string, string>(comparer: StringComparer.Ordinal);
            foreach (var item in Url.Query.TrimStart(trimChar: '?').Split(separator: '&', options: StringSplitOptions.RemoveEmptyEntries))
            {
                var parts = item.Split(separator: '=', count: 2);
                items[Uri.UnescapeDataString(stringToUnescape: parts[0])] = parts.Length > 1 ? Uri.UnescapeDataString(stringToUnescape: parts[1]) : string.Empty;
            }
            return items;
        }
    }
}
