import AzureDevOpsCore
import BriefBarCore
import Foundation

/// The demo's order of pull requests, as if the Copilot demo's "Roll out dark mode" chat had told BriefBar the order its
/// sessions' pull requests merge in: the account page's first (!4093, which the demo lists, ready to complete), then the
/// checkout page's on GitHub (Priya's #412, which GitHub's demo lists), to be reviewed after it, and the emails' (!4118, which
/// the demo doesn't list, so BriefBar can't see whether it merged).
enum DemoPullRequestOrder {
    static let id = UUID(uuidString: "d4a7c2e9-5b1f-4c83-9e60-2f8b7d1a3c55")!
    /// The Copilot demo's "Roll out dark mode" (scripts/make-copilot-demo-data.swift).
    static let coordinator = ItemRef.session("a3d9c5e1-7b2f-4e84-9c16-5f8e2d0b7a11")!
    static let accountPage = ItemRef.pullRequest(organization: DemoData.organization, number: 4093)
    static let checkoutPage = ItemRef.gitHubPullRequest(repository: "contoso/shop-web", number: 412)
    static let emails = ItemRef.pullRequest(organization: DemoData.organization, number: 4118)

    /// Told when the chat started its sessions, and again when it started the emails' one.
    static func orders(now: Date) -> DeclaredOrders {
        DeclaredOrders(plans: [
            OrderPlan(
                id: id, revision: 2, createdAt: now.addingTimeInterval(-9 * 60), updatedAt: now.addingTimeInterval(-4 * 60),
                declaredBy: coordinator, entries: [
                    OrderPlan.Entry(ref: accountPage),
                    OrderPlan.Entry(ref: checkoutPage, after: [accountPage], review: .after([accountPage], .buildsOnChanges)),
                    OrderPlan.Entry(ref: emails, after: [accountPage]),
                ]
            ),
        ])
    }
}
