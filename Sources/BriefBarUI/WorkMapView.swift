import AppKit
import BriefBarCore
import SwiftUI

// My Work's Map (`WorkMap`): By Mission, a band for each lane of the Board, with its header as the Board has it; All, a graph
// for each set of cards lines join, then the cards no line joins. Each card is a node: a click shows its details, as the
// Board's card does, and its right-click menu is the card's, with Hide on Map, which takes it off the Map until you show it
// again from its band's, or All's, hidden cards. Lines go from what comes first to what comes after, dotted through what the
// Map doesn't show there; hovering a node lights up what it waits for and what waits for it. Everything scales with the text
// size of windows' pages.

/// What a page draws of its cards on My Work's Map.
package struct WorkMapContent {
    /// A pull request's card on the Board, for its node's menu, actions and what VoiceOver says of it; nil for one the page
    /// doesn't know.
    package var card: (BoardCard) -> BoardCardContent?
    /// Your sprint work's cards, and the headers of its stories' bands; nil while the Board shows none.
    package var work: BoardWorkContent?
    /// How a work item's node looks; nil for one the page doesn't know.
    package var face: (BoardTask) -> WorkMapFace?
    /// The work items of yours a pull request's node names: "Task 5112"; nil for none.
    package var workOf: (ItemRef) -> String?
    /// The repository a pull request is in, as the page names it.
    package var place: (ItemRef) -> String?
    /// What a lane of the Board is called, for what a graph of All is about: a mission's name, a story's title.
    package var laneTitle: (BoardLane.Kind) -> String
    /// Whether a card's details show.
    package var isSelected: (ItemRef) -> Bool
    /// Shows a card's details.
    package var select: (ItemRef) -> Void
    /// The pull requests the search shows faded, as related to what it found (`PullRequestBoard.related`).
    package var related: Set<ItemRef>
    /// Shows the Board instead, for cards too many to draw.
    package var showBoard: () -> Void

    package init(
        card: @escaping (BoardCard) -> BoardCardContent?, work: BoardWorkContent?, face: @escaping (BoardTask) -> WorkMapFace?,
        workOf: @escaping (ItemRef) -> String?, place: @escaping (ItemRef) -> String?,
        laneTitle: @escaping (BoardLane.Kind) -> String, isSelected: @escaping (ItemRef) -> Bool,
        select: @escaping (ItemRef) -> Void, related: Set<ItemRef> = [], showBoard: @escaping () -> Void
    ) {
        self.card = card
        self.work = work
        self.face = face
        self.workOf = workOf
        self.place = place
        self.laneTitle = laneTitle
        self.isSelected = isSelected
        self.select = select
        self.related = related
        self.showBoard = showBoard
    }
}

/// How a work item's node looks on My Work's Map.
package struct WorkMapFace {
    /// Its type and ID: "Task 5104".
    package var label: String
    package var title: String
    /// Its state, as its process names it: "New", "Active".
    package var state: String
    /// Its type's symbol and color.
    package var symbol: String
    package var color: Color

    package init(label: String, title: String, state: String, symbol: String, color: Color) {
        self.label = label
        self.title = title
        self.state = state
        self.symbol = symbol
        self.color = color
    }
}

