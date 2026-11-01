namespace BriefBar.Core.Tests.AzureDevOps;

/// A request a `StubServer` got: its method, URL, the headers BriefBar sets, and whether it had a body.
internal sealed record StubRequest(HttpMethod Method, Uri Url, string? Authorization, string? FedAuthRedirect, bool HasBody)
{
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
