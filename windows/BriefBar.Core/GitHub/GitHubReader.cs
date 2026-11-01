namespace BriefBar.Core.GitHub;

/// Reads your pull requests from GitHub, in one request, and what that answer means for the list. The Mac's
/// `GitHubReader`.
public static class GitHubReader
{
    /// The most of a message from GitHub that a notice quotes.
    const int NoticeLength = 200;

    /// Reads GitHub with `client`; throws `GitHubException` when it can't.
    public static async Task<GitHubLoad> LoadAsync(GitHubClient client, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(argument: client);
        var result = await client.PullRequestsAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        return Load(data: result.Data, errors: result.Errors);
    }

    /// What a query's answer means for the list.
    public static GitHubLoad Load(PullRequestQueryData data, IReadOnlyList<GraphQLError>? errors = null)
    {
        ArgumentNullException.ThrowIfNull(argument: data);
        var items = GitHubClassifier.Snapshots(
            reviewing: data.Reviewing.Nodes.Select(selector: GitHubPullRequest.From),
            authored: data.Authored.Nodes.Select(selector: GitHubPullRequest.From));
        var moreThanShown = data.Reviewing.IssueCount > data.Reviewing.Nodes.Count || data.Authored.IssueCount > data.Authored.Nodes.Count;
        return new GitHubLoad(Login: data.Viewer.Login, Items: new ValueList<GitHubPRSnapshot>(items: items), Notice: Notice(errors: errors ?? []), MoreThanShown: moreThanShown);
    }

    /// What the list says of the errors GitHub answered with alongside what it could read; null without any.
    public static string? Notice(IReadOnlyList<GraphQLError> errors)
    {
        ArgumentNullException.ThrowIfNull(argument: errors);
        if (errors.Count == 0)
        {
            return null;
        }
        if (errors.Any(predicate: error => error.Message.Contains(value: "SAML", comparisonType: StringComparison.OrdinalIgnoreCase)))
        {
            return "Some organizations use single sign-on: authorize the GitHub CLI for them to see their pull requests.";
        }
        return "Some pull requests couldn't be read: " + PlainText.Prefix(text: errors[0].Message, length: NoticeLength);
    }
}
