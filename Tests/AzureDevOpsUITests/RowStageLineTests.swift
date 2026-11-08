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

    /// A failed build or conflicts after the reason, "Copilot is writing it · merge conflicts", wrap under the label where
    /// the row is narrow, so they show: the line takes one more line than the reason alone does there. Where the row is
    /// wide, both keep to one line.
    @Test func aSecondReasonWrapsRatherThanBeingCutOff() {
        let writing = StageWhy.working(StageSession(ref: Self.session, activity: .working, since: Self.now, name: "Copilot"))
        let alone = StageReading(stage: .inProgress, why: writing)
        let failing = StageReading(stage: .inProgress, why: writing, alsoFailing: "Merge conflicts")
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
}
