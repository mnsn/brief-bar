using System.Globalization;

namespace BriefBar.Core.GitHub;

/// A token for GitHub, from the GitHub CLI's sign-in, kept in memory only, and when BriefBar got it: `gh` doesn't say when
/// a token expires (most never do), so BriefBar asks again after a while, and whenever GitHub rejects it. The Mac's
/// `GitHubToken`.
public sealed record GitHubToken(string Value, DateTimeOffset FetchedAt)
{
    /// Never the token itself.
    public override string ToString() => "GitHubToken from " + FetchedAt.ToString(format: "O", formatProvider: CultureInfo.InvariantCulture);
}
