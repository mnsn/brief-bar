namespace BriefBar.Core;

/// Where a redirect from Azure DevOps or GitHub would send a request. Neither client follows one (`ADOClient`,
/// `GitHubClient`), as .NET's own handlers do by default, to any host: each source's description names the hosts it
/// connects to, and a redirect would send the request wherever it said, with its body for a 307 or a 308. Neither needs
/// one, as Azure DevOps and GitHub answer each request BriefBar sends where it sends it, so one to another host is refused,
/// in words that don't name it, as the Mac's: a host can carry an organization's name.
internal static class Redirects
{
    /// The host `location`, a redirect's, sends a request for `requested` to, when it's another host, in ASCII, as a name
    /// with letters from other scripts can pass for one it isn't; null when it stays on `requested`'s host, whatever its
    /// path, or doesn't say where: no location, one that can't be resolved, as `//` can't, or one without a host, as
    /// `about:blank`.
    public static string? OtherHost(Uri? location, Uri requested)
    {
        ArgumentNullException.ThrowIfNull(argument: requested);
        if (location is null || !Uri.TryCreate(baseUri: requested, relativeUri: location, result: out var target) || target.IdnHost.Length == 0)
        {
            return null;
        }
        return string.Equals(a: target.IdnHost, b: requested.IdnHost, comparisonType: StringComparison.OrdinalIgnoreCase) ? null : target.IdnHost;
    }
}
