import AppKit
import BriefBarCore
import SwiftUI

// By Mission's List: a card for each mission, its rows in their order, with the graph in a gutter on their left, as
// Sapling's smartlog, Graphite's `gt log` and VS Code's Source Control Graph draw one.

/// A mission's card in List: its header, the line its merged pull requests fold into, its rows with the graph beside them,
/// a quiet row for each one the page's source doesn't list, how many another page lists, the pull requests stacked with
/// its own that its order doesn't name, and, after you changed one's stage, what you did, with Undo.
package struct MissionCard: View {
    let mission: OrderMission
    /// The kinds of pull request the page lists.
    let kinds: Set<ItemRef.Kind>
    /// Its pull requests' repository, as the page names it.
    let place: String?
    /// The page that lists its other pull requests, "GitHub", and opening it; nil when it can't open.
    let elsewhere: String
    let openElsewhere: (() -> Void)?
    /// A pull request's row as the page draws it; nil for one it doesn't list.
    let row: (OrderStep) -> AnyView?
    @ObservedObject var order: PullRequestOrder
    /// Its lane on the Board, for its next steps under its header; nil where its pull requests have no stages.
    let lane: BoardLane?
    /// What a next step's click does: what its row's does.
    let select: (ItemRef) -> Void

    @LocalState private var showsFolded = false
    @LocalState private var hovered: ItemRef?
    @Environment(\.textScale) private var textScale

    package init(
        mission: OrderMission, kinds: Set<ItemRef.Kind>, place: String?, elsewhere: String, openElsewhere: (() -> Void)?,
        order: PullRequestOrder, lane: BoardLane? = nil, select: @escaping (ItemRef) -> Void = { _ in },
        row: @escaping (OrderStep) -> AnyView?
    ) {
        self.mission = mission
        self.kinds = kinds
        self.place = place
        self.elsewhere = elsewhere
        self.openElsewhere = openElsewhere
        self.order = order
        self.lane = lane
        self.select = select
        self.row = row
    }

    package var body: some View {
        let mine = mission.steps(of: kinds)
        let folded = mine.filter { $0.status == .merged || $0.status == .closed }
        let shown = showsFolded ? mine : mine.filter { $0.status != .merged && $0.status != .closed }
        let gutter = mission.hasOrder ? OrderGutter(shown) : nil
        let width = gutter.map { OrderGutterRowView.width(lanes: $0.laneCount, scale: textScale) } ?? 0
        VStack(alignment: .leading, spacing: 6) {
            MissionHeader(mission: mission, order: order, place: place)
            if let lane {
                MissionNextStepsLine(lane: lane, order: order, select: select)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !folded.isEmpty {
                    foldedLine(folded, width: width)
                }
                ForEach(Array(shown.enumerated()), id: \.element.ref) { index, step in
                    rowView(step, divided: index > 0 || !folded.isEmpty, gutter: gutter, width: width)
                }
                let outside = mission.count(outside: kinds)
                if outside > 0 {
                    OrderElsewhereLine(count: outside, elsewhere: elsewhere, open: openElsewhere)
                        .padding(.leading, max(width, 6) + 8)
                        .padding(.vertical, 6)
                }
                let attached = mission.attached.filter { kinds.contains($0.ref.kind) }
                if !attached.isEmpty {
                    apartRows(attached, title: "Not in this order", width: width)
                }
                let sameStory = mission.sameStory.filter { kinds.contains($0.ref.kind) }
                if !sameStory.isEmpty {
                    apartRows(sameStory, title: OrderText.sameStory, width: width)
                }
                if order.said.contains(where: { $0.mission == mission.key }) {
                    OrderUndoLine(order: order, in: mission.key)
                        .padding(.leading, max(width, 6) + 8)
                        .padding(.trailing, 12)
                        .padding(.vertical, 6)
                }
                StageUndoLine(refs: Set((mission.steps + mission.attached).map(\.ref)), order: order)
                    .padding(.leading, max(width, 6) + 8)
                    .padding(.trailing, 12)
                    .padding(.vertical, 6)
            }
            .padding(.vertical, 4)
            .background(GlassCard(cornerRadius: 18))
        }
        .id(mission.key)
    }

    private func rowView(_ step: OrderStep, divided: Bool, gutter: OrderGutter?, width: CGFloat) -> some View {
        let gutterRow = gutter?.rows.first { $0.ref == step.ref }
        let lit = hovered.flatMap { hovered in gutter.map { $0.highlighted(by: hovered) } }
        return VStack(spacing: 0) {
            if divided {
                Divider().padding(.leading, width + 44).padding(.trailing, 12)
            }
            (row(step) ?? AnyView(OrderPlaceholderRow(step: step, order: order)))
                .padding(.leading, max(width, 6))
                .padding(.trailing, 6)
                .padding(.vertical, 3)
        }
        .background(alignment: .topLeading) {
            if let gutterRow {
                OrderGutterRowView(
                    row: gutterRow, marker: step.standing.marker, stage: order.drawnStage(of: step),
                    nodeY: (divided ? 1 : 0) + 3 + 6 + 10 * textScale, lit: lit
                )
                .frame(width: width)
            }
        }
        .onHover { inside in
            if inside {
                hovered = step.ref
            } else if hovered == step.ref {
                hovered = nil
            }
        }
    }

    private func foldedLine(_ folded: [OrderStep], width: CGFloat) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showsFolded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(folded.contains { order.drawnStage(of: $0) == .merged } ? PullRequestStage.merged.color : .green)
                Text(OrderText.folded(folded))
                Image(systemName: "chevron.right")
                    .font(size: 9, weight: .bold)
                    .rotationEffect(.degrees(showsFolded ? 90 : 0))
            }
            .font(size: 11.5, weight: .medium)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, max(width, 6) + 8)
        .padding(.vertical, 6)
        .help(showsFolded ? "Fold the ones that merged or closed" : "Show the ones that merged or closed")
        .accessibilityLabel(showsFolded ? "Hide \(OrderText.folded(folded))" : "Show \(OrderText.folded(folded))")
    }

    /// Pull requests that show with it apart: those stacked with its own that its order doesn't name, or those for its story.
    private func apartRows(_ steps: [OrderStep], title: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 12)
            Text(title)
                .font(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(.leading, max(width, 6) + 8)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(steps, id: \.ref) { step in
                (row(step) ?? AnyView(OrderPlaceholderRow(step: step, order: order)))
                    .padding(.leading, max(width, 6))
                    .padding(.trailing, 6)
                    .padding(.vertical, 3)
            }
        }
    }
}

