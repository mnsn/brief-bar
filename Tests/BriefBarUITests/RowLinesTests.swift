import AppKit
import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

/// What a row says under its title (`RowLines`), and its buttons in its time's place or column (`RowTimeSlot`,
/// `rowActions`).
@MainActor
struct RowLinesTests {
    private func size(_ view: some View, width: CGFloat? = nil) -> CGSize {
        NSHostingView(rootView: view.frame(width: width)).fittingSize
    }

    private func block(_ width: CGFloat, _ height: CGFloat) -> some View {
        Color.clear.frame(width: width, height: height)
    }

    /// A reason 100 wide, then where, then capsules 50 wide and 16 high: on its reason's line wherever where it is can keep
    /// a few letters, it cut short first; and only where it can't, at the end of its quiet line, a line of their own here.
    @Test func capsulesStayAfterTheReasonWhereItIsCutShortFirst() {
        let lines = RowLines {
            block(100, 14).rowLine(.reason)
            Text(" · payments-api").font(.system(size: 11, weight: .medium)).lineLimit(1).rowLine(.place)
            block(50, 16).rowLine(.chips)
        }
        let place = size(Text(" · payments-api").font(.system(size: 11, weight: .medium)).lineLimit(1))
        let floor = place.height * RowLines.placeFloor
        #expect(size(lines, width: 1_000).height == 16)
        #expect(size(lines, width: 100 + floor + RowLines.spacing + 50 + 2).height == 16)
        #expect(size(lines, width: 100 + floor + RowLines.spacing + 50 - 10).height == max(14, place.height) + RowLines.quietSpacing + 16)
    }

    /// The quiet line's own things get the room its far end's and the capsules leave: here, a part that's taller where it
    /// has less than 200.
    @Test func whatsAtTheQuietLinesEndTakesItsRoomFromIt() {
        func lines(trailing: Bool) -> some View {
            RowLines {
                block(100, 14).rowLine(.reason)
                ViewThatFits(in: .horizontal) {
                    block(200, 16)
                    block(50, 30)
                }
                .rowLine(.quiet)
                if trailing {
                    block(100, 16).rowLine(.trailing)
                }
            }
        }
        let quietLine = 14 + RowLines.quietSpacing
        #expect(size(lines(trailing: false), width: 250).height == quietLine + 16)
        #expect(size(lines(trailing: true), width: 250).height == quietLine + 30)
        #expect(size(lines(trailing: true), width: 200 + RowLines.trailingSpacing + 100).height == quietLine + 16)
    }

    /// The time makes room for ✨, and in a list of the menu bar for the ⋯ after it, only while you're at the row.
    @Test func theTimeMakesRoomForItsButtonsOnlyWhileYouReAtTheRow() {
        func width(summarizes: Bool = false, isActive: Bool, actionsHere: Bool = false) -> CGFloat {
            size(RowTimeSlot("12m", summarizes: summarizes, isActive: isActive).environment(\.rowActionsInTimesPlace, actionsHere)).width
        }
        let time = width(isActive: false)
        let side = RowTimeSlot.buttonSide
        #expect(width(isActive: false, actionsHere: true) == time)
        #expect(width(isActive: true) == time)
        #expect(width(summarizes: true, isActive: true) == max(time, side))
        #expect(width(isActive: true, actionsHere: true) == max(time, side))
        #expect(width(summarizes: true, isActive: true, actionsHere: true) == max(time, 2 * side + RowTimeSlot.buttonSpacing))
    }

    private struct ActionsProbe: View {
        let activity = RowActivity()

        var body: some View {
            Color.clear.frame(width: 100, height: 20)
                .rowActions(for: "A row", openTitle: "Open", open: {}, activity: activity) { EmptyView() }
        }
    }

    /// On a window's page, a row keeps a column for its ⋯, so that nothing moves as it shows; in a list of the menu bar it
    /// takes the time's place instead, and a widget's row has none, but with Visible Row and Widget Actions.
    @Test func onlyAWindowsPageKeepsAColumnForTheRowsActions() {
        let page = size(ActionsProbe().environment(\.panelStyle, .page)).width
        let menuBar = size(ActionsProbe().environment(\.panelStyle, .popover(width: nil))).width
        let widget = size(ActionsProbe().environment(\.offersRowActions, false)).width
        let visible = size(ActionsProbe().environment(\.offersRowActions, false)
            .environment(\.interfaceOptions, InterfaceOptions(enabled: [.visibleActions]))).width
        #expect(page > 100 + RowTimeSlot.buttonSide - 0.5)
        #expect(menuBar == 100)
        #expect(widget == 100)
        #expect(visible > 100 + 28 - 0.5)
    }
}

/// A row's buttons show while it has the keyboard's focus, as Tab gives it, and go with it: here a row that takes Tab
/// whatever the Mac's keyboard navigation, as a row's button does with it on, in a list of the menu bar, before something
/// else that takes it too.
@MainActor
@Suite(.serialized, .keepsTheMainRunLoopRunning) struct RowFocusTests {
    private final class KeyWindow: TestWindow {
        override var isKeyWindow: Bool { true }
    }

    /// What the row last drew: its focus, and how wide its time's place is.
    private final class Seen {
        var focus: RowFocus?
        var isActive = false
        var timeWidth: CGFloat = 0
    }

    private struct FocusableRow: View {
        let seen: Seen
        let activity = RowActivity()

        var body: some View {
            let _ = seen.focus = activity.focus
            let _ = seen.isActive = activity.isActive
            HStack {
                Text("A row")
                Spacer()
                RowTimeSlot("1m", summarizes: false, isActive: activity.isActive)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { seen.timeWidth = $0 }
            }
            .frame(width: 300, height: 30)
            .focusable(interactions: .edit)
            .rowFocus(activity, .row)
            .rowActions(for: "A row", openTitle: "Open", open: {}, activity: activity) { EmptyView() }
        }
    }

    @Test func tabsFocusPutsTheRowsActionsInItsTimesPlaceUntilItMovesOn() async throws {
        _ = NSApplication.shared
        let seen = Seen()
        let page = VStack {
            FocusableRow(seen: seen)
            Color.clear.frame(width: 300, height: 30).focusable(interactions: .edit)
        }
        let host = NSHostingView(rootView: page.environment(\.panelStyle, .popover(width: nil)))
        let window = KeyWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 120), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        defer {
            window.contentView = nil
            window.close()
        }
        func settled(_ what: String, _ condition: @escaping () -> Bool) async throws {
            try await until(what) {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return condition()
            }
        }
        /// Tab, until the row's focus is as wanted.
        func tab(until hasFocus: Bool, _ what: String) async throws {
            for _ in 0..<4 where seen.isActive != hasFocus {
                window.selectNextKeyView(nil)
                try await Task.sleep(for: .milliseconds(50))
            }
            try await settled(what) { seen.isActive == hasFocus }
        }

        try await settled("the row") { seen.timeWidth > 0 }
        try await tab(until: false, "Tab's focus on what follows the row")
        try await settled("its time, as it is") { seen.timeWidth < RowTimeSlot.buttonSide }
        let time = seen.timeWidth

        try await tab(until: true, "Tab's focus on the row again")
        #expect(seen.focus == .row)
        try await settled("its ⋯ in its time's place") { seen.timeWidth >= RowTimeSlot.buttonSide }

        try await tab(until: false, "Tab's focus on what follows the row once more")
        try await settled("its time back") { seen.timeWidth == time }
    }
}
