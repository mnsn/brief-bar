import Foundation

/// A made-up sprint and pipelines, like the made-up pull requests, for `--demo` and the screenshots. Times
/// are relative to `now`.
extension DemoData {
    public static let team = TeamRef(
        organization: organization, projectId: "7a0c4e1d-0000-4000-8000-000000000001", projectName: "Storefront",
        id: "7a0c4e1d-0000-4000-8000-000000000101", name: "Storefront Team"
    )

    /// Another of your teams, to choose from.
    public static let otherTeam = TeamRef(
        organization: organization, projectId: "7a0c4e1d-0000-4000-8000-000000000001", projectName: "Storefront",
        id: "7a0c4e1d-0000-4000-8000-000000000102", name: "Payments Team"
    )

    /// Sprint 42, on its tenth day of fourteen.
    public static func sprint(now: Date = Date(), calendar: Calendar = .current) -> Sprint {
        Sprint(
            id: "7a0c4e1d-0000-4000-8000-000000000201", name: "Sprint 42", path: "Storefront\\Sprint 42",
            start: SprintDay.date(daysFromToday: -9, now: now, calendar: calendar),
            finish: SprintDay.date(daysFromToday: 4, now: now, calendar: calendar)
        )
    }

    /// The sprint's task board: stories and a bug with their tasks, a story without tasks yet, a finished one,
    /// and a task without a story.
    public static func sprintBoard(now: Date = Date(), calendar: Calendar = .current) -> SprintBoard {
        let people = (me: me, sam: sam, priya: priya, alex: alex, jordan: jordan, maria: maria, chen: chen)
        func item(
            _ id: Int, _ type: String, _ title: String, _ state: String, _ who: Person?, parent: Int? = nil, hours: Double? = nil,
            rank: Double, changed: Double = 60
        ) -> WorkItem {
            WorkItem(
                id: id, organization: organization, project: team.projectName, type: type, title: title, state: state,
                category: WorkItem.Category(category: nil, state: state), assignedTo: who, parentId: parent,
                remainingWork: state == "Closed" ? 0 : hours, rank: rank, changedAt: now.addingTimeInterval(-changed * 60)
            )
        }
        let items = [
            item(5101, "User Story", "Save items for later from the cart", "Active", people.me, rank: 1),
            item(5102, "Task", "Add a saved items table to the cart service", "Closed", people.me, parent: 5101, rank: 1),
            item(5103, "Task", "Show saved items under the cart", "Active", people.me, parent: 5101, hours: 3, rank: 2, changed: 25),
            item(5104, "Task", "Move a saved item back to the cart", "New", people.me, parent: 5101, hours: 2, rank: 3),
            item(5105, "Task", "Test saving with an empty cart", "New", people.sam, parent: 5101, hours: 1, rank: 4),

            item(5110, "Bug", "Coupon totals round down instead of to the nearest cent", "Active", people.priya, rank: 2),
            item(5111, "Task", "Reproduce with a negative total", "Closed", people.priya, parent: 5110, rank: 1),
            item(5112, "Task", "Round half up in the coupon service", "Active", people.me, parent: 5110, hours: 2, rank: 2, changed: 90),
            item(5113, "Task", "Add rounding tests for every currency", "New", people.priya, parent: 5110, hours: 3, rank: 3),

            item(5120, "User Story", "Pay with a gift card at checkout", "Active", people.alex, rank: 3),
            item(5121, "Task", "Design the gift card field", "Closed", people.maria, parent: 5120, rank: 1),
            item(5122, "Task", "Check gift card codes with the payments API", "Active", people.alex, parent: 5120, hours: 5, rank: 2),
            item(5123, "Task", "Show the balance left after paying", "New", people.alex, parent: 5120, hours: 3, rank: 3),
            item(5124, "Task", "Update the checkout analytics events", "New", nil, parent: 5120, hours: 2, rank: 4),

            item(5130, "User Story", "Track an order from the account page", "New", people.jordan, rank: 4),

            item(5140, "User Story", "Show search results faster", "Closed", people.chen, rank: 5),
            item(5141, "Task", "Cache popular searches", "Closed", people.chen, parent: 5140, rank: 1),
            item(5142, "Task", "Load test the search API", "Closed", people.chen, parent: 5140, rank: 2),

            item(5150, "Task", "Prepare the sprint review demo", "New", people.me, hours: 1, rank: 9),
        ]
        var relations: [ADOIterationWorkItems.Relation] = []
        for item in items where item.parentId == nil {
            relations.append(.init(rel: nil, source: nil, target: .init(id: item.id)))
        }
        for item in items {
            if let parent = item.parentId {
                relations.append(.init(rel: "System.LinkTypes.Hierarchy-Forward", source: .init(id: parent), target: .init(id: item.id)))
            }
        }
        return SprintBoard.build(
            team: team, sprint: sprint(now: now, calendar: calendar), me: me.id, relations: relations, items: items, taskTypes: ["Task"]
        )
    }