/// My Work's Map, as the page works it out once as it draws.
package struct WorkMapView: View {
    let map: WorkMap
    let grouping: WorkMapGrouping
    /// The missions, as By Mission lists them: those of the bands' headers.
    let missions: [OrderMission]
    @ObservedObject var order: PullRequestOrder
    let content: WorkMapContent

    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window
    /// Who shows the missions, for Apple Intelligence to name them while they're on screen.
    @LocalState private var viewer = MissionsViewer()
    /// The missions whose band, or graph, is in the page's sight now, By Mission and with All: Apple Intelligence names only
    /// those of the one it shows.
    @LocalState private var inSight: [WorkMapGrouping: Set<MissionKey>] = [:]

    package init(map: WorkMap, grouping: WorkMapGrouping, missions: [OrderMission], order: PullRequestOrder, content: WorkMapContent) {
        self.map = map
        self.grouping = grouping
        self.missions = missions
        self.order = order
        self.content = content
    }

    package var body: some View {
        // Apple Intelligence names only the missions on screen, as on the Board.
        let onScreen = missions.map(\.key).filter { inSight[grouping]?.contains($0) == true }
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 18) {
                // What you changed last of a mission no band shows, and why BriefBar didn't make a change.
                let shown = Set(map.bands.compactMap(\.lane.mission))
                if grouping == .all || order.said.contains(where: { OrderUndoLine.shows($0, about: nil, in: nil, outside: shown) }) {
                    OrderUndoLine(order: order, outside: grouping == .all ? nil : shown)
                        .padding(.horizontal, 4)
                }
                switch grouping {
                case .byMission:
                    if map.bands.isEmpty {
                        nothingYet
                    }
                    ForEach(map.bands) { band in
                        bandView(band)
                            .id(band.lane.kind)
                            .onSightChange { isInSight in
                                if let key = band.lane.mission { see(key, isInSight) }
                            }
                    }
                case .all:
                    all
                }
            }
            .onChange(of: order.revealed) { _, key in reveal(key, with: proxy) }
            .onChange(of: order.revealedCard) { _, ref in reveal(card: ref, with: proxy) }
            .onAppear {
                reveal(order.revealed, with: proxy)
                reveal(card: order.revealedCard, with: proxy)
                order.showing(onScreen, in: viewer, on: page)
            }
            .onChange(of: onScreen) { _, keys in order.showing(keys, in: viewer, on: page) }
            .onDisappear { order.stopShowing(in: viewer) }
        }
    }

    /// The window's page this is, when it's on one, for Pull Request Order to know when it's on screen.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestOrder.page(section, window: window)
    }

    private func see(_ key: MissionKey, _ isInSight: Bool) {
        if isInSight { inSight[grouping, default: []].insert(key) } else { inSight[grouping]?.remove(key) }
    }

    private var hidden: Set<ItemRef> {
        Set(order.mapHidden.refs)
    }

    private var nothingYet: some View {
        Text(WorkMapText.nothingYet)
            .font(size: 12.5)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: By Mission

    private func bandView(_ band: WorkMap.Band) -> some View {
        let mission = band.lane.mission.flatMap { key in missions.first { $0.key == key } }
        return VStack(alignment: .leading, spacing: 6) {
            header(band, mission: mission)
            if let graph = band.graph {
                graphCard(graph, mission: mission)
            } else if band.count > WorkMap.mostCards {
                tooMany(band.count)
            } else {
                Text(WorkMapText.allHidden)
                    .font(size: 11.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            if let key = band.lane.mission, order.said.contains(where: { $0.mission == key }) {
                OrderUndoLine(order: order, in: key)
                    .padding(.horizontal, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// A band's header, as its lane's on the Board: a mission's, with its next steps; a story's; or that of what's in no
    /// mission. Its hidden cards are a click away at its end.
    @ViewBuilder
    private func header(_ band: WorkMap.Band, mission: OrderMission?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch band.lane.kind {
            case .mission:
                if let mission {
                    MissionHeader(mission: mission, order: order, place: place(of: mission))
                    SplitSuggestionView(mission: mission, order: order, select: content.select)
                }
            case .story(let story):
                content.work?.story(story, band.lane.isFinishedStory)
            case .notInAMission:
                Text("Not in a mission")
                    .font(size: 15, weight: .semibold)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
            case .all:
                EmptyView()
            }
            if band.lane.mission != nil || !band.hidden.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if band.lane.mission != nil {
                        MissionNextStepsLine(lane: band.lane, order: order, select: content.select)
                    }
                    Spacer(minLength: 0)
                    if !band.hidden.isEmpty {
                        WorkMapHiddenButton(hidden: band.hidden, order: order, name: name(of:))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    /// The repositories its pull requests are in, the one with the most first: "payments-api and shop-web".
    private func place(of mission: OrderMission) -> String? {
        OrderText.places(mission.steps(of: [.pullRequest]).compactMap { content.place($0.ref) })
    }

    // MARK: All

    @ViewBuilder
    private var all: some View {
        if !map.hidden.isEmpty {
            HStack {
                Spacer(minLength: 0)
                WorkMapHiddenButton(hidden: map.hidden, order: order, name: name(of:))
            }
            .padding(.horizontal, 4)
        }
        if map.groups.isEmpty, map.loose.isEmpty {
            nothingYet
        }
        ForEach(map.groups) { group in
            VStack(alignment: .leading, spacing: 6) {
                Text(group.lanes.map(content.laneTitle).joined(separator: " · "))
                    .font(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
                if let graph = group.graph {
                    graphCard(graph, mission: nil)
                } else {
                    tooMany(group.items.count)
                }
            }
            .id(group.id)
            .onSightChange { isInSight in
                for kind in group.lanes {
                    if case .mission(let key) = kind { see(key, isInSight) }
                }
            }
        }
        if !map.loose.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(WorkMapText.notConnected)
                    .font(size: 15, weight: .semibold)
                    .padding(.horizontal, 4)
                    .help(WorkMapText.notConnectedHelp)
                    .accessibilityAddTraits(.isHeader)
                // What's still to do first, then what's done.
                let loose = map.loose.filter { !WorkMapGraph.isDone($0) } + map.loose.filter(WorkMapGraph.isDone)
                WorkMapLoose(items: loose, order: order, content: content, missions: missions)
                    .padding(12)
                    .background(GlassCard(cornerRadius: 18))
            }
            .id(WorkMapText.notConnected)
        }
    }

    // MARK: Pieces

    private func graphCard(_ graph: WorkMapGraph, mission: OrderMission?) -> some View {
        ScrollView(.horizontal) {
            WorkMapGraphView(graph: graph, order: order, content: content, mission: mission, missions: missions, hidden: hidden)
                .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(GlassCard(cornerRadius: 18))
    }

    private func tooMany(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Label(OrderText.tooManyCards(count), systemImage: "rectangle.split.3x1")
                .foregroundStyle(.secondary)
            Button("Show the Board", action: content.showBoard)
                .buttonStyle(.borderless)
        }
        .font(size: 11.5)
        .padding(.horizontal, 4)
    }

    /// What a hidden card is called in the list of them: "!4102" and its title, "Task 5104" and its.
    private func name(of item: BoardItem) -> (label: String, title: String) {
        switch item {
        case .pullRequest(let card):
            (card.ref.shortOrderLabel, order.describe(card.ref)?.title ?? "")
        case .work(let task):
            content.face(task).map { ($0.label, $0.title) } ?? (task.ref.shortOrderLabel, "")
        }
    }

    // MARK: Showing what's asked

    /// A mission a pull request's details asked My Work to show: its band, By Mission; the graph that has it, with All.
    private func reveal(_ key: MissionKey?, with proxy: ScrollViewProxy) {
        guard let key else { return }
        let band = map.bands.first { $0.lane.mission == key }?.lane.kind
        let group = map.groups.first { $0.lanes.contains(.mission(key)) }?.id
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                switch grouping {
                case .byMission: if let band { proxy.scrollTo(band, anchor: .top) }
                case .all: if let group { proxy.scrollTo(group, anchor: .top) }
                }
            }
            order.revealed = nil
        }
    }

    /// A card the page asked My Work to show, as Show Them does: its band, or the graph that has it, or All's cards that no
    /// line joins.
    private func reveal(card ref: ItemRef?, with proxy: ScrollViewProxy) {
        guard let ref else { return }
        let band = map.bands.first { WorkMap.items(of: $0.lane).contains { $0.ref == ref } }?.lane.kind
        let group = map.groups.first { $0.items.contains { $0.ref == ref } }?.id
        let isLoose = map.loose.contains { $0.ref == ref }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                switch grouping {
                case .byMission:
                    if let band { proxy.scrollTo(band, anchor: .top) }
                case .all:
                    if let group {
                        proxy.scrollTo(group, anchor: .top)
                    } else if isLoose {
                        proxy.scrollTo(WorkMapText.notConnected, anchor: .top)
                    }
                }
            }
            order.revealedCard = nil
        }
    }
}

// MARK: - A graph

/// A graph of the Map: its columns' titles, the lines between its cards and their nodes, each a button, column by column, as
/// VoiceOver reads them.
struct WorkMapGraphView: View {
    let graph: WorkMapGraph
    @ObservedObject var order: PullRequestOrder
    let content: WorkMapContent
    /// The mission whose band it is, By Mission; nil with All.
    let mission: OrderMission?
    let missions: [OrderMission]
    /// The cards you hid, which dotted lines go through.
    let hidden: Set<ItemRef>

    @LocalState private var hovered: ItemRef?
    /// The node that has the keyboard's focus: it lights up what it waits for and what waits for it, as hovering does.
    @FocusState private var focused: ItemRef?
    @Environment(\.textScale) private var textScale

    struct Metrics {
        let scale: CGFloat
        var title: CGFloat { 20 * scale }
        var nodeWidth: CGFloat { 196 * scale }
        var nodeHeight: CGFloat { 44 * scale }
        var columnGap: CGFloat { 40 * scale }
        var rowGap: CGFloat { 12 * scale }

        func x(_ column: Int) -> CGFloat { CGFloat(column) * (nodeWidth + columnGap) }
        func y(_ row: Int) -> CGFloat { title + CGFloat(row) * (nodeHeight + rowGap) }
    }

    var body: some View {
        let metrics = Metrics(scale: textScale)
        let width = metrics.x(graph.columns.count) - metrics.columnGap
        let height = metrics.y(max(graph.rows, 1)) - metrics.rowGap
        let lit = (hovered ?? focused).map { WorkMapLines.related(to: $0, by: graph.lines) }
        let into = Dictionary(grouping: graph.lines, by: \.after)
        ZStack(alignment: .topLeading) {
            ForEach(Array(graph.columns.enumerated()), id: \.offset) { index, column in
                if let title = column.title {
                    Text(title)
                        .font(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .offset(x: metrics.x(index))
                        .accessibilityHidden(true)
                }
            }
            Canvas { context, _ in
                for line in graph.lines {
                    draw(line, in: &context, metrics: metrics, lit: lit)
                }
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)
            ForEach(graph.nodes) { node in
                WorkMapNodeView(
                    item: node.item, order: order, content: content, mission: mission, missions: missions,
                    through: (into[node.item.ref] ?? []).compactMap { through($0) },
                    isDimmed: lit.map { !$0.contains(node.item.ref) } ?? false, width: metrics.nodeWidth, height: metrics.nodeHeight,
                    focus: $focused
                )
                .onHover { inside in
                    if inside {
                        hovered = node.item.ref
                    } else if hovered == node.item.ref {
                        hovered = nil
                    }
                }
                .offset(x: metrics.x(node.column), y: metrics.y(node.row))
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    /// What a dotted line into a card goes through, for its tooltip and VoiceOver: "After !4101, through !4102, which you hid".
    private func through(_ line: WorkMapLine) -> String? {
        guard case .through(let refs) = line.style else { return nil }
        return "After \(line.before.shortOrderLabel), " + OrderText.through(refs, hidden: hidden).lowercasedFirst
    }

    private func draw(_ line: WorkMapLine, in context: inout GraphicsContext, metrics: Metrics, lit: Set<ItemRef>?) {
        guard let from = graph.nodes.first(where: { $0.item.ref == line.before }),
              let to = graph.nodes.first(where: { $0.item.ref == line.after })
        else { return }
        let middle = { (row: Int) in metrics.y(row) + metrics.nodeHeight / 2 }
        var path = Path()
        var point = CGPoint(x: metrics.x(from.column) + metrics.nodeWidth, y: middle(from.row))
        path.move(to: point)
        func curve(to end: CGPoint) {
            let reach = max(12 * metrics.scale, (end.x - point.x) / 2)
            path.addCurve(
                to: end, control1: CGPoint(x: point.x + reach, y: point.y), control2: CGPoint(x: end.x - reach, y: end.y)
            )
            point = end
        }
        // Through each column it skips, along the row it keeps there.
        for (offset, row) in line.rows.enumerated() {
            let column = from.column + 1 + offset
            curve(to: CGPoint(x: metrics.x(column), y: middle(row)))
            point = CGPoint(x: metrics.x(column) + metrics.nodeWidth, y: middle(row))
            path.addLine(to: point)
        }
        let end = CGPoint(x: metrics.x(to.column), y: middle(to.row))
        curve(to: end)
        let isLit = lit.map { $0.contains(line.before) && $0.contains(line.after) }
        let color: Color = switch isLit {
        case nil: .secondary.opacity(0.6)
        case true?: .accentColor
        case false?: .secondary.opacity(0.18)
        }
        let width = 1.5 * metrics.scale
        let style = switch line.style {
        case .stacked: StrokeStyle(lineWidth: width, lineCap: .round)
        case .order: StrokeStyle(lineWidth: width, lineCap: .round, dash: [3 * metrics.scale, 3 * metrics.scale])
        case .through: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.5, 3.5 * metrics.scale])
        }
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

/// What hovering a node lights up.
enum WorkMapLines {
    /// The card, what comes before it and what comes after it, directly or through others, by these lines.
    static func related(to ref: ItemRef, by lines: [WorkMapLine]) -> Set<ItemRef> {
        func reach(_ step: (WorkMapLine) -> (from: ItemRef, to: ItemRef)) -> Set<ItemRef> {
            var reached: Set<ItemRef> = []
            var pending = [ref]
            while let current = pending.popLast() {
                for line in lines {
                    let (from, to) = step(line)
                    if from == current, reached.insert(to).inserted { pending.append(to) }
                }
            }
            return reached
        }
        return reach { ($0.after, $0.before) }.union(reach { ($0.before, $0.after) }).union([ref])
    }
}

/// The cards of All that no line joins, each a node, in rows as wide as the page.
struct WorkMapLoose: View {
    let items: [BoardItem]
    @ObservedObject var order: PullRequestOrder
    let content: WorkMapContent
    let missions: [OrderMission]

    @Environment(\.textScale) private var textScale

    var body: some View {
        let metrics = WorkMapGraphView.Metrics(scale: textScale)
        FlowLayout(spacing: metrics.columnGap / 2, lineSpacing: metrics.rowGap) {
            ForEach(items) { item in
                WorkMapNodeView(
                    item: item, order: order, content: content, mission: nil, missions: missions, through: [], isDimmed: false,
                    width: metrics.nodeWidth, height: metrics.nodeHeight
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - A node

/// A card's node: a pull request's mark, number and short title, with the work items of yours it's for, in its stage's
/// color; or a work item's type, ID, state and title, in the color of where it is: gray, outlined dashed, before it starts,
/// then In progress's, Merged's once resolved, and green once done. A click does what clicking its card does; its menu is
/// its card's, with Hide on Map.
struct WorkMapNodeView: View {
    let item: BoardItem
    @ObservedObject var order: PullRequestOrder
    let content: WorkMapContent
    /// The mission whose band it's in, By Mission; nil with All.
    let mission: OrderMission?
    let missions: [OrderMission]
    /// What the dotted lines into it go through: "After !4101, through !4102, which you hid".
    let through: [String]
    let isDimmed: Bool
    let width: CGFloat
    let height: CGFloat
    /// Which node has the keyboard's focus in its graph, which lights up what it's joined to; nil where nothing lights up.
    var focus: FocusState<ItemRef?>.Binding? = nil

    var body: some View {
        let card = cardContent
        let isSelected = content.isSelected(item.ref)
        let color = self.color
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let select = { content.select(item.ref) }
        face
            .padding(.horizontal, 8)
            .frame(width: width, height: height)
            .background(shape.fill(color.opacity(0.12)))
            .overlay(
                shape.strokeBorder(
                    isSelected ? Color.accentColor : color.opacity(0.4),
                    style: isToStart && !isSelected
                        ? StrokeStyle(lineWidth: 1, dash: [3, 2]) : StrokeStyle(lineWidth: isSelected ? 2 : 1)
                )
            )
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .onTapGesture(perform: select)
            // As a card on the Board takes the keyboard's focus, on a click and with Tab, whatever the Mac's keyboard
            // navigation: Return or Space shows its details.
            .focusable(interactions: .edit)
            .focused(on: focus, equals: item.ref)
            .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                select()
                return .handled
            }
            .opacity(isDimmed ? 0.45 : content.related.contains(item.ref) ? 0.55 : 1)
            .help(help(card))
            .contextMenu {
                if let card {
                    card.menu
                    Divider()
                }
                Button("Hide on Map") { order.hideOnMap(item.ref) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card?.label ?? item.ref.shortOrderLabel)
            .accessibilityValue(((card?.details ?? []) + through).joined(separator: ", "))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
            .missionActions(item.ref, context: card?.mission)
            .accessibilityActions {
                card?.actions
                Button("Hide on Map") { order.hideOnMap(item.ref) }
            }
    }

    private var cardContent: BoardCardContent? {
        switch item {
        case .pullRequest(let card): content.card(card)
        case .work(let task): content.work?.card(task)
        }
    }

    private var isToStart: Bool {
        if case .work(let task) = item { return task.column == .toStart }
        return false
    }

    private var color: Color {
        switch item {
        case .pullRequest(let card):
            card.stage.color
        case .work(let task):
            switch task.column {
            case .toStart: .secondary
            case .inProgress: PullRequestStage.inProgress.color
            case .merged: PullRequestStage.merged.color
            case .completed: .green
            }
        }
    }

    @ViewBuilder
    private var face: some View {
        switch item {
        case .pullRequest(let card):
            HStack(spacing: 7) {
                OrderNodeMark(card.step?.standing.marker ?? .none, stage: card.stage)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(card.ref.shortOrderLabel)
                            .font(size: 11, weight: .semibold)
                            .monospacedDigit()
                        if card.step?.isYours == true {
                            Image(systemName: "pencil")
                                .font(size: 9, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        if let work = content.workOf(card.ref) {
                            Text("· " + work)
                                .font(size: 10.5, weight: .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(order.describe(card.ref)?.title ?? card.step.flatMap(OrderText.capsule) ?? "")
                        .font(size: 10.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if let worker = order.sessionsWorking(on: card.ref).lazy.compactMap(order.describe).first {
                    Image(systemName: "waveform.path.ecg")
                        .font(size: 9, weight: .semibold)
                        .foregroundStyle(worker.color)
                        .accessibilityHidden(true)
                }
            }
        case .work(let task):
            let face = content.face(task)
            HStack(spacing: 7) {
                Image(systemName: face?.symbol ?? "checklist")
                    .font(size: 10, weight: .semibold)
                    .foregroundStyle(face?.color ?? .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(face?.label ?? task.ref.shortOrderLabel)
                            .font(size: 11, weight: .semibold)
                            .monospacedDigit()
                        if let state = face?.state {
                            Text("· " + state)
                                .font(size: 10.5, weight: .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(face?.title ?? "")
                        .font(size: 10.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Its tooltip: what it is, then what its card says of it, where it waits elsewhere, and what dotted lines into it go
    /// through.
    private func help(_ card: BoardCardContent?) -> String {
        var lines = [card?.label ?? item.ref.fullOrderLabel] + (card?.details ?? [])
        if case .pullRequest(let boardCard) = item, let step = boardCard.step,
           let mission = mission ?? boardCard.mission.flatMap({ key in missions.first { $0.key == key } }),
           let elsewhere = OrderText.elsewhere(step, in: mission, missions: missions, names: order.names) {
            lines.append(elsewhere)
        }
        return (lines + through).joined(separator: "\n")
    }
}

// MARK: - Hidden cards

/// A band's cards you hid, or All's, as a quiet button, "2 hidden", whose popover lists them, each with Show, and Show All.
struct WorkMapHiddenButton: View {
    let hidden: [BoardItem]
    @ObservedObject var order: PullRequestOrder
    /// What each is called: "!4102" and its title.
    let name: (BoardItem) -> (label: String, title: String)

    @LocalState private var isShown = false

    var body: some View {
        Button {
            isShown = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "eye.slash")
                Text(WorkMapText.hidden(hidden.count))
            }
            .font(size: 11.5, weight: .medium)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Tab reaches it, whatever the Mac's keyboard navigation, as it's the only way back to the cards it hides there.
        .focusable(interactions: .edit)
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            isShown = true
            return .handled
        }
        .help(WorkMapText.hiddenHelp)
        .accessibilityLabel(WorkMapText.hidden(hidden.count))
        .accessibilityHint(WorkMapText.hiddenHelp)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hidden on the Map")
                    .font(size: 13, weight: .semibold)
                ForEach(hidden) { item in
                    let named = name(item)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(named.label)
                            .font(size: 12, weight: .semibold)
                            .monospacedDigit()
                        Text(named.title)
                            .font(size: 12)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Button("Show") { order.showOnMap([item.ref]) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Show \(named.label)")
                    }
                }
                if hidden.count > 1 {
                    Divider()
                    Button("Show All") {
                        order.showOnMap(hidden.map(\.ref))
                        isShown = false
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
        }
    }
}

// MARK: - Words

/// What My Work's Map says.
package enum WorkMapText {
    /// With nothing to draw.
    static let nothingYet = "Nothing to draw yet: your pull requests show here as they come, and, with + Sprint Tasks, your sprint work."

    /// A band whose cards you all hid.
    static let allHidden = "You hid all its cards on the Map."

    /// All's last part's title: the cards no line joins.
    static let notConnected = "Not connected"

    static let notConnectedHelp = "No line joins these to other cards: nothing BriefBar knows holds them, and they hold nothing"

    /// "1 hidden", "3 hidden".
    static func hidden(_ count: Int) -> String {
        "\(count) hidden"
    }

    static let hiddenHelp = "The cards you hid on the Map, as they're not your focus now. They stay on the Board"

    /// The Map's tooltip in My Work's header.
    package static let viewHelp = "Board: a column for each stage, a lane for each mission. Map: what holds what, as a graph"

    /// By Mission | All's tooltip.
    package static let groupingHelp =
        "By Mission: a graph for each mission, as the Board's lanes. All: a graph for each set of cards lines join, whatever their missions"
}

private extension View {
    /// Binds its focus to a node's, where there's one to bind to.
    @ViewBuilder
    func focused(on focus: FocusState<ItemRef?>.Binding?, equals ref: ItemRef) -> some View {
        if let focus { self.focused(focus, equals: ref) } else { self }
    }
}

private extension String {
    /// With its first letter lowercased: "through !4102".
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
}

// MARK: - Switches

/// My Work's Board | Map, in its header, remembered.
package struct MyWorkViewPicker: View {
    @ObservedObject var order: PullRequestOrder
    /// The view a picture shows; nil for the one you chose.
    let shown: MyWorkView?

    package init(order: PullRequestOrder, shown: MyWorkView? = nil) {
        self.order = order
        self.shown = shown
    }

    package var body: some View {
        SegmentedPicker("My Work View", selection: Binding(get: { shown ?? order.myWorkView }, set: { order.setMyWorkView($0) }), segments: [
            .init(MyWorkView.board, title: MyWorkView.board.title, systemImage: "rectangle.split.3x1"),
            .init(MyWorkView.map, title: MyWorkView.map.title, systemImage: "map"),
        ])
        .fixedSize()
        .help(WorkMapText.viewHelp)
    }
}

/// The Map's By Mission | All, in My Work's header while it shows the Map, remembered.
package struct MapGroupingPicker: View {
    @ObservedObject var order: PullRequestOrder
    /// The grouping a picture shows; nil for the one you chose.
    let shown: WorkMapGrouping?

    package init(order: PullRequestOrder, shown: WorkMapGrouping? = nil) {
        self.order = order
        self.shown = shown
    }

    package var body: some View {
        SegmentedPicker("Map Grouping", selection: Binding(get: { shown ?? order.mapGrouping }, set: { order.setMapGrouping($0) }), segments: [
            .init(WorkMapGrouping.byMission, title: WorkMapGrouping.byMission.title, systemImage: "rectangle.stack"),
            .init(WorkMapGrouping.all, title: WorkMapGrouping.all.title, systemImage: "point.3.connected.trianglepath.dotted"),
        ])
        .fixedSize()
        .help(WorkMapText.groupingHelp)
    }
}
