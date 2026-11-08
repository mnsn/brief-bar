import AzureDevOpsCore
import BriefBarCore
import Foundation

/// The demo's orders of pull requests, as if the Copilot demo's chats had told BriefBar the order their sessions' pull
/// requests merge in (scripts/make-copilot-demo-data.swift):
/// - "Fix the payments bugs": !4074, which BriefBar saw merge yesterday and no list has now; then the retry (!4102, which
///   needs you); then the coupon rounding (!4091, ready to complete, so its capsule turns orange) and the order status
///   rename (!4079), each after it; then the legacy coupon API's removal (!3990), after both, to be reviewed after the
///   rounding. You focus on it.
/// - "Roll out dark mode": the account page's (!4093, ready to complete), then the checkout page's on GitHub (Priya's #412,
///   which GitHub's demo lists), to be reviewed after it, and the emails' (!4118, which the demo doesn't list, so BriefBar
///   can't see whether it merged).
///
/// And your changes to them (`OrderChanges`): you set the order status rename (!4079) as next to merge, two hours ago, so
/// it no longer waits for the retry, which waits for it; and you made a mission of your own of the delivery estimates
/// (!4088) and the one-click checkout's prototype (!4105), which you put after them.
/// And the stage you set on the one-click checkout's prototype, a draft nobody reviews yet: Teammate's review, two
/// hours ago, so it says to find a reviewer; and the one "Retry backoff" set on the retry (!4102) as it finished: Your
/// review.
enum DemoPullRequestOrder {
    static let paymentsID = UUID(uuidString: "b81f4e27-6a3c-4d95-8e10-3c7a9d2f4b66")!
    static let id = UUID(uuidString: "d4a7c2e9-5b1f-4c83-9e60-2f8b7d1a3c55")!
    /// The Copilot demo's "Fix the payments bugs".
    static let payments = ItemRef.session("e5b7d2c9-3f1a-4c86-9b20-7d4e1a8c6f17")!
    /// The Copilot demo's "Roll out dark mode".
    static let coordinator = ItemRef.session("a3d9c5e1-7b2f-4e84-9c16-5f8e2d0b7a11")!
    static let retryPolicy = pullRequest(4074)
    static let retry = pullRequest(4102)
    static let couponRounding = pullRequest(4091)
    static let statusRename = pullRequest(4079)
    static let legacyCoupons = pullRequest(3990)
    static let accountPage = pullRequest(4093)
    static let checkoutPage = ItemRef.gitHubPullRequest(repository: "contoso/shop-web", number: 412)
    static let emails = pullRequest(4118)
    static let deliveryEstimates = pullRequest(4088)
    static let oneClickCheckout = pullRequest(4105)
    /// Your mission of the delivery estimates and the one-click checkout.
    static let mineID = UUID(uuidString: "6c2e9f41-8b3d-4a57-9e12-0d4f7b3a5c88")!

    static func pullRequest(_ number: Int) -> ItemRef {
        .pullRequest(organization: DemoData.organization, number: number)
    }

    /// The payments' order, told when the chat started its sessions and again as they went; and the dark mode's, told when
    /// the chat started its sessions, and again when it started the emails' one.
    static func orders(now: Date) -> DeclaredOrders {
        DeclaredOrders(plans: [
            OrderPlan(
                id: paymentsID, revision: 3, createdAt: now.addingTimeInterval(-27 * 3_600), updatedAt: now.addingTimeInterval(-3 * 3_600),
                declaredBy: payments, entries: [
                    OrderPlan.Entry(ref: retryPolicy),
                    OrderPlan.Entry(ref: retry, after: [retryPolicy]),
                    OrderPlan.Entry(ref: couponRounding, after: [retry]),
                    OrderPlan.Entry(ref: statusRename, after: [retry]),
                    OrderPlan.Entry(ref: legacyCoupons, after: [couponRounding, statusRename], review: .after([couponRounding], .sameCode)),
                ]
            ),
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

    /// What BriefBar saw become of the payments' first pull request, yesterday, while Done still listed it.
    static func evidence(now: Date) -> OrderEvidence {
        OrderEvidence(records: [
            retryPolicy: OrderEvidence.Record(outcome: .merged, observedAt: now.addingTimeInterval(-22 * 3_600), witness: .list),
        ])
    }

    /// The mission you focus on.
    static let focus = MissionKey.plan(paymentsID)

    /// The stages you set: the one-click checkout's prototype, for a teammate's review, two hours ago.
    static func stages(now: Date) -> [ItemRef: StageMark] {
        [oneClickCheckout: StageMark(stage: .teammateReview, at: now.addingTimeInterval(-2 * 3_600))]
    }

    /// The Copilot demo's "Retry backoff", which opened the retry (!4102).
    static let retryBackoff = ItemRef.session("2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14")!

    /// The stages sessions set (`pull_request_stage`): "Retry backoff" said the retry was ready for your review as it
    /// pushed its work and finished.
    static func sessionStages(now: Date) -> [ItemRef: StageMark] {
        [retry: StageMark(stage: .yourReview, at: now.addingTimeInterval(-26 * 3_600), by: retryBackoff)]
    }

    /// Your changes: the order status rename set as next to merge, and a mission of your own.
    static func changes(now: Date) -> OrderChanges {
        let orders = orders(now: now)
        let mine = OrderPlacement.into(.mine(mineID))
        return OrderChanges([
            OrderChange(
                ref: statusRename, first: .plan(paymentsID), changedAt: now.addingTimeInterval(-2 * 3_600),
                replaced: OrderPlace(of: statusRename, in: orders)
            ),
            OrderChange(ref: deliveryEstimates, placement: mine, changedAt: now.addingTimeInterval(-50 * 60)),
            OrderChange(
                ref: oneClickCheckout, after: [deliveryEstimates], placement: mine, changedAt: now.addingTimeInterval(-49 * 60)
            ),
        ])
    }
}
