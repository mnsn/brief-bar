import AppKit
import SwiftUI
import Testing
@testable import AzureDevOpsUI

@MainActor
@Suite struct FlowLayoutTests {
    private static let sentence = "A sentence long enough to wrap onto several lines in a column this narrow"

    private func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    /// What it narrows to the line wraps there, as bigger text makes it do: it's as tall as its lines, rather than one.
    @Test func anItemItNarrowsIsAsTallAsItWraps() {
        let line = height(Text("One line").font(.system(size: 12)))
        let wrapped = height(Text(Self.sentence).font(.system(size: 12)).frame(width: 120))
        #expect(wrapped > line * 2)
        let flowed = height(FlowLayout { Text(Self.sentence) }.font(.system(size: 12)).frame(width: 120))
        #expect(abs(flowed - wrapped) < 1)
    }

    /// What follows it starts under its last line, rather than over the lines it wrapped to.
    @Test func whatFollowsANarrowedItemStartsUnderIt() {
        let line = height(Text("After").font(.system(size: 12)))
        let wrapped = height(Text(Self.sentence).font(.system(size: 12)).frame(width: 120))
        let flowed = height(
            FlowLayout(spacing: 6, lineSpacing: 4) {
                Text(Self.sentence)
                Text("After")
            }
            .font(.system(size: 12))
            .frame(width: 120)
        )
        #expect(abs(flowed - (wrapped + 4 + line)) < 1)
    }
}
