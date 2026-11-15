import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// A pull request's row in four parts at most: its last, quiet line is one line high, says what's left but never what's
/// done, and shows where its order puts it on every stage.
@MainActor
@Suite struct PRQuietLineTests {
    private static let now = Date(timeIntervalSince1970: 1_792_000_000)
    private static let ref = ItemRef.pullRequest(organization: "contoso", number: 4102)
    private static let services = AppServices(defaults: MemoryDefaults(), isDemo: false)
    private static let settings = AppSettings(defaults: MemoryDefaults())
    private static let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
    private static let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
    private static let sessions = PullRequestSessions(copilot: copilot, links: services.links)
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
    private static func item(readiness: [PRReadiness.Item]) throws -> PRSnapshot {
        let pullRequest = PullRequest(
            key: PRKey("contoso", 4102), title: "Add retry with backoff to the payments client", author: DemoData.me,
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

    private func size(_ view: some View, width: CGFloat? = nil) -> CGSize {
        let hosted = view
            .frame(width: width)
            .environmentObject(Self.services)
            .environmentObject(Self.copilot)
            .environmentObject(Self.store)
            .environmentObject(Self.sessions)
        return NSHostingView(rootView: hosted).fittingSize
    }

    /// However narrow the row, its quiet line keeps to one line: what's left that doesn't fit folds into "+2", rather than
    /// wrapping as the readiness line did.
    @Test func itKeepsToOneLineHoweverNarrow() throws {
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
