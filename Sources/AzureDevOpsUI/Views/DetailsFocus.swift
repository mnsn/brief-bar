import SwiftUI

/// Where a pull request's details went last, as `PullRequestDetailsContent` takes them where they're asked to go, for
/// VoiceOver to follow them there: the header of one of their parts, of their Files, or their title, which takes its focus
/// as they get there (`takesFocusOnArrival`), as a thread, a file's row, a build or a check does as it's pointed out. And
/// whether they're on their way somewhere: their title doesn't take VoiceOver's focus as it shows then, as it does
/// otherwise.
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
        modifier(ArrivalFocus(anchor: anchor))
    }
}

private struct ArrivalFocus: ViewModifier {
    let anchor: PullRequestDetailsStore.Anchor

    @Environment(\.detailsArrival) private var arrival
    @AccessibilityFocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityFocused($isFocused)
            .onChange(of: arrival.count) {
                if arrival.anchor == anchor { isFocused = true }
            }
    }
}
