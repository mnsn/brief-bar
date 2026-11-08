import BriefBarCore
import SwiftUI

/// Up Next, at the top of Azure DevOps' Pull Requests page while Pull Request Order is on, By Status and By Mission alike: a
/// slot for each kind of next that has something, side by side, each in its stage's color, with its pull request, why, its
/// mission and how many more. A click on one shows its details; "2 more ›" shows By Mission's Board at that column. Narrow,
/// or with bigger text, the slots wrap, two or three to a line. It folds with its chevron, remembered. It changes no group
/// or count: it only points.
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
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 176 * textScale), spacing: 10, alignment: .top)], alignment: .leading,
                        spacing: 10
                    ) {
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

    /// "2 more ›", or, for one alone, nothing in the same room, so the slots on a line keep one height.
    @ViewBuilder
    private var moreLine: some View {
        let label = HStack(spacing: 2) {
            Text(slot.more ?? "1 more")
            Image(systemName: "chevron.right")
                .font(size: 8.5, weight: .bold)
        }
        .font(size: 11.5, weight: .medium)
        if let more = slot.more {
            Button {
                showColumn(stage)
            } label: {
                label
                    .foregroundStyle(.tint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the rest on By Mission's Board, in \(stage.title)")
            .accessibilityLabel("\(more) in \(stage.title)")
            .accessibilityHint("Shows them on By Mission's Board")
        } else {
            label
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// Its mission's name, as By Mission has it, or that it's in none.
    private var missionTitle: String {
        guard let key = slot.card.mission, let mission = order.missions.first(where: { $0.key == key }) else { return "Not in a mission" }
        return OrderText.title(of: mission, name: order.name(of:))
    }
}
