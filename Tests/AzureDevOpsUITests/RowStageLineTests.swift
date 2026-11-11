import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// A row's stage line: why, and who set it, wrap where they're longer than the row is wide, rather than being cut off.
@MainActor
@Suite struct RowStageLineTests {
    private static let now = Date(timeIntervalSince1970: 1_792_000_000)
    private static let session = ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b")!

    /// How tall the line is at this width.
    private func height(_ reading: StageReading, width: CGFloat) -> CGFloat {
        let ordering = PullRequestOrder(defaults: MemoryDefaults(), isDemo: false, now: { Self.now })
        let line = RowStageLine(stage: reading, order: nil, ordering: ordering, now: Self.now).frame(width: width)
        return NSHostingView(rootView: line).fittingSize.height
    }

    /// How wide the line is with room to spare, on one line.
    private func width(_ reading: StageReading, order: OrderRowContext?) -> CGFloat {
        let ordering = PullRequestOrder(defaults: MemoryDefaults(), isDemo: false, now: { Self.now })
        return NSHostingView(rootView: RowStageLine(stage: reading, order: order, ordering: ordering, now: Self.now)).fittingSize.width
    }

    /// A failed build or conflicts after the reason, "Copilot is writing it · merge conflicts", wrap under the label where
    /// the row is narrow, so they show: the line takes one more line than the reason alone does there. Where the row is
    /// wide, both keep to one line.
    @Test func aSecondReasonWrapsRatherThanBeingCutOff() {
        let writing = StageWhy.working(StageSession(ref: Self.session, activity: .working, since: Self.now, name: "Copilot"))
        let alone = StageReading(stage: .inProgress, why: writing)
        let failing = StageReading(stage: .inProgress, why: writing, flags: [.failing("Merge conflicts")])
        #expect(height(failing, width: 140) > height(alone, width: 140) + 4)
        #expect(abs(height(failing, width: 2_000) - height(alone, width: 2_000)) < 0.5)
    }

    /// Who set it wraps too, where it's longer than the row is wide: a session's, "after you".
    @Test func whoSetItWrapsRatherThanBeingCutOff() {
        let set = StageMark(stage: .inProgress, at: Self.now.addingTimeInterval(-300), by: Self.session)
        let yours = StageMark(stage: .yourReview, at: Self.now.addingTimeInterval(-3_600))
        let reading = StageReading(stage: .inProgress, why: .draft, mark: set, replaced: yours)
        #expect(StageText.who(reading, now: Self.now, name: { _ in nil }) == "A Copilot session set it 5m ago, after you")
        #expect(height(reading, width: 160) > height(reading, width: 280) + 4)
    }

    /// Can merge and Waits say where its order puts it, so their line has no capsule to say it again, as other stages' do.
    /// One with no order known shows its quiet ✎ on every stage: no stage says what a change of yours says of it, such as
    /// that you moved it there.
    @Test func aChangeOfYoursShowsOnEveryStageWhereItHasNoOrder() {
        let ref = ItemRef.pullRequest(organization: "contoso", number: 4130)
        let moved = OrderRowContext(
            step: OrderStep(ref: ref, status: .open, standing: .unordered, notes: [.moved(from: nil, Self.now)]), isReady: true
        )
        let next = OrderRowContext(step: OrderStep(ref: ref, status: .open, standing: .next), isReady: true)
        let canMerge = StageReading(stage: .canMerge, why: .ready(autoComplete: false))
        let teammates = StageReading(stage: .teammateReview, why: .findReviewer)
        #expect(width(canMerge, order: moved) > width(canMerge, order: nil) + 10)
        #expect(abs(width(canMerge, order: next) - width(canMerge, order: nil)) < 0.5)
        #expect(width(teammates, order: next) > width(teammates, order: nil) + 10)
        #expect(width(teammates, order: moved) > width(teammates, order: nil) + 10)
    }

    /// Where a change of yours speaks of one its order places, Can merge and Waits show its capsule too, as main's rows did:
    /// ✎ Next to merge for one you set as next, which "Complete it" doesn't say; and, for one an order put after another
    /// since, going against yours, the capsule whose tooltip and VoiceOver say so, with Put Yours Back in its menu. One
    /// whose order alone places it still has none.
    @Test func aChangeOfYoursShowsOnCanMergeAndWaitsWhereItHasAnOrder() {
        let ref = ItemRef.pullRequest(organization: "contoso", number: 4102)
        let other = ItemRef.pullRequest(organization: "contoso", number: 4103)
        let yours = OrderRowContext(
            step: OrderStep(ref: ref, status: .open, standing: .next, notes: [.yourNext(Self.now)], isYours: true, isChangedByYou: true),
            isReady: true
        )
        let override = OrderOverride(by: nil, at: Self.now, now: .after([other]), yours: .next)
        let overridden = OrderRowContext(
            step: OrderStep(ref: ref, status: .open, standing: .waiting(open: [other], unknown: []), notes: [.orderChangedIt(override)]),
            isReady: true
        )
        let theirs = OrderRowContext(step: OrderStep(ref: ref, status: .open, standing: .waiting(open: [other], unknown: [])), isReady: true)
        let canMerge = StageReading(stage: .canMerge, why: .ready(autoComplete: false))
        let waits = StageReading(stage: .waits, why: .waitsFor([other], words: "After !4103"))
        #expect(width(canMerge, order: yours) > width(canMerge, order: nil) + 10)
        #expect(width(waits, order: overridden) > width(waits, order: nil) + 10)
        #expect(abs(width(waits, order: theirs) - width(waits, order: nil)) < 0.5)
        #expect(overridden.sentence?.contains("after you'd set it as next") == true)
    }
}