/// How many of a mission's pull requests another page lists, "+1 on GitHub ›", which opens that page where it can.
package struct OrderElsewhereLine: View {
    let count: Int
    /// The page that lists them, "GitHub".
    let elsewhere: String
    let open: (() -> Void)?

    package init(count: Int, elsewhere: String, open: (() -> Void)?) {
        self.count = count
        self.elsewhere = elsewhere
        self.open = open
    }

    package var body: some View {
        let text = OrderText.elsewhere(count, on: elsewhere)
        Group {
            if let open {
                Button(action: open) {
                    HStack(spacing: 4) {
                        Text(text)
                        Image(systemName: "chevron.right")
                            .font(size: 9, weight: .bold)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show its other pull requests on \(elsewhere)'s Pull Requests page")
            } else {
                Text(text)
                    .help("Its other pull requests are on \(elsewhere)")
            }
        }
        .font(size: 11.5, weight: .medium)
        .foregroundStyle(.secondary)
    }
}

/// A quiet row for a pull request in a mission that the page's source doesn't list, "!4118 · Can't see it": one that
/// isn't yours or one you review, one that merged a while ago, or one whose source is off. A GitHub one opens on GitHub.
struct OrderPlaceholderRow: View {
    let step: OrderStep
    @ObservedObject var order: PullRequestOrder

    @Environment(\.interfaceOptions) private var options
    @Environment(\.textScale) private var textScale

    var body: some View {
        let open = opener
        let content = HStack(spacing: options.readableRows ? 10 : 9) {
            Image(systemName: step.status == .merged ? "arrow.triangle.merge" : "eye.slash")
                .font(size: 13)
                .foregroundStyle(.tertiary)
                .frame(width: options.rowIconWidth * textScale, height: 20 * textScale)
            Text(OrderText.placeholder(step))
                .font(size: 12.5, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            OrderCapsule(OrderRowContext(step: step, isReady: false))
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        Group {
            if let open {
                Button(action: open) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .help([OrderText.placeholder(step), OrderText.sentence(of: step)].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OrderText.placeholder(step))
        .accessibilityValue(OrderText.sentence(of: step) ?? "")
    }

    /// Opens it where it lives, when a source says how, or on GitHub.
    private var opener: (() -> Void)? {
        if let open = order.describe(step.ref)?.open { return open }
        guard step.ref.kind == .gitHubPullRequest, let url = URL(string: "https://github.com/\(step.ref.scope)/pull/\(step.ref.id)") else {
            return nil
        }
        return { ThisMac.open(url) }
    }
}

/// One row's part of the graph: the lines through it, each in its lane, curving at forks and joins, and its node beside
/// the row's title. Solid where a pull request is stacked on the one before it, dashed where it only merges after it.
/// Hovering a row lights up what it goes before and after, and dims the rest. VoiceOver skips it: the row says it all.
struct OrderGutterRowView: View {
    let row: OrderGutter.Row
    let marker: OrderMarker
    /// Its stage, whose color its node takes; nil for one with none.
    var stage: PullRequestStage?
    /// Where its node is, from the row's top: beside its title.
    let nodeY: CGFloat
    /// What hovering a row lights up; nil while none is hovered.
    let lit: Set<ItemRef>?

    @Environment(\.textScale) private var textScale

    static func laneWidth(scale: CGFloat) -> CGFloat { 14 * scale }

    /// How wide the gutter is with this many lanes.
    static func width(lanes: Int, scale: CGFloat) -> CGFloat {
        CGFloat(max(lanes, 1)) * laneWidth(scale: scale) + 8 * scale
    }

    var body: some View {
        let scale = textScale
        let node = OrderNodeMark.diameter(marker, scale: scale)
        Canvas { context, size in
            for segment in row.segments {
                draw(segment, in: &context, height: size.height, scale: scale, radius: node / 2)
            }
        }
        .overlay(alignment: .topLeading) {
            OrderNodeMark(marker, isDimmed: lit.map { !$0.contains(row.ref) } ?? false, stage: stage)
                .offset(x: x(row.lane, scale) - node / 2, y: nodeY - node / 2)
        }
        .accessibilityHidden(true)
    }

    private func x(_ lane: Int, _ scale: CGFloat) -> CGFloat {
        4 * scale + (CGFloat(lane) + 0.5) * Self.laneWidth(scale: scale)
    }

    private func draw(_ segment: OrderGutter.Segment, in context: inout GraphicsContext, height: CGFloat, scale: CGFloat, radius: CGFloat) {
        let node = CGPoint(x: x(row.lane, scale), y: nodeY)
        let bend = min(nodeY, 11 * scale)
        var path = Path()
        switch (segment.from, segment.to) {
        case (.top(let lane), .node):
            let start = CGPoint(x: x(lane, scale), y: 0)
            if lane == row.lane {
                path.move(to: start)
                path.addLine(to: CGPoint(x: node.x, y: node.y - radius))
            } else {
                // A join: down its lane, then into the node.
                path.move(to: start)
                path.addLine(to: CGPoint(x: start.x, y: max(0, node.y - bend)))
                path.addCurve(
                    to: CGPoint(x: node.x, y: node.y - radius),
                    control1: CGPoint(x: start.x, y: node.y - radius),
                    control2: CGPoint(x: node.x, y: max(0, node.y - bend))
                )
            }
        case (.node, .bottom(let lane)):
            let end = CGPoint(x: x(lane, scale), y: height)
            if lane == row.lane {
                path.move(to: CGPoint(x: node.x, y: node.y + radius))
                path.addLine(to: end)
            } else {
                // A fork: out of the node, then down its lane.
                path.move(to: CGPoint(x: node.x, y: node.y + radius))
                path.addCurve(
                    to: CGPoint(x: end.x, y: min(height, node.y + bend)),
                    control1: CGPoint(x: node.x, y: min(height, node.y + bend)),
                    control2: CGPoint(x: end.x, y: node.y + radius)
                )
                path.addLine(to: end)
            }
        case (.top(let from), .bottom(let to)):
            path.move(to: CGPoint(x: x(from, scale), y: 0))
            path.addLine(to: CGPoint(x: x(to, scale), y: height))
        default:
            return
        }
        let isLit = lit.map { $0.contains(segment.line.edge.before) && $0.contains(segment.line.edge.after) }
        let color: Color = switch isLit {
        case nil: .secondary.opacity(0.55)
        case true?: .accentColor
        case false?: .secondary.opacity(0.18)
        }
        let width = 1.5 * scale
        let style = segment.line.style == .solid
            ? StrokeStyle(lineWidth: width, lineCap: .round)
            : StrokeStyle(lineWidth: width, lineCap: .round, dash: [3 * scale, 3 * scale])
        context.stroke(path, with: .color(color), style: style)
    }
}

extension OrderNodeMark {
    /// How wide a node is, as drawn: none for one without a mark.
    static func diameter(_ marker: OrderMarker, scale: CGFloat) -> CGFloat {
        marker == .none ? 0 : 9 * scale
    }
}
