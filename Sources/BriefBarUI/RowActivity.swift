import SwiftUI

// A row's actions show when you need them: its ⋯ menu, ✨ Summarize and a button such as Finished My Review show while the
// pointer is over the row, or while the row or one of its buttons has keyboard focus, or VoiceOver's; always with Visible
// Row and Widget Actions on, but for ✨, whose Summarize is in the ⋯ menu then. On a window's page, the ⋯ keeps a column of
// its own, so that nothing moves as it shows; in a list of the menu bar, it takes the time's place, with ✨ before it, so
// that titles keep the row's whole width while you're elsewhere. Every action is in the row's right-click menu too, and a
// button's in VoiceOver's actions for the row.

/// What has keyboard or VoiceOver focus in a row: the row itself, or a button it shows while you're at it.
package enum RowFocus: Hashable, Sendable {
    case row
    /// Its stage's pill, a menu.
    case pill
    case finishedReview
    /// ✨ Summarize, in its time's place.
    case summarize
    /// Its ⋯ menu.
    case actions
    /// Another of its buttons, such as a session's ↳ tag.
    case control
}

private struct ShowsRowActionsKey: EnvironmentKey {
    static let defaultValue = false
}

private struct OffersRowActionsKey: EnvironmentKey {
    static let defaultValue = true
}

private struct RowActionsInTimesPlaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Rows show their actions as they do while you point at them: for a picture of one (`--render`).
    package var showsRowActions: Bool {
        get { self[ShowsRowActionsKey.self] }
        set { self[ShowsRowActionsKey.self] = newValue }
    }

    /// Whether rows show their ⋯ while you're at them: not in a desktop widget, whose rows keep their look, with a ⋯ only
    /// once you choose Visible Row and Widget Actions.
    package var offersRowActions: Bool {
        get { self[OffersRowActionsKey.self] }
        set { self[OffersRowActionsKey.self] = newValue }
    }

    /// The row's ⋯ takes its time's place while you're at it, as in a list of the menu bar (`rowActions`).
    var rowActionsInTimesPlace: Bool {
        get { self[RowActionsInTimesPlaceKey.self] }
        set { self[RowActionsInTimesPlaceKey.self] = newValue }
    }
}

/// Whether a row is in use: under the pointer, or with focus on it or on one of its controls.
package struct RowActivity: DynamicProperty {
    @LocalState package var isHovered = false
    @FocusState package var focus: RowFocus?
    @AccessibilityFocusState package var voiceOverFocus: RowFocus?
    @Environment(\.showsRowActions) private var showsActions

    package init() {}

    /// Its actions show.
    package var isActive: Bool {
        isPointedAt || focus != nil || voiceOverFocus != nil
    }

    /// It looks as it does under the pointer: highlighted.
    package var isPointedAt: Bool { isHovered || showsActions }
}

extension View {
    /// Marks one of a row's buttons for its focus: while it has it, keyboard's or VoiceOver's, the row's buttons show.
    package func rowFocus(_ activity: RowActivity?, _ part: RowFocus) -> some View {
        modifier(RowFocusModifier(activity: activity, part: part, keyboard: true, voiceOver: true))
    }

    /// A row's own button's keyboard focus, where the row is one accessibility element made of it: on the button, before
    /// `accessibilityElement(children:)`, with `rowVoiceOverFocus` on the element after it.
    package func rowKeyboardFocus(_ activity: RowActivity?) -> some View {
        modifier(RowFocusModifier(activity: activity, part: .row, keyboard: true, voiceOver: false))
    }

    /// VoiceOver's focus on a row that's one accessibility element: after `accessibilityElement(children:)`, on the element
    /// VoiceOver goes to.
    package func rowVoiceOverFocus(_ activity: RowActivity?) -> some View {
        modifier(RowFocusModifier(activity: activity, part: .row, keyboard: false, voiceOver: true))
    }
}

private struct RowFocusModifier: ViewModifier {
    let activity: RowActivity?
    let part: RowFocus
    let keyboard: Bool
    let voiceOver: Bool

    func body(content: Content) -> some View {
        if let activity, keyboard, voiceOver {
            content
                .focused(activity.$focus, equals: part)
                .accessibilityFocused(activity.$voiceOverFocus, equals: part)
        } else if let activity, keyboard {
            content.focused(activity.$focus, equals: part)
        } else if let activity, voiceOver {
            content.accessibilityFocused(activity.$voiceOverFocus, equals: part)
        } else {
            content
        }
    }
}

