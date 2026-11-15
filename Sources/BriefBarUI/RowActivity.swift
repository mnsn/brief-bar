import SwiftUI

// A row's actions show when you need them: its ⋯ menu, and a button such as Finished My Review, show while the pointer is
// over the row, while the row or one of those controls has keyboard focus, or VoiceOver's; always with Visible Row and
// Widget Actions on. Hidden, the ⋯ keeps its place, so that nothing moves as it shows, and stays where Tab and VoiceOver
// reach it; every action is in the row's right-click menu too, and a button's in VoiceOver's actions for the row.

/// What has keyboard or VoiceOver focus in a row: the row itself, or a control it shows while you're at it.
package enum RowFocus: Hashable, Sendable {
    case row
    /// Its stage's pill, a menu.
    case pill
    case finishedReview
    /// Its ⋯ menu.
    case actions
}

private struct ShowsRowActionsKey: EnvironmentKey {
    static let defaultValue = false
}

private struct OffersRowActionsKey: EnvironmentKey {
    static let defaultValue = true
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
    /// Marks a row's control, or the row itself, for its focus: while it has it, keyboard's or VoiceOver's, the row's
    /// actions show.
    package func rowFocus(_ activity: RowActivity?, _ part: RowFocus) -> some View {
        modifier(RowFocusModifier(activity: activity, part: part))
    }
}

private struct RowFocusModifier: ViewModifier {
    let activity: RowActivity?
    let part: RowFocus

    func body(content: Content) -> some View {
        if let activity {
            content
                .focused(activity.$focus, equals: part)
                .accessibilityFocused(activity.$voiceOverFocus, equals: part)
        } else {
            content
        }
    }
}

/// Shows while its row is in use, and keeps its place while it doesn't: a row's ⋯.
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
