import BriefBarCore
import SwiftUI

// A split Apple Intelligence suggests (§7.4.8), under its mission's header in the List, on the Map and in the Board's lane:
// which group keeps the mission and where the others go, with Split and Keep Together. Nothing moves until you click.

/// The box of a split Apple Intelligence suggests for a mission, while it has one that holds: each group's line, its name
/// and where it goes, then its pull requests, each showing its details; then the button that does it, Keep Together, and
/// who suggested it. It takes no focus and appears without animation; narrow, or at 150% text, its lines wrap, and so do
/// its buttons. VoiceOver reads it as a group, then its buttons.
package struct SplitSuggestionView: View {
    let mission: OrderMission
    @ObservedObject var order: PullRequestOrder
    /// What a pull request's number does: shows its details, as its row's click does.
    let select: (ItemRef) -> Void

    @Environment(\.textScale) private var textScale

    package init(mission: OrderMission, order: PullRequestOrder, select: @escaping (ItemRef) -> Void) {
        self.mission = mission
        self.order = order
        self.select = select
    }

    package var body: some View {
        if let box = order.splitBox(for: mission) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .foregroundStyle(Self.tint)
                    Text(box.heading)
                        .font(size: 12, weight: .semibold)
                }
                .font(size: 12)
                .accessibilityHidden(true)
                ForEach(Array(box.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
                // Who suggested it at the trailing edge, as long as the row fits; else under the buttons.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        buttons(box)
                        Spacer(minLength: 12)
                        credit
                    }
                    FlowLayout(spacing: 8, lineSpacing: 6) {
                        buttons(box)
                        credit
                    }
                }
                .font(size: 12)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Self.tint.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Self.tint.opacity(0.35), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(SpokenText.unquoted(box.spoken))
        }
    }

    /// Apple Intelligence's color, as the box's mark, border and button have it.
    static let tint = Color.purple

    private func buttons(_ box: SplitBox) -> some View {
        SplitButtons(title: box.button, split: split, keepTogether: keepTogether)
    }

    private var credit: some View {
        HStack(spacing: 3) {
            Text("Apple Intelligence")
            Image(systemName: "info.circle")
        }
        .font(size: 11)
        .foregroundStyle(.secondary)
        .padding(.vertical, 3)
        .help(OrderText.splitHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Apple Intelligence")
        .accessibilityHint(OrderText.splitHelp)
    }

    /// A group: what it's called and where it goes, "Checkout coupons · keeps this mission", or "Not in a mission"; then
    /// its pull requests, "!4101 Add the coupon field · !4102 Round coupon totals", each showing its details.
    private func lineView(_ line: SplitBox.Line) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 3) {
            HStack(spacing: 4) {
                if line.goes == .keeps, mission.isFocused {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color.yellow)
                        .accessibilityHidden(true)
                }
                if let title = line.title {
                    Text(title)
                        .fontWeight(.medium)
                    Text("· \(line.says)")
                        .foregroundStyle(.secondary)
                } else {
                    Text(line.says)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            ForEach(Array(line.refs.enumerated()), id: \.element) { index, ref in
                pullRequest(ref, last: index == line.refs.count - 1)
            }
        }
        .font(size: 12)
        .accessibilityHidden(true)
    }

    private func pullRequest(_ ref: ItemRef, last: Bool) -> some View {
        let title = order.name(of: ref)
        return Button {
            select(ref)
        } label: {
            HStack(spacing: 3) {
                Text(ref.shortOrderLabel)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                if let title {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 260 * textScale, alignment: .leading)
                }
                if !last {
                    Text("·")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help([ref.shortOrderLabel, title].compactMap { $0 }.joined(separator: " ") + "\nClick to see its details")
    }

    private func split() {
        guard let said = order.split(mission) else { return }
        SpokenText.announce(SpokenText.unquoted(said))
    }

    private func keepTogether() {
        SpokenText.announce(order.keepTogether(mission))
    }
}

/// A suggested split's Split and Keep Together, their titles as big as the text on windows' pages (`ControlLabel`), which
/// AppKit would otherwise draw at their control's size.
package struct SplitButtons: View {
    /// What Split does, such as "Split in Two" or "Take Out !4120".
    let title: String
    let split: () -> Void
    let keepTogether: () -> Void

    package init(title: String, split: @escaping () -> Void, keepTogether: @escaping () -> Void) {
        self.title = title
        self.split = split
        self.keepTogether = keepTogether
    }

    package var body: some View {
        Button(action: split) { ControlLabel(title) }
            .buttonStyle(.borderedProminent)
            .tint(SplitSuggestionView.tint)
        Button(action: keepTogether) { ControlLabel(OrderText.keepTogether) }
            .buttonStyle(.bordered)
    }
}
