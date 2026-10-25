import Foundation

/// Made-up pull requests in every group, for working on the UI and taking screenshots without showing real ones
/// (`--demo`, `make demo`, `make screenshots`). Times are relative to `now`.
public enum GitHubDemoData {
    public static let login = "robin"

    /// The groups the demo pull requests land in; `make demo-check` compares them with the app's.
    public static let expectedCounts: [String: Int] = [
        "toReview": 2, "changesRequested": 1, "failing": 2, "ready": 1, "waiting": 2,
    ]

    public static func load(now: Date = Date()) -> GitHubLoad {
        GitHubLoad(
            login: login,
            items: GitHubClassifier.snapshots(reviewing: reviewing(now: now), authored: authored(now: now))
        )
    }

    static func reviewing(now: Date) -> [GitHubPullRequest] {
        [
            pullRequest(
                412, "Add dark mode to the checkout page", repository: "contoso/shop-web", author: "priya",
                updated: now.addingTimeInterval(-25 * 60), reviewDecision: .reviewRequired, checks: .passing
            ),
            pullRequest(
                198, "Cache product images on the CDN", repository: "contoso/shop-api", author: "sam",
                updated: now.addingTimeInterval(-3 * 3_600), reviewDecision: .reviewRequired, checks: .running
            ),
        ]
    }

    static func authored(now: Date) -> [GitHubPullRequest] {
        [
            pullRequest(
                201, "Validate coupon codes on the server", repository: "contoso/shop-api",
                updated: now.addingTimeInterval(-50 * 60), reviewDecision: .changesRequested, checks: .passing,
                reviews: [.init(reviewer: "sam", state: .changesRequested)]
            ),
            pullRequest(
                77, "Upgrade to Swift 6.2", repository: "contoso/shop-ios",
                updated: now.addingTimeInterval(-15 * 60), reviewDecision: .reviewRequired, checks: .failing
            ),
            pullRequest(
                405, "Rename the cart service", repository: "contoso/shop-web",
                updated: now.addingTimeInterval(-2 * 3_600), reviewDecision: .reviewRequired, conflicts: true,
                checks: .passing
            ),
            pullRequest(
                409, "Fix the tax rounding", repository: "contoso/shop-web",
                updated: now.addingTimeInterval(-3_600), reviewDecision: .approved, checks: .passing,
                reviews: [.init(reviewer: "priya", state: .approved)]
            ),
            pullRequest(
                203, "Add order history export", repository: "contoso/shop-api",
                updated: now.addingTimeInterval(-5 * 60), reviewDecision: .reviewRequired, checks: .running
            ),
            pullRequest(
                80, "Spike: one-tap reorder", repository: "contoso/shop-ios", draft: true,
                updated: now.addingTimeInterval(-26 * 3_600)
            ),
        ]
    }

    private static func pullRequest(
        _ number: Int, _ title: String, repository: String, author: String = login, draft: Bool = false, updated: Date,
        reviewDecision: GitHubPullRequest.ReviewDecision? = nil, conflicts: Bool = false,
        checks: GitHubPullRequest.Checks? = nil, reviews: [GitHubPullRequest.Review] = []
    ) -> GitHubPullRequest {
        GitHubPullRequest(
            id: "PR_demo_\(repository.split(separator: "/").last ?? "")_\(number)", number: number, title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!, repository: repository, author: author,
            isDraft: draft, createdAt: updated.addingTimeInterval(-2 * 86_400), updatedAt: updated,
            reviewDecision: reviewDecision, hasConflicts: conflicts, checks: checks, reviews: reviews
        )
    }
}