// MARK: The time's place

/// A row's time, "41m", whose place its buttons take while you're at the row: ✨ where it offers Summarize, and, in a list
/// of the menu bar, its ⋯ after it. It makes room for them then, so they cover nothing; at rest, it's as wide as its words.
package struct RowTimeSlot: View {
    private let text: String
    private let summarizes: Bool
    private let isActive: Bool

    @Environment(\.rowActionsInTimesPlace) private var actionsHere
    @Environment(\.textScale) private var textScale

    /// How big each button in the time's place is, before the text size, and the room between them.
    package static let buttonSide: CGFloat = 22
    package static let buttonSpacing: CGFloat = 2

    /// - Parameters:
    ///   - summarizes: ✨, or a spinner while a summary is written, takes its place.
    ///   - isActive: you're at the row: the pointer's over it, or it or one of its buttons has focus (`RowActivity`).
    package init(_ text: String, summarizes: Bool, isActive: Bool) {
        self.text = text
        self.summarizes = summarizes
        self.isActive = isActive
    }

    package var body: some View {
        let actions = actionsHere && isActive
        let buttons = (summarizes ? 1 : 0) + (actions ? 1 : 0)
        let side = Self.buttonSide * textScale
        Text(text)
            .font(size: 11).monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .opacity(buttons > 0 ? 0 : 1)
            .frame(minWidth: buttons == 0 ? 0 : CGFloat(buttons) * side + CGFloat(buttons - 1) * Self.buttonSpacing, alignment: .trailing)
            .anchorPreference(key: RowTimeSpot.self, value: .bounds) {
                buttons > 0 ? RowTimeSpot.Spot(bounds: $0, summarizes: summarizes, actions: actions) : nil
            }
    }
}

/// Where a row's time is, while its buttons take its place.
package struct RowTimeSpot: PreferenceKey {
    package struct Spot {
        let bounds: Anchor<CGRect>
        /// ✨ is there, before the ⋯ where that's there too.
        let summarizes: Bool
        /// The row's ⋯ is there, at its end.
        let actions: Bool
    }

    package static var defaultValue: Spot? { nil }

    package static func reduce(value: inout Spot?, nextValue: () -> Spot?) {
        value = value ?? nextValue()
    }
}

/// Which of the time's place's buttons a view is.
enum RowTimeButton {
    case summarize, actions
}

extension View {
    /// Puts a row's ✨, or a spinner while its summary is written, where the row's time is, while the time gives it its place
    /// (`RowTimeSlot`): over a row that's a button, which would take its click.
    package func rowTimeSummarizeButton<Button: View>(@ViewBuilder _ button: @escaping () -> Button) -> some View {
        overlayPreferenceValue(RowTimeSpot.self) { spot in
            if let spot, spot.summarizes {
                RowTimeButtonPlace(spot: spot, button: .summarize, content: button)
            }
        }
    }

    /// Puts a row's ⋯ at its time's end, while it's there (`RowTimeSlot`).
    func rowTimeActionsButton<Button: View>(@ViewBuilder _ button: @escaping () -> Button) -> some View {
        overlayPreferenceValue(RowTimeSpot.self) { spot in
            if let spot, spot.actions {
                RowTimeButtonPlace(spot: spot, button: .actions, content: button)
            }
        }
    }
}

/// A button in a row's time's place: the ⋯ at its end, ✨ before it.
private struct RowTimeButtonPlace<Content: View>: View {
    let spot: RowTimeSpot.Spot
    let button: RowTimeButton
    @ViewBuilder let content: () -> Content

    @Environment(\.textScale) private var textScale

    var body: some View {
        let side = RowTimeSlot.buttonSide * textScale
        GeometryReader { proxy in
            let frame = proxy[spot.bounds]
            let before = button == .summarize && spot.actions ? side + RowTimeSlot.buttonSpacing : 0
            content()
                .frame(width: side, height: side)
                .position(x: frame.maxX - side / 2 - before, y: frame.midY)
        }
    }
}

/// Shows while its row is in use, and keeps its place while it doesn't: a row's ⋯ in its column on a window's page.
package struct RowActionVisibility: ViewModifier {
    let isShown: Bool

    package init(isShown: Bool) {
        self.isShown = isShown
    }

    package func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isShown)
    }
}
