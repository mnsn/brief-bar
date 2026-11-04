import AppKit
import BriefBarCore
import SwiftUI

// By Mission's Map: each mission a band, a graph from left to right in merge waves, as GitHub Actions' visualization graph
// and Airflow's grid lay runs out. Columns are what merged, then what can merge now, then what comes after; lanes are the
// sessions that opened its pull requests. Only lines from a pull request to one that comes right after it join them.

/// A mission's band in the Map: its header, the task or work item most of its pull requests go with, and the graph,
/// which scrolls sideways when it's wide. Above `OrderMap.mostPullRequests` pull requests, its list instead, with why.
package struct MissionBand: View {
    let mission: OrderMission
    let place: String?
    /// The work item most of its pull requests are linked to, as a badge: "5101 Save items for later".
    let badge: String?
    let isSelected: (ItemRef) -> Bool
    /// What clicking a node does: what clicking its row does, or opening it where it lives.
    let select: (ItemRef) -> Void
    /// Its list, for a mission too big to draw.
    let list: () -> AnyView
    @ObservedObject var order: PullRequestOrder

    package init(
        mission: OrderMission, place: String?, badge: String?, order: PullRequestOrder, isSelected: @escaping (ItemRef) -> Bool,
        select: @escaping (ItemRef) -> Void, list: @escaping () -> AnyView
    ) {
        self.mission = mission
        self.place = place
        self.badge = badge
        self.order = order
        self.isSelected = isSelected
        self.select = select
        self.list = list
    }

    package var body: some View {
        if let map = OrderMap(mission) {
            VStack(alignment: .leading, spacing: 6) {
                MissionHeader(mission: mission, order: order, place: [place, badge].compactMap { $0 }.joined(separator: " · "))
                ScrollView(.horizontal) {
                    OrderMapGrid(map: map, mission: mission, order: order, isSelected: isSelected, select: select)
                        .padding(12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(GlassCard(cornerRadius: 18))
            }
            .id(mission.key)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label(OrderText.tooManyToDraw(mission.pullRequestCount), systemImage: "list.bullet")
                    .font(size: 11.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                list()
            }
        }
    }
}

/// The graph of a mission's band: column titles, its sessions' lanes with their names, the lines between its pull requests
/// and their nodes, each a button in merge order, as VoiceOver reads them.
struct OrderMapGrid: View {
    let map: OrderMap
    let mission: OrderMission
    @ObservedObject var order: PullRequestOrder
    let isSelected: (ItemRef) -> Bool
    let select: (ItemRef) -> Void

    @LocalState private var hovered: ItemRef?
    @Environment(\.textScale) private var textScale

    private struct Metrics {
        let scale: CGFloat
        var label: CGFloat { 112 * scale }
        var title: CGFloat { 20 * scale }
        var nodeWidth: CGFloat { 172 * scale }
        var nodeHeight: CGFloat { 40 * scale }
        var columnGap: CGFloat { 36 * scale }
        var rowGap: CGFloat { 10 * scale }

        func x(_ column: Int) -> CGFloat { label + CGFloat(column) * (nodeWidth + columnGap) }
        func y(_ row: Int) -> CGFloat { title + CGFloat(row) * (nodeHeight + rowGap) }
    }

    var body: some View {
        let metrics = Metrics(scale: textScale)
        let rows = map.lanes.map { $0.row + $0.height }.max() ?? 1
        let width = metrics.x(map.columns.count) - metrics.columnGap
        let height = metrics.y(rows) - metrics.rowGap
        let lit = hovered.map { OrderLine.related(to: $0, by: map.lines) }
        let steps = Dictionary(mission.steps.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        ZStack(alignment: .topLeading) {
            lanes(metrics, width: width)
            columnTitles(metrics)
            Canvas { context, _ in
                for line in map.lines {
                    draw(line, in: &context, metrics: metrics, lit: lit)
                }
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)
            ForEach(Array(map.nodes.enumerated()), id: \.element.ref) { index, node in
                if let step = steps[node.ref] {
                    OrderMapNode(
                        step: step, item: order.describe(node.ref), isSelected: isSelected(node.ref),
                        isDimmed: lit.map { !$0.contains(node.ref) } ?? false, width: metrics.nodeWidth, height: metrics.nodeHeight
                    ) {
                        select(node.ref)
                    }
                    .onHover { inside in
                        if inside {
                            hovered = node.ref
                        } else if hovered == node.ref {
                            hovered = nil
                        }
                    }
                    .offset(x: metrics.x(node.column), y: metrics.y(node.row))
                    .accessibilitySortPriority(Double(map.nodes.count - index))
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    /// The sessions' lanes: each one's name on the left, a quiet line between them.
    private func lanes(_ metrics: Metrics, width: CGFloat) -> some View {
        ForEach(Array(map.lanes.enumerated()), id: \.offset) { index, lane in
            let top = metrics.y(lane.row)
            let laneHeight = CGFloat(lane.height) * (metrics.nodeHeight + metrics.rowGap) - metrics.rowGap
            ZStack(alignment: .topLeading) {
                if index > 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: width, height: 1)
                        .offset(y: -metrics.rowGap / 2)
                }
                Text(lane.session.flatMap(order.name(of:)).map { "‘\($0)’" } ?? "No session")
                    .font(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: metrics.label - 12 * textScale, height: laneHeight, alignment: .leading)
            }
            .offset(y: top)
            .accessibilityHidden(true)
        }
    }

    private func columnTitles(_ metrics: Metrics) -> some View {
        ForEach(Array(map.columns.enumerated()), id: \.offset) { index, column in
            if let title = OrderText.title(of: column) {
                Text(title)
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .offset(x: metrics.x(index))
                    .accessibilityHidden(true)
            }
        }
    }

    private func draw(_ line: OrderLine, in context: inout GraphicsContext, metrics: Metrics, lit: Set<ItemRef>?) {
        guard let from = map.nodes.first(where: { $0.ref == line.edge.before }),
              let to = map.nodes.first(where: { $0.ref == line.edge.after })
        else { return }
        let start = CGPoint(x: metrics.x(from.column) + metrics.nodeWidth, y: metrics.y(from.row) + metrics.nodeHeight / 2)
        let end = CGPoint(x: metrics.x(to.column), y: metrics.y(to.row) + metrics.nodeHeight / 2)
        let reach = max(12 * metrics.scale, (end.x - start.x) / 2)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + reach, y: start.y), control2: CGPoint(x: end.x - reach, y: end.y))
        let isLit = lit.map { $0.contains(line.edge.before) && $0.contains(line.edge.after) }
        let color: Color = switch isLit {
        case nil: .secondary.opacity(0.6)
        case true?: .accentColor
        case false?: .secondary.opacity(0.18)
        }
        let width = 1.5 * metrics.scale
        let style = line.style == .solid
            ? StrokeStyle(lineWidth: width, lineCap: .round)
            : StrokeStyle(lineWidth: width, lineCap: .round, dash: [3 * metrics.scale, 3 * metrics.scale])
        context.stroke(path, with: .color(color), style: style)
        // Its arrowhead.
        let size = 4.5 * metrics.scale
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - size, y: end.y - size * 0.6))
        head.addLine(to: CGPoint(x: end.x - size, y: end.y + size * 0.6))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

/// A pull request's node in the Map: its mark, its number and a short title, in its status's color. A click does what
/// clicking its row does.
struct OrderMapNode: View {
    let step: OrderStep
    /// How its source shows it, when one that's on lists it.
    let item: LinkedItem?
    let isSelected: Bool
    let isDimmed: Bool
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        let color = item?.color ?? .secondary
        Button(action: action) {
            HStack(spacing: 7) {
                OrderNodeMark(step.standing.marker)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.ref.shortOrderLabel)
                        .font(size: 11, weight: .semibold)
                        .monospacedDigit()
                    Text(item?.title ?? OrderText.capsule(step) ?? "")
                        .font(size: 10.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : color.opacity(0.35), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .opacity(isDimmed ? 0.45 : 1)
        .help(help)
        .accessibilityLabel([step.ref.shortOrderLabel, item?.title].compactMap { $0 }.joined(separator: " "))
        .accessibilityValue([item?.status, OrderText.sentence(of: step)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Whether clicking it can show it or open it, as its placeholder row's click can: a source that's on lists it, or it's
    /// on GitHub. One BriefBar can't see, such as an Azure DevOps pull request no list has, does nothing.
    private var canOpen: Bool {
        item?.open != nil || item?.show != nil || step.ref.kind == .gitHubPullRequest
    }

    private var help: String {
        [[step.ref.fullOrderLabel, item?.title].compactMap { $0 }.joined(separator: " "), item?.status, OrderText.sentence(of: step)]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

/// Under the Map: the pull requests it doesn't draw, as they're in no mission, and the way to List.
package struct NotInAMissionLine: View {
    let count: Int
    let showList: () -> Void

    package init(count: Int, showList: @escaping () -> Void) {
        self.count = count
        self.showList = showList
    }

    package var body: some View {
        if count > 0 {
            HStack(spacing: 6) {
                Text(OrderText.notInAMission(count))
                    .foregroundStyle(.secondary)
                Button("Show List", action: showList)
                    .buttonStyle(.borderless)
            }
            .font(size: 12)
            .padding(.horizontal, 4)
        }
    }
}

/// The badge of a mission's band: the work item most of its pull requests are linked to, through Show Links or Azure
/// DevOps, "5101 Save items for later"; nil while Show Links is off, or when none is.
@MainActor
package enum OrderBadge {
    package static func workItem(of mission: OrderMission, links: Links) -> String? {
        var counts: [ItemRef: Int] = [:]
        for step in mission.steps {
            for connection in links.connections(of: step.ref) where connection.item.ref.kind == .workItem {
                counts[connection.item.ref, default: 0] += 1
            }
        }
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
        let item = links.describe(best)
        return item.label == item.title ? item.title : "\(item.label) \(item.title)"
    }
}
