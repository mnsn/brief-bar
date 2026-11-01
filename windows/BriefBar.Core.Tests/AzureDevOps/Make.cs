using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Made-up pull requests, details and comments, as the Swift tests' `makePR`, `makeDetails` and `comment`. Times are
/// `TestTimes.T`'s, seconds after the tests' reference time.
internal static class Make
{
    public const double Minute = 60;
    public const double Hour = 3_600;
    public const double Day = 86_400;

    /// `contoso/7`, "Fix the checkout total", yours, created two days before the reference time, in project "Shop" (`p1`)
    /// and repository "shop-web" (`r1`), from `fix-total` into `main`.
    public static PullRequest PR(
        int number = 7,
        string title = "Fix the checkout total",
        PullRequestStatus status = PullRequestStatus.Active,
        Person? author = null,
        DateTimeOffset? created = null,
        DateTimeOffset? closed = null,
        IEnumerable<Reviewer>? reviewers = null,
        bool draft = false,
        string? merge = "succeeded",
        bool autoComplete = false,
        string organization = "contoso") => new()
        {
            Key = new PRKey(Organization: organization, Number: number),
            Title = title,
            Status = status,
            Author = author ?? People.Me,
            CreatedAt = created ?? TestTimes.T(seconds: -2 * Day),
            ClosedAt = closed,
            ProjectId = "p1",
            ProjectName = "Shop",
            RepositoryId = "r1",
            RepositoryName = "shop-web",
            SourceBranch = "fix-total",
            TargetBranch = "main",
            IsDraft = draft,
            MergeStatus = merge,
            Reviewers = new ValueList<Reviewer>(items: reviewers ?? []),
            AutoComplete = autoComplete,
            SourceCommit = "abc",
            TargetCommit = "def",
        };

    /// `pr`'s details, read at the reference time, current for it; its last activity is its latest comment or activity
    /// unless said.
    public static PRDetails Details(
        PullRequest pr,
        IEnumerable<Check>? checks = null,
        bool checksKnown = true,
        IEnumerable<ReviewThread>? threads = null,
        IEnumerable<Activity>? activity = null,
        DateTimeOffset? lastActivity = null)
    {
        var threadList = (threads ?? []).ToList();
        var activityList = (activity ?? []).ToList();
        var dates = threadList.SelectMany(selector: thread => thread.Comments.Select(selector: comment => comment.PublishedAt)).Concat(second: activityList.Select(selector: item => item.At)).ToList();
        return new PRDetails
        {
            FetchedAt = TestTimes.T(seconds: 0),
            Fingerprint = pr.Fingerprint,
            Checks = new ValueList<Check>(items: checks ?? []),
            ChecksKnown = checksKnown,
            Threads = new ValueList<ReviewThread>(items: threadList),
            Activity = new ValueList<Activity>(items: activityList),
            LastActivity = lastActivity ?? (dates.Count > 0 ? dates.Max() : null),
        };
    }

    public static ReviewComment Comment(int id, Person author, DateTimeOffset at, string text = "A comment", IEnumerable<Person>? mentions = null) =>
        new(id: id, author: author, text: text, publishedAt: at, mentions: (mentions ?? []).Select(selector: person => person.Id));
}
