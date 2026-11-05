import AppKit
import BriefBarUI
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// A header's action, such as the Comments' Fix All: at the end of its title's line while both fit, and under the title
/// otherwise, rather than squeezing it.
@MainActor
@Suite struct ActionBesideOrUnderTests {
    private func size(_ view: some View) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    /// Within half a point, as a hosting view's fitting size rounds.
    private func about(_ value: CGFloat, _ expected: CGFloat) -> Bool {
        abs(value - expected) < 0.5
    }

    private func header(width: CGFloat) -> some View {
        ActionBesideOrUnder(gap: 16, lineSpacing: 8) {
            Color.clear.frame(width: 100, height: 20)
            Color.clear.frame(width: 80, height: 24)
        }
        .frame(width: width)
    }

    @Test func anActionWithRoomStaysOnItsTitlesLine() {
        #expect(about(size(header(width: 196)).height, 24))
        #expect(about(size(header(width: 400)).height, 24))
    }

    @Test func anActionWithoutRoomGoesUnderItsTitle() {
        #expect(about(size(header(width: 195)).height, 20 + 8 + 24))
    }

    /// A title that fits on its own keeps to one line as its action goes under it, where beside it, it'd break.
    @Test func aTitleThatFitsAloneDoesntBreak() {
        let title = Text("Comments").font(.system(size: 20, weight: .semibold))
        let line = size(title.fixedSize())
        let squeezed = size(
            HStack(spacing: 16) {
                title
                Color.clear.frame(width: 120, height: 24)
            }
            .frame(width: line.width + 40)
        )
        #expect(squeezed.height > line.height * 1.5)
        let header = size(
            ActionBesideOrUnder(gap: 16, lineSpacing: 8) {
                title
                Color.clear.frame(width: 120, height: 24)
            }
            .frame(width: line.width + 40)
        )
        #expect(about(header.height, line.height + 8 + 24))
    }

    /// With no action, as while its composer is open, the title takes the line alone.
    @Test func aTitleWithoutAnActionTakesTheLine() {
        let header = size(ActionBesideOrUnder { Color.clear.frame(width: 100, height: 20) }.frame(width: 300))
        #expect(about(header.width, 300) && about(header.height, 20))
    }

    /// On one line, the Comments' title, Active | All and Fix All take the room the row they were in took, at each text
    /// size: lined up on their text, as before.
    @Test(arguments: [1.0, 1.5]) func onOneLineItIsAsTallAsTheRowItReplaced(scale: CGFloat) {
        let title = HStack(alignment: .firstTextBaseline, spacing: 8) {
            PageSectionHeader(title: "Comments", count: 2)
            SegmentedPicker("Comments Shown", selection: .constant(0), segments: [.init(0, title: "Active"), .init(1, title: "All")])
                .controlSize(.small)
                .fixedSize()
        }
        let action = Button {} label: { ControlLabel("Fix 1 Comment", systemImage: "wrench.and.screwdriver") }
            .buttonStyle(.bordered)
            .controlSize(.small)
        let row = size(
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title
                Spacer(minLength: 8)
                action
            }
            .environment(\.textScale, scale)
            .frame(width: 700)
        )
        let header = size(ActionBesideOrUnder { title; action }.environment(\.textScale, scale).frame(width: 700))
        #expect(header.height == row.height)
    }
}
