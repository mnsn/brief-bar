import BriefBarCore
import SwiftUI

/// Up Next, at the top of Azure DevOps' Pull Requests page while Pull Request Order is on, whatever the page's order: a slot
/// for each kind of next that has something, side by side across the page, each in its stage's color, with its pull request,
/// why, its mission and how many more. A click on one shows its details; "2 more ›" shows By Mission's Board at that column.
/// Narrow, or with bigger text, the slots wrap, two or three to a line. It folds with its chevron, remembered. It changes no
/// group or count: it only points.
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

    /// What VoiceOver hears after a slot's title: why, a second reason after a pause, then its mission: "Cart asks you,
    /// build failed, Not in a mission", where its tooltip says "‘Cart’ asks you · build failed".
    package static func spoken(_ slot: UpNext.Slot, mission: String, order: PullRequestOrder) -> String {
        SpokenText.unquoted(StageText.why(slot.card.reading, name: order.name(of:), then: ", ") + ", " + mission)
    }
}

/// One of Up Next's slots: its kind in its stage's color and how many it has; its pull request, why, and its mission; and
/// "2 more ›", which shows the rest on the Board.
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
        let why = StageText.why(slot.card.reading, name: order.name(of:))
        let mission = missionTitle
        VStack(alignment: .leading, spacing: 4) {
            Button {
                select(ref)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(stage.color)
                            .frame(width: 7 * textScale, height: 7 * textScale)
                        Text(slot.kind.title)
                            .font(size: 11.5, weight: .semibold)
                            .foregroundStyle(stage.textColor)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(slot.count)")
                            .font(size: 11.5, weight: .medium)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
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
            .help([[ref.fullOrderLabel, title].compactMap { $0 }.joined(separator: " "), why, mission, slot.kind.help, "Click to see its details"]
                .joined(separator: "\n"))
            .accessibilityLabel("\(slot.kind.title): \([ref.shortOrderLabel, title].compactMap { $0 }.joined(separator: " "))")
            .accessibilityValue(UpNextView.spoken(slot, mission: mission, order: order))
            .accessibilityHint("Shows its details")
            moreLine
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

    /// "2 more ›", which shows the rest on the Board; nothing for one alone.
    @ViewBuilder
    private var moreLine: some View {
        if let more = slot.more {
            Button {
                showColumn(stage)
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
            .help("Show the rest on By Mission's Board, in \(stage.title)")
            .accessibilityLabel("\(more) in \(stage.title)")
            .accessibilityHint("Shows them on By Mission's Board")
        }
    }

    /// Its mission's name, as By Mission has it, or that it's in none.
    private var missionTitle: String {
        guard let key = slot.card.mission, let mission = order.missions.first(where: { $0.key == key }) else { return "Not in a mission" }
        return OrderText.title(of: mission, name: order.name(of:))
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
        let width = proposal.width ?? CGFloat(subviews.count) * (minimum + spacing) - spacing
        let lines = arrange(width: width, subviews: subviews)
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
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
