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
/// it no longer waits for the retry, which waits for it; and you made a mission of your own of the build agents' upgrade
/// (!4110) and the slow query log (!4099), which you put after it.
/// And the stages you set: on the one-click checkout's prototype, a draft nobody reviews yet, Teammate's review, two
/// hours ago, so it says to find a reviewer; and on the legacy coupon API's removal (!3990), once you'd reviewed what its
/// session wrote, Teammate's review, a day ago, where it waits for Priya with its build expired. And the one "Retry
/// backoff" set on the retry (!4102) as it finished: Your review. And the split Apple Intelligence would suggest for the
/// checkout redesign's mission: taking the delivery estimates out.
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
    static let checkoutSpeed = pullRequest(4113)
    static let buildAgents = pullRequest(4110)
    static let slowQueries = pullRequest(4099)
    /// Your mission of the build agents' upgrade and the slow query log.
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

    /// User Story 5180, "Checkout redesign", outside the sprint: Show Links' demo links its tasks to !4113, !4088 and !4105
    /// (`DemoData.workLinks`), which are its mission.
    static let checkoutRedesign = ItemRef.workItem(organization: DemoData.organization, id: 5180)

    /// Task 5152, "Let shoppers cancel an order before it ships", in the sprint with no story: Show Links' demo links it to
    /// !4115, in payments-api, and !4116, in shop-web (`DemoData.workLinks`), which are its mission.
    static let orderCancellation = ItemRef.workItem(organization: DemoData.organization, id: 5152)

    /// The names Apple Intelligence would give the demo's missions, as their work drifted from where it started: made up,
    /// as the demo never asks the model.
    static let names: [MissionKey: String] = [
        .plan(paymentsID): "Payment retries and coupons",
        .plan(id): "Dark mode everywhere",
        .story(checkoutRedesign): "Faster checkout",
        .story(orderCancellation): "Order cancellation",
        .mine(mineID): "Build agents on .NET 9",
    ]

    /// The split Apple Intelligence would suggest for the checkout redesign's mission, made up, as the demo never asks the
    /// model: the delivery estimates on the product page (!4088) look like other work than the checkout page's speed-up
    /// (!4113) and one-click checkout (!4105), so they keep the mission, with the name it has, and it goes out of By Mission.
    static let split: (key: MissionKey, grouping: [Set<ItemRef>], names: [String?]) = (
        .story(checkoutRedesign), [[checkoutSpeed, oneClickCheckout], [deliveryEstimates]], ["Faster checkout", nil]
    )

    /// The stages you set: the one-click checkout's prototype, for a teammate's review, two hours ago; and the legacy coupon
    /// API's removal, a day ago, once you'd reviewed what "Remove the legacy coupon API" wrote, so that it waits for Priya
    /// with its build expired, rather than for your review.
    static func stages(now: Date) -> [ItemRef: StageMark] {
        [
            oneClickCheckout: StageMark(stage: .teammateReview, at: now.addingTimeInterval(-2 * 3_600)),
            legacyCoupons: StageMark(stage: .teammateReview, at: now.addingTimeInterval(-25 * 3_600)),
        ]
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
            OrderChange(ref: buildAgents, placement: mine, changedAt: now.addingTimeInterval(-30 * 60)),
            OrderChange(ref: slowQueries, after: [buildAgents], placement: mine, changedAt: now.addingTimeInterval(-29 * 60)),
        ])
    }

    // MARK: My Work's Map

    /// The Copilot demo's "Save items for later", which worked out what waits for what in the checkout redesign.
    static let savedItems = ItemRef.session("c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11")!

    /// The demo's steps on My Work's Map, made up, with fixed IDs.
    static let apiTests = step(1), endToEndTests = step(2), testInDev = step(3), monitoring = step(4), staging = step(5),
        production = step(6), announcement = step(7), loadTest = step(8), retriesInProduction = step(9), couponData = step(10)

    private static func step(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "5e9a1c00-3b7d-4f2a-9c11-%012d", number))!
    }

    private static func workItem(_ id: Int) -> MapNodeID {
        .card(.workItem(organization: DemoData.organization, id: id))
    }

    /// What you and the demo's sessions said on My Work's Map, as if "Save items for later" had worked out what waits for
    /// what in the checkout redesign, through ✨ Ask Copilot, and "Fix the payments bugs" in the payments' work:
    /// - The checkout redesign's three flows: the one-click checkout (!4105) after the checkout page's speed-up (!4113) and
    ///   the delivery estimates (!4088); the Cancel button (!4116) after the cancellation endpoint (!4115); and moving a saved
    ///   item back to the cart (Task 5104) after showing them (Task 5103), which you said, after the saved items' table
    ///   (Task 5102). Then API tests after all of them, end-to-end tests after the three flows, testing in dev after the API
    ///   tests, monitoring and alerts after that, enabling it in staging after all that, in production after everything, and
    ///   your announcement after production.
    /// - The payments: load testing the retries after the retry (!4102) and the public API's rate limiting (!4060), then
    ///   enabling them in production; and migrating the coupon data after the rounding fix (!4091), before the legacy coupon
    ///   API's removal (!3990).
    static func map(now: Date) -> (yours: MapEdits, told: MapEdits) {
        let checkout = MapAuthor.session(savedItems)
        let payments = MapAuthor.session(Self.payments)
        var told = MapEdits()
        var yours = MapEdits()
        var at = now.addingTimeInterval(-5 * 3_600)
        func next() -> Date {
            at += 1
            return at
        }
        for (id, name) in [
            (apiTests, "API tests"), (endToEndTests, "End-to-end tests"), (testInDev, "Test in dev"), (monitoring, "Monitoring and alerts"),
            (staging, "Enable in staging"), (production, "Enable in production"),
        ] {
            told.addStep(id, name: name, home: nil, by: checkout, at: next())
        }
        let flows: [MapNodeID] = [.card(checkoutSpeed), .card(deliveryEstimates), .card(oneClickCheckout), .card(pullRequest(4115)),
                                  .card(pullRequest(4116)), workItem(5103), workItem(5104)]
        let lines: [(MapNodeID, MapNodeID)] = [
            (.card(checkoutSpeed), .card(oneClickCheckout)), (.card(deliveryEstimates), .card(oneClickCheckout)),
            (.card(pullRequest(4115)), .card(pullRequest(4116))),
        ] + flows.map { ($0, .step(apiTests)) }
            + [.card(oneClickCheckout), .card(pullRequest(4116)), workItem(5104)].map { ($0, .step(endToEndTests)) }
            + [(.step(apiTests), .step(testInDev)), (.step(testInDev), .step(monitoring))]
            + [apiTests, endToEndTests, testInDev, monitoring].map { (.step($0), .step(staging)) }
            + (flows + [.step(staging)]).map { ($0, .step(production)) }
        for (before, after) in lines {
            told.set(MapEdits.Line(before, after), on: true, by: checkout, at: next())
        }
        yours.set(MapEdits.Line(workItem(5102), workItem(5103)), on: true, by: .you, at: next())
        yours.set(MapEdits.Line(workItem(5103), workItem(5104)), on: true, by: .you, at: next())
        yours.addStep(announcement, name: "Announce it", home: .story(checkoutRedesign), by: .you, at: next())
        yours.set(MapEdits.Line(.step(production), .step(announcement)), on: true, by: .you, at: next())

        at = now.addingTimeInterval(-3 * 3_600)
        for (id, name) in [(loadTest, "Load test the retries"), (retriesInProduction, "Enable retries in production"), (couponData, "Migrate coupon data")] {
            told.addStep(id, name: name, home: nil, by: payments, at: next())
        }
        for (before, after) in [
            (MapNodeID.card(retry), MapNodeID.step(loadTest)), (.card(pullRequest(4060)), .step(loadTest)),
            (.step(loadTest), .step(retriesInProduction)), (.card(couponRounding), .step(couponData)),
            (.step(couponData), .card(legacyCoupons)),
        ] {
            told.set(MapEdits.Line(before, after), on: true, by: payments, at: next())
        }
        return (yours, told)
    }
}
