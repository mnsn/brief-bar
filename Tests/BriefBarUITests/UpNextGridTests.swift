import AppKit
import SwiftUI
import Testing
@testable import BriefBarUI

/// Up Next's slots: the size their layout gives is one SwiftUI can use, whatever it's asked.
@MainActor
@Suite struct UpNextGridTests {
    /// What the layout answered when its parent asked for its largest size. SwiftUI lays out on the main thread alone.
    private final class Answer: @unchecked Sendable {
        var size: CGSize?
    }

    /// A parent that asks its child for its largest size, as a stack does to see how far it stretches, then lays it out in
    /// what it's offered.
    private struct AsksForTheLargest: Layout {
        let answer: Answer

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            answer.size = subviews.first?.sizeThatFits(.infinity)
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: proposal)
        }
    }

    /// Asked for its largest size, it's as wide as its slots side by side at their narrowest, as for its ideal size, never
    /// infinite.
    @Test func askedForItsLargestSizeItsAsWideAsItsSlotsSideBySide() throws {
        let answer = Answer()
        let host = NSHostingView(rootView: AsksForTheLargest(answer: answer) {
            UpNextGrid(minimum: 176, spacing: 10) {
                ForEach(0..<4, id: \.self) { index in
                    Text("Slot \(index)").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        })
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1_000, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()

        let size = try #require(answer.size)
        #expect(size.width == CGFloat(4 * 176 + 3 * 10))
        #expect(size.height.isFinite && size.height > 0)
    }
}
