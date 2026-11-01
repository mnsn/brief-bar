using System.Text.Json;

namespace BriefBar.Core.GitHub;

/// What `PullRequestQuery` reads: who you are, its two searches, and GitHub's hourly limit. The Mac's
/// `PullRequestQueryData`.
public sealed record PullRequestQueryData(GitHubViewer Viewer, PullRequestSearch Reviewing, PullRequestSearch Authored, GitHubRateLimit? RateLimit = null)
{
    /// What `element`, the answer's `data`, holds; throws `GitHubException` when it lacks what BriefBar reads, as the Mac
    /// can't decode it.
    internal static PullRequestQueryData Read(JsonElement element)
    {
        var viewer = LenientJson.Node(element: element, name: "viewer") ?? throw Missing(path: "viewer");
        var login = LenientJson.Text(element: viewer, name: "login") ?? throw Missing(path: "viewer.login");
        var reviewing = LenientJson.Node(element: element, name: "reviewing") ?? throw Missing(path: "reviewing");
        var authored = LenientJson.Node(element: element, name: "authored") ?? throw Missing(path: "authored");
        return new PullRequestQueryData(
            Viewer: new GitHubViewer(Login: login),
            Reviewing: PullRequestSearch.Read(element: reviewing),
            Authored: PullRequestSearch.Read(element: authored),
            RateLimit: LenientJson.Node(element: element, name: "rateLimit") is { } rateLimit ? GitHubRateLimit.Read(element: rateLimit) : null);
    }

    static GitHubException Missing(string path) => new(error: GitHubError.Decoding(message: "missing " + path));
}
