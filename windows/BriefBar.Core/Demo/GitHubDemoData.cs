using BriefBar.Core.GitHub;

namespace BriefBar.Core.Demo;

/// Made-up pull requests in every group, for working on the UI and taking screenshots without showing real ones
/// (`--demo`): the Mac's `GitHubDemoData`. Times are relative to `now`.
public static class GitHubDemoData
{
    public const string Login = "robin";

    /// The groups the demo pull requests land in.
    public static IReadOnlyDictionary<GitHubPRGroup, int> ExpectedCounts { get; } = new Dictionary<GitHubPRGroup, int>
    {
        [GitHubPRGroup.ToReview] = 2,
        [GitHubPRGroup.ChangesRequested] = 1,
        [GitHubPRGroup.Failing] = 2,
        [GitHubPRGroup.Ready] = 1,
        [GitHubPRGroup.Waiting] = 2,
    };

    public static GitHubLoad Load(DateTimeOffset now) => new(
        Login: Login,
        Items: [.. GitHubClassifier.Snapshots(reviewing: Reviewing(now: now), authored: Authored(now: now))]);

    static List<GitHubPullRequest> Reviewing(DateTimeOffset now) =>
    [
        PullRequest(
            number: 412, title: "Add dark mode to the checkout page", repository: "contoso/shop-web", author: "priya", branch: "priya/checkout-dark-mode",
            updated: now.AddMinutes(minutes: -25), reviewDecision: GitHubReviewDecision.ReviewRequired, checks: GitHubChecks.Passing),
        PullRequest(
            number: 198, title: "Cache product images on the CDN", repository: "contoso/shop-api", author: "sam", branch: "sam/image-cdn",
            updated: now.AddHours(hours: -3), reviewDecision: GitHubReviewDecision.ReviewRequired, checks: GitHubChecks.Running),
    ];

    static List<GitHubPullRequest> Authored(DateTimeOffset now) =>
    [
        PullRequest(
            number: 201, title: "Validate coupon codes on the server", repository: "contoso/shop-api", branch: "validate-coupons",
            updated: now.AddMinutes(minutes: -50), reviewDecision: GitHubReviewDecision.ChangesRequested, checks: GitHubChecks.Passing,
            reviews: [new GitHubReview(Reviewer: "sam", State: GitHubReviewState.ChangesRequested)]),
        PullRequest(
            number: 77, title: "Upgrade to Swift 6.2", repository: "contoso/shop-ios", branch: "swift-6.2",
            updated: now.AddMinutes(minutes: -15), reviewDecision: GitHubReviewDecision.ReviewRequired, checks: GitHubChecks.Failing),
        PullRequest(
            number: 405, title: "Rename the cart service", repository: "contoso/shop-web", branch: "rename-cart-service",
            updated: now.AddHours(hours: -2), reviewDecision: GitHubReviewDecision.ReviewRequired, conflicts: true, checks: GitHubChecks.Passing),
        PullRequest(
            number: 409, title: "Fix the tax rounding", repository: "contoso/shop-web", branch: "fix-tax-rounding",
            updated: now.AddHours(hours: -1), reviewDecision: GitHubReviewDecision.Approved, checks: GitHubChecks.Passing,
            reviews: [new GitHubReview(Reviewer: "priya", State: GitHubReviewState.Approved)]),
        PullRequest(
            number: 203, title: "Add order history export", repository: "contoso/shop-api", branch: "order-history-export",
            updated: now.AddMinutes(minutes: -5), reviewDecision: GitHubReviewDecision.ReviewRequired, checks: GitHubChecks.Running),
        PullRequest(
            number: 80, title: "Spike: one-tap reorder", repository: "contoso/shop-ios", branch: "one-tap-reorder", draft: true,
            updated: now.AddHours(hours: -26)),
    ];

    static GitHubPullRequest PullRequest(
        int number,
        string title,
        string repository,
        DateTimeOffset updated,
        string author = Login,
        string? branch = null,
        bool draft = false,
        GitHubReviewDecision? reviewDecision = null,
        bool conflicts = false,
        GitHubChecks? checks = null,
        IReadOnlyList<GitHubReview>? reviews = null) =>
        new(
            Id: "PR_demo_" + repository.Split(separator: '/')[^1] + "_" + number.ToString(provider: System.Globalization.CultureInfo.InvariantCulture),
            Number: number,
            Title: title,
            Url: new Uri(uriString: "https://github.com/" + repository + "/pull/" + number.ToString(provider: System.Globalization.CultureInfo.InvariantCulture)),
            Repository: repository,
            Author: author,
            CreatedAt: updated.AddDays(days: -2),
            UpdatedAt: updated)
        {
            IsDraft = draft,
            ReviewDecision = reviewDecision,
            HasConflicts = conflicts,
            Checks = checks,
            Reviews = [.. reviews ?? []],
            Branch = branch,
        };
}
