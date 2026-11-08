import BriefBarCore
import SwiftUI

/// Why the Board's keys couldn't move a pull request while its details covered the Board, which hides the line under the
/// card's lane that says so: for the details to say it, under its stage track.
package struct StageRefusal: Equatable, Sendable {
    package let ref: ItemRef
    /// "Azure DevOps decides when it can merge: once it says it's ready to complete".
    package let why: String
    /// How its stage read as it couldn't leave it: once it reads otherwise, it's said no more.
    package let reading: StageReading

    package init(ref: ItemRef, why: String, reading: StageReading) {
        self.ref = ref
        self.why = why
        self.reading = reading
    }
}

extension PullRequestOrder {
    /// Why the Board's keys couldn't move a pull request while its details covered the Board, while its stage reads as it
    /// did then: nil once it changed, from anywhere, or the Board shows again, or you dismissed it.
    package func stageRefusal(of ref: ItemRef) -> String? {
        guard let refusal = stageRefusal, refusal.ref == ref, stage(of: ref) == refusal.reading else { return nil }
        return refusal.why
    }
}

/// Under a pull request's stage track in its details, while they cover the Board: why its keys couldn't move it, as the
/// Board says under the card's lane, which can't be seen then. Until its stage changes, the Board shows again, or you
/// dismiss it.
package struct StageRefusalLine: View {
    private let ref: ItemRef
    @ObservedObject private var order: PullRequestOrder

    package init(ref: ItemRef, order: PullRequestOrder) {
        self.ref = ref
        self.order = order
    }

    package var body: some View {
        if let why = order.stageRefusal(of: ref) {
            Line(text: why) { order.stageRefusal = nil }
        }
    }

    /// Why a card couldn't move: under its lane on the Board, and under its stage track in its details.
    struct Line: View {
        let text: String
        let dismiss: () -> Void

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "nosign")
                    .foregroundStyle(.orange)
                Text(text + ".")
                    .foregroundStyle(.secondary)
                    // In full, however big the text: in the narrow details, a reason takes a few lines.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(size: 9, weight: .bold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .font(size: 11)
            .accessibilityElement(children: .contain)
        }
    }
}
