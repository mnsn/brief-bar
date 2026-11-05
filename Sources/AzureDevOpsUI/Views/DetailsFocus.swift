import SwiftUI

/// Where a pull request's details went last, as `PullRequestDetailsContent` takes them where they're asked to go, for
/// VoiceOver to follow them there each time: to what they point out, a thread, a file's row, a build or a check, or else
/// the header of one of their parts, of their Files, or their title (`focusesOnArrival`, `takesFocusOnArrival`). Each time
/// they go somewhere is another arrival, to the same place again too, as when a build is asked for again while it's still
/// pointed out (`arrived(at:since:)`). And whether they're on their way somewhere: their title doesn't take VoiceOver's
/// focus as it shows then, as it does otherwise.
struct DetailsArrival: Equatable {
    /// Where they went last; nil before they went anywhere.
    var anchor: PullRequestDetailsStore.Anchor?
    /// How many times they went somewhere: each time is another, to the same place again too.
    var count = 0
    /// They're asked to go somewhere, and haven't got there yet.
    var isGoing = false

    /// They went there.
    mutating func arrive(at anchor: PullRequestDetailsStore.Anchor) {
        self.anchor = anchor
        count += 1
    }

    /// Whether, from `old` to this, they went to `anchor`: each time they go there, though they went there last too and
    /// still point it out, for VoiceOver to go there again; not as they set out somewhere (`isGoing`).
    func arrived(at anchor: PullRequestDetailsStore.Anchor, since old: DetailsArrival) -> Bool {
        count != old.count && self.anchor == anchor
    }
}

private struct DetailsArrivalKey: EnvironmentKey {
    static var defaultValue: DetailsArrival { DetailsArrival() }
}

extension EnvironmentValues {
    /// Where the details around went last, and whether they're on their way somewhere (`DetailsArrival`).
    var detailsArrival: DetailsArrival {
        get { self[DetailsArrivalKey.self] }
        set { self[DetailsArrivalKey.self] = newValue }
    }
}

extension View {
    /// Takes VoiceOver's focus each time the details around go to `anchor`: a part's header, such as their Comments' as
    /// What's Left's Comments takes them there.
    func takesFocusOnArrival(at anchor: PullRequestDetailsStore.Anchor) -> some View {
        modifier(OwnArrivalFocus(anchor: anchor))
    }

    /// The same, for a view with VoiceOver's focus of its own, `isFocused`, as what the details point out has, such as a
    /// build's row: each time they go to it, though they went there a moment ago and it's still pointed out.
    func focusesOnArrival(at anchor: PullRequestDetailsStore.Anchor, _ isFocused: AccessibilityFocusState<Bool>.Binding) -> some View {
        modifier(ArrivalFocus(anchor: anchor, isFocused: isFocused))
    }
}

private struct OwnArrivalFocus: ViewModifier {
    let anchor: PullRequestDetailsStore.Anchor

    @AccessibilityFocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityFocused($isFocused)
            .focusesOnArrival(at: anchor, $isFocused)
    }
}

private struct ArrivalFocus: ViewModifier {
    let anchor: PullRequestDetailsStore.Anchor
    let isFocused: AccessibilityFocusState<Bool>.Binding

    @Environment(\.detailsArrival) private var arrival

    func body(content: Content) -> some View {
        content
            .onChange(of: arrival) { old, new in
                if new.arrived(at: anchor, since: old) { isFocused.wrappedValue = true }
            }
    }
}
