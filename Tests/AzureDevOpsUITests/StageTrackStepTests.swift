import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// A step of the details' stage track: Waits, which says what it waits for, wraps where the track is narrow, rather than
/// running past the details; the other steps keep to one line.
@MainActor
@Suite struct StageTrackStepTests {
    private static let waits = "After !4102 · stacked, !4103 · stacked and !4104, which its order puts first"

    private func size(_ view: some View) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    @Test func waitsWrapsWhereTheTrackIsNarrow() {
        let line = size(StageTrackStep(stage: .waits, title: "After !4102", place: .current))
        #expect(size(StageTrackStep(stage: .waits, title: Self.waits, place: .current)).width > 200)
        let narrow = size(
            FlowLayout(spacing: 4, lineSpacing: 5) {
                StageTrackStep(stage: .waits, title: Self.waits, place: .current)
            }
            .frame(width: 200)
        )
        #expect(narrow.height > line.height * 1.5)
    }

    @Test func theOtherStepsKeepToOneLine() {
        let line = size(StageTrackStep(stage: .teammateReview, title: "Teammate's review", place: .later))
        let narrow = size(
            FlowLayout(spacing: 4, lineSpacing: 5) {
                StageTrackStep(stage: .teammateReview, title: "Teammate's review", place: .later)
            }
            .frame(width: 60)
        )
        #expect(abs(narrow.height - line.height) < 0.5)
    }
}
