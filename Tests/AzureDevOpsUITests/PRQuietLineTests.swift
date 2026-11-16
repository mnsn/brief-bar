import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// A pull request's row in four parts at most: its last, quiet line is one line high while its stage fits, says what's
/// left but never what's done, and shows where its order puts it: on every stage on the Pull Requests page, and where its
/// stage's words said it in the menu bar's lists and the Overview.
@MainActor
@Suite struct PRQuietLineTests {
    private static let now = Date(timeIntervalSince1970: 1_792_000_000)
    private static let ref = ItemRef.pullRequest(organization: "contoso", number: 4102)
    private static let services = AppServices(defaults: MemoryDefaults(), isDemo: false)
    private static let settings = AppSettings(defaults: MemoryDefaults())
    private static let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
    private static let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
    private static let sessions = PullRequestSessions(copilot: copilot, links: services.links)
    private static let details = PullRequestDetailsStore()
    private static let left: [PRReadiness.Item] = [
        .init(kind: .comments, state: .needsYou, label: "Resolve 2 comments"),
        .init(kind: .approvals, state: nil, label: "1 of 2 approvals"),
        .init(kind: .requiredReviewers, state: nil, label: "Waiting on Sam"),
    ]
    private static let done: [PRReadiness.Item] = [
        .init(kind: .builds, state: .done, label: "Build passed"),
        .init(kind: .workItems, state: .done, label: "Work item linked"),
    ]

