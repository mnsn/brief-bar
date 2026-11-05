import SwiftUI

/// Where a pull request's details went last, as `PullRequestDetailsContent` takes them where they're asked to go, for
/// VoiceOver to follow them there each time: to what they point out, a thread, a file's row, a build or a check, or else
/// the header of one of their parts, of their Files, or their title (`focusesOnArrival`, `takesFocusOnArrival`). Each time
/// they go somewhere is another arrival, to the same place again too, as when a build is asked for again while it's still
/// pointed out (`arrived(at:since:)`), and what they point out there shows for a moment of its own (`pointedOut`). And
/// whether they're on their way somewhere: their title doesn't take VoiceOver's focus as it shows then, as it does
/// otherwise.
struct DetailsArrival: Equatable {
    /// Where they went last; nil before they went anywhere.
    var anchor: PullRequestDetailsStore.Anchor?
    /// How many times they went somewhere: each time is another, to the same place again too.
    var count = 0
    /// They're asked to go somewhere, and haven't got there yet.
    var isGoing = false
    /// What they point out for a moment: the thread, the file's row, the build or the check they went to last, until its
    /// moment is over (`endMoment(of:)`). Nothing once they went to a part, their Files or their top, which ends what
    /// they pointed out a moment ago elsewhere.
    private(set) var pointedOut: PullRequestDetailsStore.Anchor?

    /// They went there: VoiceOver goes there, and a thread, a file's row, a build or a check is pointed out, for a moment
    /// of its own, though it was a moment ago.
    mutating func arrive(at anchor: PullRequestDetailsStore.Anchor) {
        self.anchor = anchor
        count += 1
        pointedOut = Self.pointsOut(anchor) ? anchor : nil
    }

    /// The moment of the arrival numbered `arrived` is over: what it pointed out isn't anymore, unless they went somewhere
    /// since, such as there again, which has a moment of its own, or somewhere that ended it already.
    mutating func endMoment(of arrived: Int) {
        if count == arrived { pointedOut = nil }
    }

    /// Whether they point it out as they go there: a thread, a file's row, a build or a check; not a part, their Files or
    /// their top, whose headers take VoiceOver's focus all the same.
    static func pointsOut(_ anchor: PullRequestDetailsStore.Anchor) -> Bool {
        switch anchor {
        case .thread, .check, .file: true
        case .section, .files, .top: false
        }
    }

    /// Whether, from `old` to this, they went to `anchor`: each time they go there, though they went there last too and
    /// still point it out, for VoiceOver to go there again; not as they set out somewhere (`isGoing`), nor as a moment
    /// ends.
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