    /// More of the project's pipelines, to find and pin.
    public static let morePipelines: [PipelineRef] = [
        PipelineRef(organization: organization, projectId: team.projectId, projectName: team.projectName, definitionId: 33,
                    name: "search CI", folder: "Storefront\\CI"),
        PipelineRef(organization: organization, projectId: team.projectId, projectName: team.projectName, definitionId: 34,
                    name: "infra CI", folder: "Storefront\\CI"),
        PipelineRef(organization: organization, projectId: team.projectId, projectName: team.projectName, definitionId: 41,
                    name: "Storefront docs", folder: "Storefront\\Release"),
    ]

    /// Four pipelines: one that just failed its tests, one running, a release waiting for approval to go to
    /// production, and a nightly run that succeeded with issues.
    public static func pipelines(now: Date = Date()) -> [PipelineStatus] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func ref(_ id: Int, _ name: String, _ folder: String) -> PipelineRef {
            PipelineRef(organization: organization, projectId: team.projectId, projectName: team.projectName, definitionId: id,
                        name: name, folder: folder)
        }
        let dayFormat = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)", timeZone: .current, calendar: Calendar(identifier: .gregorian)
        )
        var nextId = 81_000
        /// Runs from the oldest to the newest, each `(status, minutes it took, minutes ago it finished)`.
        func runs(
            _ history: [(PipelineRun.Status, Double, Double)], trigger: PipelineRun.Trigger = .push, branch: String = "main",
            by: String? = nil
        ) -> [PipelineRun] {
            var counts: [String: Int] = [:]
            return history.map { status, minutes, finishedAgo in
                nextId += 1
                let finished = ago(finishedAgo)
                let started = finished.addingTimeInterval(-minutes * 60)
                let day = started.formatted(dayFormat)
                counts[day, default: 0] += 1
                let isFinished = status.isFinished
                return PipelineRun(
                    id: nextId, organization: organization, projectName: team.projectName, number: "\(day).\(counts[day]!)",
                    status: status, trigger: trigger, branch: branch, requestedFor: by,
                    queuedAt: started.addingTimeInterval(-40), startedAt: status == .queued ? nil : started,
                    finishedAt: isFinished ? finished : nil
                )
            }.reversed()
        }
        func stage(_ id: Int, _ name: String, _ state: PipelineStage.State, _ startedAgo: Double? = nil, _ minutes: Double? = nil) -> PipelineStage {
            let started = startedAgo.map(ago)
            return PipelineStage(
                id: "stage-\(id)", name: name, state: state, startedAt: started,
                finishedAt: started.flatMap { start in minutes.map { start.addingTimeInterval($0 * 60) } }
            )
        }

        let shopWeb = PipelineStatus(
            pipeline: ref(31, "shop-web CI", "Storefront\\CI"),
            runs: runs([
                (.succeeded, 7.5, 2_950), (.succeeded, 8.1, 2_400), (.failed, 3.2, 1_900), (.succeeded, 7.9, 1_700),
                (.succeeded, 8.4, 1_300), (.succeeded, 7.2, 900), (.succeeded, 8.8, 420), (.succeeded, 7.7, 180),
                (.failed, 6.2, 65),
            ], by: "Robin Diaz"),
            stages: [stage(1, "Build", .succeeded, 71, 2.3), stage(2, "Test", .failed, 68.6, 3.6), stage(3, "Publish", .skipped)],
            failure: PipelineFailure(stage: "Test", step: "Run unit tests", message: "2 tests failed in DeliveryEstimateTests.")
        )

        var paymentsRuns = runs([
            (.succeeded, 11.2, 3_100), (.succeeded, 10.8, 2_600), (.succeeded, 12.1, 2_000), (.partiallySucceeded, 12.6, 1_500),
            (.succeeded, 10.4, 1_100), (.succeeded, 11.5, 600), (.succeeded, 10.9, 240), (.succeeded, 11.1, 95),
        ], by: "Sam Rivera")
        nextId += 1
        paymentsRuns.insert(PipelineRun(
            id: nextId, organization: organization, projectName: team.projectName, number: "\(now.formatted(dayFormat)).4",
            status: .running, trigger: .push, branch: "main", requestedFor: "Sam Rivera",
            queuedAt: ago(5.6), startedAt: ago(5.3)
        ), at: 0)
        let payments = PipelineStatus(
            pipeline: ref(32, "payments-api CI", "Storefront\\CI"),
            runs: paymentsRuns,
            stages: [stage(4, "Build", .succeeded, 5.3, 2.2), stage(5, "Test", .running, 3.1), stage(6, "Package", .pending)]
        )

        var releaseRuns = runs([
            (.succeeded, 34, 10_200), (.succeeded, 31, 8_800), (.canceled, 12, 7_300), (.succeeded, 36, 5_900),
            (.succeeded, 33, 4_400), (.succeeded, 35, 2_900),
        ], trigger: .manual, by: "Maria Garcia")
        nextId += 1
        releaseRuns.insert(PipelineRun(
            id: nextId, organization: organization, projectName: team.projectName, number: "\(now.formatted(dayFormat)).1",
            status: .running, trigger: .manual, branch: "main", requestedFor: "Maria Garcia", queuedAt: ago(48), startedAt: ago(47)
        ), at: 0)
        let release = PipelineStatus(
            pipeline: ref(40, "Storefront release", "Storefront\\Release"),
            runs: releaseRuns,
            stages: [stage(7, "Build", .succeeded, 47, 6.5), stage(8, "Deploy to staging", .succeeded, 40, 9.8),
                     stage(9, "Smoke tests", .succeeded, 30, 4.4), stage(10, "Deploy to production", .waiting)]
        )

        let nightly = PipelineStatus(
            pipeline: ref(51, "Nightly load test", "Storefront"),
            // The sums are Doubles: Swift 6.1 would take a sum of whole numbers in this list for an Int.
            runs: runs([
                (.succeeded, 42, 8_640.0 + 420), (.succeeded, 44, 7_200.0 + 420), (.succeeded, 41, 5_760.0 + 420), (.failed, 18, 4_320.0 + 420),
                (.succeeded, 43, 2_880.0 + 420), (.succeeded, 45, 1_440.0 + 420), (.partiallySucceeded, 47, 420),
            ], trigger: .schedule),
            stages: [stage(11, "Load test", .warning, 467, 39), stage(12, "Report", .succeeded, 428, 8)]
        )
        return [shopWeb, payments, release, nightly]
    }
}