    /// One of yours, with what's left and what's done.
    private static func item(_ number: Int = 4102, readiness: [PRReadiness.Item]) throws -> PRSnapshot {
        let pullRequest = PullRequest(
            key: PRKey("contoso", number), title: "Add retry with backoff to the payments client", author: DemoData.me,
            createdAt: now.addingTimeInterval(-86_400), projectId: "7A0C4E1D", projectName: "Storefront",
            repositoryId: "Repository-Shop", repositoryName: "payments-api", sourceBranch: "robin/retry", targetBranch: "main"
        )
        var item = try #require(PRClassifier.snapshot(
            for: PRRecord(pullRequest: pullRequest, role: .author, me: DemoData.me.id), seenCutoff: .distantPast,
            dismissedCutoff: .distantPast, now: now
        ))
        item.readiness = PRReadiness(items: readiness)
        return item
    }

    private static func ordering() -> PullRequestOrder {
        PullRequestOrder(defaults: MemoryDefaults(), isDemo: false, now: { now })
    }

    /// Pull Request Order on, with !4101, !4102 and !4103 of yours in one order, each after the one before, the first two
    /// ready to complete: so !4101 can merge, !4102 waits for it, and !4103 waits for a reviewer, in Teammate's review.
    private static func inOneOrder() throws -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let numbers = [4101, 4102, 4103]
        var orders = DeclaredOrders()
        try orders.apply(
            OrderRequest(entries: numbers.enumerated().map { place, number in
                OrderRequest.Entry(
                    link: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)",
                    after: place == 0 ? [] : ["\(numbers[place - 1])"]
                )
            }),
            now: now.addingTimeInterval(-600), newID: UUID()
        )
        orders.save(to: defaults)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { now })
        order.publish(
            .azureDevOps,
            pullRequests: numbers.map { number in
                OrderPullRequest(
                    ref: .pullRequest(organization: "contoso", number: number), repository: "contoso/7d3f9a12/shop-web",
                    sourceBranch: "robin/\(number)", targetBranch: "main", author: "robin",
                    createdAt: now.addingTimeInterval(-86_400 + Double(number))
                )
            },
            stages: [
                .pullRequest(organization: "contoso", number: 4101): StageFacts(role: .author, isReady: true, votes: "0", commit: "c4101"),
                .pullRequest(organization: "contoso", number: 4102): StageFacts(role: .author, isReady: true, votes: "0", commit: "c4102"),
                .pullRequest(organization: "contoso", number: 4103): StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "0"),
            ],
            account: "robin@contoso.com"
        )
        return order
    }

    private func size(_ view: some View, width: CGFloat? = nil, ordering: PullRequestOrder? = nil) -> CGSize {
        let hosted = view
            .frame(width: width)
            .environmentObject(Self.services)
            .environmentObject(Self.copilot)
            .environmentObject(Self.store)
            .environmentObject(Self.sessions)
            .environmentObject(Self.settings)
            .environmentObject(Self.details)
            .environmentObject(ordering ?? Self.ordering())
        return NSHostingView(rootView: hosted).fittingSize
    }

    /// Proposes its view so wide a room, or none for as wide as it would be, and is as big as its view says it is then,
    /// even wider than the room.
    private struct Proposing: Layout {
        let width: CGFloat?

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: nil))
        }
    }

    /// How big a view says it is in so wide a room, rather than the room's width.
    private func ownSize(_ view: some View, width: CGFloat? = nil, ordering: PullRequestOrder? = nil) -> CGSize {
        size(Proposing(width: width) { view }, ordering: ordering)
    }

    /// In the menu bar's lists, the Overview and lists by state (`PullRequestRow`), a Can merge or Waits row shows where its
    /// order puts it, which its stage's words said before they went to its pill's menu, as the Pull Requests page does, so
    /// that it's as wide as its pill and its order's capsule side by side; another stage's row there shows none. Each row's
    /// title and reason are short here, so that its quiet line is its widest part.
    @Test func aListsRowSaysWhereItsOrderPutsItWhereItsStageSaidIt() throws {
        let ordering = try Self.inOneOrder()
        for (number, stage, shows) in [(4101, PullRequestStage.canMerge, true), (4102, .waits, true), (4103, .teammateReview, false)] {
            let ref = ItemRef.pullRequest(organization: "contoso", number: number)
            let reading = try #require(ordering.stage(of: ref))
            #expect(reading.stage == stage, "!\(number)")
            let order = try #require(OrderRowContext.of(ref, in: ordering.missions, isReady: false, names: ordering.names))
            var item = try Self.item(number, readiness: [])
            (item.title, item.headline, item.repository) = ("Fix", "Ready", "web")

            let pill = ownSize(PRQuietLine(item: item, stage: reading, ordering: ordering, left: [])).width
            let capsule = ownSize(PRQuietLine(item: item, order: order, left: [])).width
            let row = ownSize(PullRequestRow(item: item), ordering: ordering).width
            #expect((row >= pill + 6 + capsule) == shows, "!\(number): \(row) wide, its pill \(pill), its capsule \(capsule)")
        }
    }

    /// Where its stage's pill and its order's capsule each fit, but not side by side, the line goes on more lines, as its
    /// stage's line wrapped before, rather than past the row's edge.
    @Test func itWrapsRatherThanRunPastTheRow() throws {
        let item = try Self.item(readiness: Self.left)
        let other = ItemRef.pullRequest(organization: "contoso", number: 4103)
        let order = OrderRowContext(step: OrderStep(ref: Self.ref, status: .open, standing: .waiting(open: [other], unknown: [])), isReady: true)
        let stage = StageReading(stage: .waits, why: .waitsFor([other], words: "After !4103"))
        let pill = ownSize(PRQuietLine(item: item, stage: stage, ordering: Self.ordering(), left: []))
        let capsule = ownSize(PRQuietLine(item: item, order: order, left: []))
        let width = max(pill.width, capsule.width) + 10
        #expect(width < pill.width + 6 + capsule.width)

        let line = ownSize(PRQuietLine(item: item, stage: stage, ordering: Self.ordering(), order: order, left: Self.left), width: width)
        #expect(line.width < width + 0.5)
        #expect(line.height > pill.height + 2)

        // Where even its pill alone doesn't fit, it says how wide it is, rather than as wide as the room, so that what
        // follows it on the row goes under it rather than over it.
        let alone = ownSize(PRQuietLine(item: item, stage: stage, ordering: Self.ordering(), left: []), width: pill.width - 20)
        #expect(alone.width > pill.width - 0.5)
    }

    /// In a narrow row, its quiet line keeps to one line: what's left that doesn't fit folds into "+2", rather than
    /// wrapping as the readiness line did.
    @Test func itKeepsToOneLineInANarrowRow() throws {
        let item = try Self.item(readiness: Self.left)
        let stage = StageReading(stage: .yourReview, why: .awaitsYourReview)
        let line = PRQuietLine(item: item, stage: stage, ordering: Self.ordering(), left: Self.left)
        #expect(size(line, width: 2_000).height > 10)
        #expect(abs(size(line, width: 180).height - size(line, width: 2_000).height) < 0.5)
    }

    /// What's done stays in the details: a row with done items as well as what's left is no taller and no wider than one
    /// with only what's left.
    @Test func whatsDoneStaysInTheDetails() throws {
        let leftOnly = try Self.item(readiness: Self.left)
        let withDone = try Self.item(readiness: Self.left + Self.done)
        let row = { (item: PRSnapshot) in PRRowView(item: item, now: Self.now) {} }
        #expect(size(row(withDone), width: 2_000) == size(row(leftOnly), width: 2_000))
        let doneOnly = try Self.item(readiness: Self.done)
        let nothing = try Self.item(readiness: [])
        #expect(size(row(doneOnly), width: 2_000) == size(row(nothing), width: 2_000))
    }

    /// What its reason says already isn't said again: a pull request whose reason is its merge conflicts is as wide as one
    /// with what else is left alone.
    @Test func itDoesntRepeatItsReason() throws {
        let conflicts = PRReadiness.Item(kind: .conflicts, state: .failing, label: "Merge conflicts")
        var repeated = try Self.item(readiness: [conflicts] + Self.left)
        repeated.headline = "Merge conflicts"
        var rest = try Self.item(readiness: Self.left)
        rest.headline = "Merge conflicts"
        let row = { (item: PRSnapshot) in PRRowView(item: item, now: Self.now) {} }
        #expect(size(row(repeated)) == size(row(rest)))
    }

    /// Why it's in its stage is in its pill's menu, not on the row, so where its order puts it shows on every stage, Can
    /// merge and Waits too, whose words used to say it.
    @Test func itsOrderShowsOnEveryStage() throws {
        let item = try Self.item(readiness: [])
        let other = ItemRef.pullRequest(organization: "contoso", number: 4103)
        let order = OrderRowContext(step: OrderStep(ref: Self.ref, status: .open, standing: .waiting(open: [other], unknown: [])), isReady: true)
        for stage in [StageReading(stage: .canMerge, why: .ready(autoComplete: false)),
                      StageReading(stage: .waits, why: .waitsFor([other], words: "After !4103")),
                      StageReading(stage: .teammateReview, why: .findReviewer)] {
            let with = PRQuietLine(item: item, stage: stage, ordering: Self.ordering(), order: order, left: [])
            let without = PRQuietLine(item: item, stage: stage, ordering: Self.ordering(), left: [])
            #expect(size(with).width > size(without).width + 10, "\(stage.stage)")
        }
    }
}
