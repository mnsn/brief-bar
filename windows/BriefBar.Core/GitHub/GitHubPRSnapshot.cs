namespace BriefBar.Core.GitHub;

/// A pull request as the list shows it: why it's where it is, what it's waiting for in a few words (`Headline`, "Checks
/// failing"), and who (`Detail`, "By priya"). The Mac's `GitHubPRSnapshot`.
public sealed record GitHubPRSnapshot(
    GitHubPullRequest PullRequest, GitHubPRRole Role, GitHubPRGroup Group, GitHubPRReason Reason, string Headline, string? Detail = null)
{
    public string Id => PullRequest.Id;

    /// When it last changed.
    public DateTimeOffset Since => PullRequest.UpdatedAt;

    /// A brief's line in BriefBar's own words.
    public string BriefSentence
    {
        get
        {
            var title = "“" + PullRequest.Title + "”";
            switch (Reason)
            {
                case GitHubPRReason.ReviewRequested:
                    return PullRequest.Author is { } author ? author + " asks for your review on " + title + "." : "Your review is requested on " + title + ".";
                case GitHubPRReason.ChangesRequested:
                    var reviewers = PullRequest.Reviewers(state: GitHubReviewState.ChangesRequested);
                    return reviewers.Count == 0
                        ? "Changes are requested on " + title + "."
                        : GitHubClassifier.Names(names: reviewers) + " requested changes on " + title + ".";
                case GitHubPRReason.ChecksFailed:
                    return "Checks are failing on " + title + ".";
                case GitHubPRReason.Conflicts:
                    return title + " has merge conflicts.";
                case GitHubPRReason.Approved:
                    return title + " is approved.";
                case GitHubPRReason.ChecksRunning:
                    return "Checks are running on " + title + ".";
                case GitHubPRReason.Draft:
                    return title + " is a draft.";
                case GitHubPRReason.WaitingForReview:
                    return title + " is waiting for review.";
                default:
                    throw new InvalidOperationException(message: "A reason BriefBar doesn't know.");
            }
        }
    }
}