// MARK: - Work item details

extension DemoData {
    /// A made-up sprint work item's details: what it's about, as HTML or Markdown, its links and its discussion. Nil for a
    /// work item the made-up sprint doesn't have.
    public static func workItemDetails(
        organization: String, id: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> WorkItemDetails? {
        let board = sprintBoard(now: now, calendar: calendar)
        let items = board.rows.flatMap { ($0.parent.map { [$0] } ?? []) + $0.tasks }
        guard organization.caseInsensitiveCompare(self.organization) == .orderedSame,
              var item = items.first(where: { $0.id == id })
        else { return nil }
        func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
        let made = demoDetails(id)
        item.tags = made.tags

        var links: [WorkItemDetails.Link] = []
        if let parent = items.first(where: { $0.id == item.parentId }) {
            links.append(WorkItemDetails.Link(kind: .parent, name: "Parent", workItemId: parent.id, item: parent))
        }
        for child in items where child.parentId == id {
            links.append(WorkItemDetails.Link(kind: .child, name: "Child", workItemId: child.id, item: child))
        }
        for related in made.related {
            links.append(WorkItemDetails.Link(kind: .other, name: "Related", workItemId: related, item: items.first { $0.id == related }))
        }
        var texts: [WorkItemDetails.LongText] = []
        for (field, title, text) in [
            ("System.Description", "Description", made.description),
            ("Microsoft.VSTS.TCM.ReproSteps", "Repro Steps", made.reproSteps),
            ("Microsoft.VSTS.TCM.SystemInfo", "System Info", made.systemInfo),
            ("Microsoft.VSTS.Common.AcceptanceCriteria", "Acceptance Criteria", made.acceptanceCriteria),
        ] {
            guard let text else { continue }
            let rich = field == "System.Description" && made.isMarkdown ? RichText(markdown: text) : RichText(html: text)
            texts.append(WorkItemDetails.LongText(id: field, title: title, text: rich))
        }
        let comments = made.comments.enumerated().map { index, comment in
            WorkItemDetails.Comment(
                id: id * 10 + made.comments.count - index, author: comment.author, createdAt: ago(hours: comment.hoursAgo),
                text: RichText(html: comment.html)
            )
        }
        let reason: String? = switch item.category {
        case .proposed: "New"
        case .inProgress, .resolved: "Work started"
        case .completed: "Work finished"
        case .removed: nil
        }
        return WorkItemDetails(
            item: item, reason: reason, areaPath: made.area, iterationPath: sprint(now: now, calendar: calendar).path,
            priority: made.priority, severity: made.severity, size: made.size, sizeTitle: "Story Points", originalEstimate: made.estimate,
            completedWork: made.completed, activity: made.activity, createdBy: made.createdBy ?? item.assignedTo ?? sam,
            createdAt: ago(hours: made.createdDaysAgo * 24), changedBy: item.assignedTo ?? sam, texts: texts, links: links,
            resources: made.resources, comments: comments, readAt: now
        )
    }

    private struct DemoDetails {
        var description: String?
        var isMarkdown = false
        var reproSteps: String?
        var systemInfo: String?
        var acceptanceCriteria: String?
        /// Newest first.
        var comments: [(author: Person, hoursAgo: Double, html: String)] = []
        var related: [Int] = []
        var resources: [WorkItemDetails.Resource] = []
        var size: Double?
        var priority: Int? = 2
        var severity: String?
        var estimate: Double?
        var completed: Double?
        var activity: String?
        var area = "Storefront\\Checkout"
        var tags: [String] = []
        var createdBy: Person?
        var createdDaysAgo: Double = 6
    }

    private static func demoDetails(_ id: Int) -> DemoDetails {
        switch id {
        case 5101:
            return DemoDetails(
                description: """
                    <div>As a shopper, I want to <b>save items for later</b> from my cart, so I can buy them another time without \
                    looking for them again.</div><div><br></div><div>Saved items belong to the account, not the device:</div>\
                    <ul><li>They show under the cart, newest first</li><li>One click moves an item back to the cart</li>\
                    <li>An account keeps up to <b>50</b>; saving more drops the oldest</li></ul>\
                    <div>Design: <a href="https://www.figma.com/">Cart › Saved for later</a></div>
                    """,
                acceptanceCriteria: """
                    <ol><li>A signed-in shopper can save any item in the cart</li><li>Saved items are still there after signing \
                    in on another device</li><li>An item that's out of stock says so, and can't be moved back</li></ol>
                    """,
                comments: [
                    (me, 3, "<div>Only signed-in shoppers for now. Guests get a prompt to sign in when they try.</div>"),
                    (priya, 20, "<div>Do we keep saved items for guests too, or only for signed-in shoppers?</div>"),
                    (sam, 50, """
                        <div>The design is in Figma, under <i>Cart › Saved for later</i>. \
                        <a href="#" data-vss-mention="version:2.0,a001">@Robin Diaz</a> ping me if anything's unclear.</div>
                        """),
                ],
                size: 5, area: "Storefront\\Cart", tags: ["cart", "web"], createdBy: sam, createdDaysAgo: 9
            )
        case 5103:
            return DemoDetails(
                description: """
                    Show the **Saved for later** list under the cart's items.

                    - Reuse `CartItemRow`, without the quantity stepper
                    - Say *Nothing saved yet* when there's nothing
                    - [x] Read saved items from the cart service
                    - [ ] Move an item back with **Move to Cart**

                    Spacing is in the [design](https://www.figma.com/).
                    """,
                isMarkdown: true,
                comments: [(alex, 5, "<div>Use the cart's 48 pt thumbnails, so both lists line up.</div>")],
                estimate: 5, completed: 2, activity: "Development", area: "Storefront\\Cart", tags: ["web"], createdDaysAgo: 6
            )
        case 5110:
            return DemoDetails(
                reproSteps: """
                    <ol><li>Add a <b>$19.99</b> item to the cart</li><li>Apply the coupon <code>SAVE15</code></li>\
                    <li>Look at the total</li></ol><div><b>Expected:</b> $16.99</div><div><b>Actual:</b> $16.98</div>
                    """,
                systemInfo: "<div>Storefront web 3.42.0 · Safari 26 · macOS 26.1</div>",
                comments: [
                    (me, 2, "<div>I'll round half up in the coupon service, and add tests for every currency.</div>"),
                    (priya, 26, """
                        <div>Only totals with half a cent are off: <code>CouponService.Apply</code> truncates instead of \
                        rounding.</div>
                        """),
                ],
                related: [5120],
                resources: [WorkItemDetails.Resource(
                    kind: .attachment, name: "coupon-total.png",
                    url: URL(string: "https://dev.azure.com/contoso/Storefront/_apis/wit/attachments/0a1b2c3d?fileName=coupon-total.png")!
                )],
                size: 3, priority: 1, severity: "2 - High", tags: ["coupons"], createdBy: priya, createdDaysAgo: 4
            )
        case 5112:
            return DemoDetails(
                description: """
                    <div>Round discounted totals <b>half up</b> to the cent, as finance asked, instead of truncating them.</div>\
                    <pre>var total = Math.Round(amount, 2, MidpointRounding.AwayFromZero);</pre>
                    """,
                estimate: 3, completed: 1, activity: "Development", tags: ["coupons"], createdDaysAgo: 3
            )
        case 5120:
            return DemoDetails(
                description: "<div>Shoppers can pay with a gift card, on its own or with a card for the rest.</div>",
                acceptanceCriteria: """
                    <div>What the shopper's card is charged:</div><table><tr><th>Gift card balance</th><th>Order total</th>\
                    <th>Charged to the card</th></tr><tr><td>$50.00</td><td>$30.00</td><td>$0.00</td></tr><tr><td>$20.00</td>\
                    <td>$30.00</td><td>$10.00</td></tr></table>
                    """,
                comments: [(maria, 30, "<div>The field's design is done: it goes under the payment methods.</div>")],
                size: 8, area: "Storefront\\Payments", tags: ["payments"], createdBy: alex, createdDaysAgo: 12
            )
        case 5150:
            return DemoDetails(
                description: "<div>Walk through saving for later and paying with a gift card, on staging.</div>",
                estimate: 1, activity: "Documentation", createdDaysAgo: 2
            )
        default:
            return DemoDetails()
        }
    }
}
