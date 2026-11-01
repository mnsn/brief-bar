namespace BriefBar.Core.GitHub;

/// What `GitHubClient.PullRequestsAsync` reads, with the errors GitHub answered about parts it couldn't, such as an
/// organization's pull requests that need single sign-on. The Mac's `PullRequestQueryResult`.
public sealed record PullRequestQueryResult(PullRequestQueryData Data, ValueList<GraphQLError> Errors);
