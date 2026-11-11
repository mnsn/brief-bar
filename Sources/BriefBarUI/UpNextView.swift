import BriefBarCore
import SwiftUI

/// Up Next, at the top of Azure DevOps' Pull Requests page while Pull Request Order is on, whatever the page's order: a slot
/// for each kind of next that has something, side by side across the page, each in its stage's color, with its pull request,
/// why, its mission and how many more. A click on one shows its details; its title's ⌄ chooses which of its pull requests it
/// shows, remembered until that one moves on (`UpNextPicks`); "2 more ›" shows By Mission's Board at that column. Narrow, or
/// with bigger text, the slots wrap, two or three to a line. It folds with its chevron, remembered. It changes no group or
/// count: it only points.
package struct UpNextView: View {
    let upNext: UpNext
    @ObservedObject var order: PullRequestOrder
    /// Shows a pull request's details.
    let select: (ItemRef) -> Void
    /// Shows By Mission's Board at a column.
    let showColumn: (PullRequestStage) -> Void

    @Environment(\.textScale) private var textScale

    package init(upNext: UpNext, order: PullRequestOrder, select: @escaping (ItemRef) -> Void, showColumn: @escaping (PullRequestStage) -> Void) {
        self.upNext = upNext
        self.order = order
        self.select = select
        self.showColumn = showColumn
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !order.isUpNextFolded {
                if upNext.isEmpty {
                    Text(UpNext.nothingNext)
                        .font(size: 12.5)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    UpNextGrid(minimum: 176 * textScale, spacing: 10) {
                        ForEach(upNext.slots) { slot in
                            UpNextSlotView(slot: slot, order: order, select: select, showColumn: showColumn)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "Up Next", which folds it, and, folded, how many each slot has.
    private var header: some View {
        let folded = order.isUpNextFolded
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { order.setUpNextFolded(!folded) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(size: 9, weight: .bold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                Text("Up Next")
                    .font(size: 13, weight: .semibold)
                if folded {
                    ForEach(upNext.slots) { slot in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(slot.kind.stage.color)
                                .frame(width: 7 * textScale, height: 7 * textScale)
                            Text("\(slot.count)")
                                .monospacedDigit()
                        }
                        .font(size: 11.5, weight: .medium)
                        .foregroundStyle(.secondary)
                        .help("\(slot.kind.title): \(slot.count)")
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(folded ? "Show what's next for you" : "Fold Up Next")
        .accessibilityLabel("Up Next")
        .accessibilityValue(folded ? upNext.slots.map { "\($0.kind.title): \($0.count)" }.joined(separator: ", ") : "")
        .accessibilityHint(folded ? "Shows what's next for you" : "Folds it")
        .accessibilityAddTraits(.isHeader)
    }

    /// What VoiceOver hears after a slot's title: why, a second reason after a pause, then its mission, and that you chose it
    /// where you did: "Cart asks you, build failed, Not in a mission", where its tooltip says "‘Cart’ asks you · build
    /// failed".
    package static func spoken(_ slot: UpNext.Slot, mission: String, order: PullRequestOrder) -> String {
        let spoken = SpokenText.unquoted(why(slot.card, in: slot.kind, order: order, then: ", ") + ", " + mission)
        return slot.isPicked ? spoken + ", you chose it" : spoken
    }

    /// A pull request as a slot's ⌄ lists it, with why it's there: "!4131 Fix the coupon rounding error — Build failed".
    package static func choice(_ card: BoardCard, in kind: UpNextSlot? = nil, order: PullRequestOrder) -> String {
        [card.ref.shortOrderLabel, order.name(of: card.ref)].compactMap { $0 }.joined(separator: " ") + " — "
            + why(card, in: kind, order: order)
    }

    /// Why a slot has a pull request: in Fix next, what needs you first, and where it is, "Build failed · in Approved"
    /// (`StageText.fixWords`); else why it's in its stage.
    package static func why(_ card: BoardCard, in kind: UpNextSlot?, order: PullRequestOrder, then separator: String = " · ") -> String {
        kind == .fix ? StageText.fixWords(card.reading, name: order.name(of:), then: separator)
            : StageText.why(card.reading, name: order.name(of:), then: separator)
    }

    /// Whether a slot's menu offers Let BriefBar Choose: once you chose a pull request for it, whether the slot shows it now
    /// or waits for it to come back.
    package static func offersLetBriefBarChoose(_ slot: UpNext.Slot, order: PullRequestOrder) -> Bool {
        order.picks[slot.kind] != nil
    }

    /// What VoiceOver hears of a slot's ⌄: "Chooses which of its 3 pull requests it shows", or, with one, "Chooses which
    /// pull request it shows".
    package static func chooserHint(_ slot: UpNext.Slot) -> String {
        slot.count > 1 ? "Chooses which of its \(slot.count) pull requests it shows" : "Chooses which pull request it shows"
    }
}

extension UpNextView {
    /// A card's mission's name, as By Mission's header has it, the name you gave it, else Apple Intelligence's, else
    /// BriefBar's own; or that it's in none.
    package static func missionTitle(_ key: MissionKey?, order: PullRequestOrder) -> String {
        guard let key, let mission = order.missions.first(where: { $0.key == key }) else { return "Not in a mission" }
        return order.title(of: mission)
    }
}

/// One of Up Next's slots: its kind in its stage's color, whose ⌄ chooses its pull request, ✎ once you chose it, and how
/// many it has; its pull request, why, and its mission; and "2 more ›", which shows the rest on the Board.
private struct UpNextSlotView: View {
    let slot: UpNext.Slot
    @ObservedObject var order: PullRequestOrder
    let select: (ItemRef) -> Void
    let showColumn: (PullRequestStage) -> Void

    @LocalState private var isHovered = false
    @Environment(\.textScale) private var textScale

    private var stage: PullRequestStage { slot.kind.stage }
    private var ref: ItemRef { slot.card.ref }

    var body: some View {
        let title = order.name(of: ref)
        let why = UpNextView.why(slot.card, in: slot.kind, order: order)
        let mission = missionTitle
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(stage.color)
                    .frame(width: 7 * textScale, height: 7 * textScale)
                    .accessibilityHidden(true)
                UpNextChooser(slot: slot, order: order)
                if slot.isPicked {
                    Image(systemName: "pencil")
                        .font(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .help(UpNext.pickedHelp)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                Text("\(slot.count)")
                    .font(size: 11.5, weight: .medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            Button {
                select(ref)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text([ref.shortOrderLabel, title].compactMap { $0 }.joined(separator: " "))
                        .font(size: 13, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(why)
                        .font(size: 12)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(mission)
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help([
                [ref.fullOrderLabel, title].compactMap { $0 }.joined(separator: " "), why, mission,
                slot.isPicked ? UpNext.pickedHelp : slot.kind.help, "Click to see its details",
            ].joined(separator: "\n"))
            .accessibilityLabel("\(slot.kind.title): \([ref.shortOrderLabel, title].compactMap { $0 }.joined(separator: " "))")
            .accessibilityValue(UpNextView.spoken(slot, mission: mission, order: order))
            .accessibilityHint("Shows its details")
            moreLine
                .padding(.top, 1)
        }
        .padding(.horizontal, 11)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // As tall as the tallest on its line.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlassCard(cornerRadius: 12, isHovered: isHovered))
        .overlay {
            // Its stage's color along its top.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(stage.color, lineWidth: 3 * textScale)
                .mask(alignment: .top) { Rectangle().frame(height: 3 * textScale) }
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    /// The column "2 more ›" shows: its own; for Fix next, which has what needs you from every column, the next one's.
    private var moreColumn: PullRequestStage {
        slot.kind == .fix && slot.cards.count > 1 ? slot.cards[1].stage : stage
    }

    /// "2 more ›", which shows the rest on the Board; nothing for one alone.
    @ViewBuilder
    private var moreLine: some View {
        if let more = slot.more {
            let column = moreColumn
            Button {
                showColumn(column)
            } label: {
                HStack(spacing: 2) {
                    Text(more)
                    Image(systemName: "chevron.right")
                        .font(size: 8.5, weight: .bold)
                }
                .font(size: 11.5, weight: .medium)
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(slot.kind == .fix ? "Show the next on By Mission's Board, in \(column.title)"
                : "Show the rest on By Mission's Board, in \(column.title)")
            .accessibilityLabel(slot.kind == .fix ? "\(more), the next in \(column.title)" : "\(more) in \(column.title)")
            .accessibilityHint("Shows them on By Mission's Board")
        }
    }

    /// Its mission's name, as By Mission has it, or that it's in none.
    private var missionTitle: String {
        UpNextView.missionTitle(slot.card.mission, order: order)
    }
}

/// An Up Next slot's title, with ⌄: its pull requests in its column's order, the one it shows checked, to choose which it
/// shows, first in its column on the Board, until that one moves on; and Let BriefBar Choose, once you chose one, whether
/// the slot shows it now or waits for it to come back, as while its build runs again, which gives it back to BriefBar's
/// order.
private struct UpNextChooser: View {
    let slot: UpNext.Slot
    @ObservedObject var order: PullRequestOrder

    var body: some View {
        let textColor = slot.kind.stage.textColor
        Menu {
            ForEach(slot.cards) { card in
                Toggle(UpNextView.choice(card, in: slot.kind, order: order), isOn: Binding(get: { card.ref == slot.card.ref }, set: { _ in
                    choose(card.ref)
                }))
            }
            Divider()
            Button("Let BriefBar Choose") { letBriefBarChoose() }
                .disabled(!UpNextView.offersLetBriefBarChoose(slot, order: order))
        } label: {
            HStack(spacing: 3) {
                Text(slot.kind.title)
                    .font(size: 11.5, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                MenuChevron()
            }
            .foregroundStyle(textColor)
            .contentShape(Rectangle())
        }
        .labelMenuStyle()
        .help("Choose which pull request \(slot.kind.title) shows, first on the Board too, until it moves on")
        .accessibilityLabel(slot.kind.title)
        .accessibilityValue(slot.isPicked ? "You chose its pull request" : "")
        .accessibilityHint(UpNextView.chooserHint(slot))
    }

    private func choose(_ ref: ItemRef) {
        guard order.pickNext(ref, in: slot.kind) else { return }
        AccessibilityNotification.Announcement("\(slot.kind.title): \(ref.shortOrderLabel)").post()
    }

    private func letBriefBarChoose() {
        order.letBriefBarChoose(slot.kind)
        AccessibilityNotification.Announcement("BriefBar chooses \(slot.kind.title)").post()
    }
}

/// Up Next's slots in lines: as many to a line as fit at their narrowest, never more than there are, so that they always
/// fill the line, as wide as it allows and as tall as the tallest of them on it.
package struct UpNextGrid: Layout {
    /// How narrow a slot can be.
    let minimum: CGFloat
    let spacing: CGFloat

    package init(minimum: CGFloat, spacing: CGFloat) {
        self.minimum = minimum
        self.spacing = spacing
    }

    /// How many slots go on a line this wide.
    package static func columns(count: Int, width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        guard width.isFinite, width > 0 else { return count }
        let fit = Int(((width + spacing) / (minimum + spacing)).rounded(.down))
        return min(count, max(1, fit))
    }

    package func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = finite(proposal.width, subviews: subviews)
        let lines = arrange(width: width, subviews: subviews)
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: finite(bounds.width, subviews: subviews), subviews: subviews) {
            for (column, index) in line.indices.enumerated() {
                let x = bounds.minX + CGFloat(column) * (line.width + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: line.width, height: line.height)
                )
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: Range<Int>
        /// Each slot's width on it.
        var width: CGFloat
        var height: CGFloat
    }

    /// The width to lay its slots out in: the one offered, or, asked for its ideal or its largest size, its slots side by
    /// side at their narrowest. Never infinite, nor less than nothing, as SwiftUI needs a size it can use.
    private func finite(_ width: CGFloat?, subviews: Subviews) -> CGFloat {
        if let width, width.isFinite { return max(0, width) }
        return max(0, CGFloat(subviews.count) * (minimum + spacing) - spacing)
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        let columns = Self.columns(count: subviews.count, width: width, minimum: minimum, spacing: spacing)
        guard columns > 0 else { return [] }
        let slot = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            let indices = start..<min(start + columns, subviews.count)
            let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: slot, height: nil)).height }.max() ?? 0
            return Line(indices: indices, width: slot, height: height)
        }
    }
}
