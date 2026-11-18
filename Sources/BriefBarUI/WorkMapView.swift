import AppKit
import BriefBarCore
import SwiftUI

// My Work's Map (`WorkMap`): By Mission, a band for each lane of the Board, with its header as the Board has it, its cards and
// the steps added there, and, dimmed, what they're joined to in other bands; All, one canvas: a graph for each set of cards and
// steps lines join, their columns lined up, then those no line joins, in a grid. Each is a node: a card's click shows its
// details, as the Board's card does, and a step's circle marks it done; a right-click has the card's menu with Waits For, Add
// Step After… and Hide on Map, and a step's Rename…, Mark Done and Delete Step. A drag from one node onto another draws a
// line: the other waits for it. A click on a line selects it, to take it away. Hovering a node lights up what it waits for
// and what waits for it. ✨ Ask Copilot, on a band or a graph, asks its session, a fork of it or a new one to work out what
// waits for what there and tell BriefBar, which draws what it tells as it hears it. Only the Map changes for any of it.
// Where the page is too narrow for a graph's columns, as with a card's details beside it, they fold into tiers, one under
// the other, and the lines from one tier to the next wrap round, down and back. Everything scales with the text size of
// windows' pages.

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
    /// Asks a session what waits for what on a band or a graph, as ✨ Ask Copilot does: the page writes the prompt, with its
    /// links, sends it or copies it, and says what it did. Nil where no session can be asked.
    package var ask: ((WorkMapQuestion, WorkMapAsk) async -> String)?
    /// Whether ✨ Ask Copilot offers the missions' sessions, as Send Work to Copilot can send them prompts; else it only copies.
    package var asksSessions: Bool

    package init(
        card: @escaping (BoardCard) -> BoardCardContent?, work: BoardWorkContent?, face: @escaping (BoardTask) -> WorkMapFace?,
        workOf: @escaping (ItemRef) -> String?, place: @escaping (ItemRef) -> String?,
        laneTitle: @escaping (BoardLane.Kind) -> String, isSelected: @escaping (ItemRef) -> Bool,
        select: @escaping (ItemRef) -> Void, related: Set<ItemRef> = [], showBoard: @escaping () -> Void,
        ask: ((WorkMapQuestion, WorkMapAsk) async -> String)? = nil, asksSessions: Bool = false
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
        self.ask = ask
        self.asksSessions = asksSessions
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

/// What ✨ Ask Copilot asks a session about: a band, or a graph of All, as the Map shows it.
package struct WorkMapQuestion {
    /// What it's about: a mission's name, or the names of the lanes a graph of All is in.
    package var title: String
    /// Its cards and steps, as they show.
    package var items: [WorkMapItem]
    /// What each waits for right before it, as the Map has it: on it or not.
    package var waits: [MapNodeID: [MapNodeID]]
    /// The steps the Map has, for their names.
    package var steps: [MapStep]
}

/// Whom ✨ Ask Copilot asks.
package enum WorkMapAsk: Equatable {
    /// A session of the mission.
    case session(ItemRef)
    /// A fork of it, so that what it does goes on as it was.
    case fork(ItemRef)
    /// None: the prompt is copied, for a new session.
    case copy
}

/// A step's name being asked for: to add one, after and before what it was added between, or to rename one.
struct StepNaming {
    enum Kind {
        case add(home: LaneOrderKey?, after: MapNodeID?, before: MapNodeID?)
        case rename(UUID)
    }

    var kind: Kind
    /// "Add a Step After !4105".
    var title: String
    var name = ""
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
    @Environment(\.textScale) private var textScale
    /// Who shows the missions, for Apple Intelligence to name them while they're on screen.
    @LocalState private var viewer = MissionsViewer()
    /// What's in the page's sight now, By Mission and with All: each band and graph, with its missions. Apple Intelligence
    /// names only the missions of those, as one mission can be in several of All's graphs.
    @LocalState private var inSight: [WorkMapGrouping: [String: Set<MissionKey>]] = [:]
    /// A step's name being asked for.
    @LocalState private var naming: StepNaming?
    /// What ✨ Ask Copilot did last, for each band and graph.
    @LocalState private var asked: [String: String] = [:]
    /// How wide the page is, for the graphs to fold to it and the grids to fill it.
    @LocalState private var width: CGFloat = 0
    /// The node that has the keyboard's focus, in any band or graph: one a search found takes it.
    @FocusState private var focused: MapNodeID?

    package init(map: WorkMap, grouping: WorkMapGrouping, missions: [OrderMission], order: PullRequestOrder, content: WorkMapContent) {
        self.map = map
        self.grouping = grouping
        self.missions = missions
        self.order = order
        self.content = content
    }

    package var body: some View {
        // Apple Intelligence names only the missions on screen, as on the Board.
        let seen = Set((inSight[grouping] ?? [:]).values.flatMap { $0 })
        let onScreen = missions.map(\.key).filter(seen.contains)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 18) {
                topLines
                switch grouping {
                case .byMission:
                    if map.bands.isEmpty {
                        nothingYet
                    }
                    ForEach(map.bands) { band in
                        bandView(band)
                            .id(band.lane.kind)
                            .onSightChange { see("band \(band.lane.kind)", band.lane.mission.map { [$0] } ?? [], $0) }
                    }
                case .all:
                    all
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
        .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: Binding(get: { naming?.name ?? "" }, set: { naming?.name = $0 }))
            Button(naming.map { if case .rename = $0.kind { "Rename" } else { "Add" } } ?? "Add") { name() }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            if case .add? = naming?.kind {
                Text(WorkMapText.stepMessage)
            }
        }
    }

    /// The window's page this is, when it's on one, for Pull Request Order to know when it's on screen.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestOrder.page(section, window: window)
    }

    private func see(_ id: String, _ keys: Set<MissionKey>, _ isInSight: Bool) {
        if isInSight { inSight[grouping, default: [:]][id] = keys } else { inSight[grouping]?[id] = nil }
    }

    private var metrics: WorkMapMetrics {
        WorkMapMetrics(scale: textScale)
    }

    /// How wide a canvas can be, inside its card's padding, for its graphs to fold and its grid to fit; nil until the page
    /// knows its width.
    private var canvasWidth: CGFloat? {
        width > 0 ? max(width - 24, 0) : nil
    }

    /// What you changed last, of the Map and of missions no band shows; why BriefBar didn't make a change; and, until you or
    /// a session first change the Map, how to.
    @ViewBuilder
    private var topLines: some View {
        let shown = Set(map.bands.compactMap(\.lane.mission))
        let showsOrders = grouping == .all || order.said.contains(where: { OrderUndoLine.shows($0, about: nil, in: nil, outside: shown) })
        if showsOrders || order.mapUndo != nil || order.mapEdits.isEmpty && order.mapTold.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if showsOrders {
                    OrderUndoLine(order: order, outside: grouping == .all ? nil : shown)
                }
                WorkMapUndoLine(order: order)
                if order.mapEdits.isEmpty, order.mapTold.isEmpty, order.mapUndo == nil, !map.bands.isEmpty {
                    Label(WorkMapText.tip, systemImage: "hand.draw")
                        .font(size: 12)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var nothingYet: some View {
        Text(WorkMapText.nothingYet)
            .font(size: 12.5)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: Editing

    /// What a canvas does as you edit it: a band's, whose steps go in it, or All's, where they go in their card's band.
    private func editor(home: LaneOrderKey?) -> WorkMapEditor {
        WorkMapEditor(
            map: map, order: order, content: content, home: home, askName: { naming = $0 },
            showBand: { kind in
                if let key = kind.missionKey { order.revealOnBoard(key) }
            }
        )
    }

    /// Adds or renames the step whose name was asked for.
    private func name() {
        guard let naming else { return }
        self.naming = nil
        let editor = editor(home: nil)
        switch naming.kind {
        case .add(let home, let after, let before):
            guard let name = MapEdits.name(naming.name) else { return }
            order.addMapStep(
                named: name, home: home, after: after, before: before,
                undo: after.map { "You added the step “\(name)” after \(editor.label($0))." } ?? "You added the step “\(name)”."
            )
        case .rename(let id):
            guard let name = MapEdits.name(naming.name) else { return }
            order.renameMapStep(id, to: name, undo: "You renamed the step “\(editor.label(.step(id)))” to “\(name)”.")
        }
    }

    // MARK: By Mission

    private func bandView(_ band: WorkMap.Band) -> some View {
        let mission = band.lane.mission.flatMap { key in missions.first { $0.key == key } }
        let id = "band \(band.lane.kind)"
        return VStack(alignment: .leading, spacing: 6) {
            header(band, mission: mission)
            if let said = asked[id] {
                Label(said, systemImage: "sparkles")
                    .font(size: 11.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if let graph = band.graph {
                WorkMapCanvas(
                    blocks: [WorkMapCanvas.Block(id: id, graph: graph)], columns: graph.columns, grid: [], width: canvasWidth,
                    editor: editor(home: band.key), order: order, focus: $focused
                )
                .padding(12)
                .scrollingSideways()
            } else if band.count > WorkMap.mostCards {
                tooMany(band.count)
                stepsGrid(shownSteps { map.band(of: $0) == band.lane.kind }, home: band.key)
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
    /// mission. Then + Step, ✨ Ask Copilot and its hidden cards and steps.
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if band.lane.mission != nil {
                    MissionNextStepsLine(lane: band.lane, order: order, select: content.select)
                }
                Spacer(minLength: 0)
                addStepButton(home: band.key)
                if let ask = content.ask, let graph = band.graph {
                    WorkMapAskMenu(
                        question: question(title: content.laneTitle(band.lane.kind), graph: graph),
                        sessions: content.asksSessions ? mission?.sessions ?? [] : [],
                        order: order, ask: ask
                    ) { asked["band \(band.lane.kind)"] = $0 }
                }
                if !band.hidden.isEmpty {
                    WorkMapHiddenButton(hidden: band.hidden, order: order, editor: editor(home: band.key))
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func addStepButton(home: LaneOrderKey?) -> some View {
        Button {
            naming = StepNaming(kind: .add(home: home, after: nil, before: nil), title: "Add a Step")
        } label: {
            WorkMapControlLabel(title: "Step", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .help(WorkMapText.addStepHelp)
        .accessibilityLabel("Add a Step")
    }

    /// The repositories its pull requests are in, the one with the most first: "payments-api and shop-web".
    private func place(of mission: OrderMission) -> String? {
        OrderText.places(mission.steps(of: [.pullRequest]).compactMap { content.place($0.ref) })
    }

    /// What ✨ Ask Copilot asks about a graph.
    private func question(title: String, graph: WorkMapGraph) -> WorkMapQuestion {
        let items = graph.nodes.map(\.item)
        let waits = Dictionary(items.map { ($0.id, map.waitsFor($0.id).map(\.node)) }, uniquingKeysWith: { first, _ in first })
        return WorkMapQuestion(title: title, items: items, waits: waits, steps: order.mapState.steps)
    }

    // MARK: All

    @ViewBuilder
    private var all: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            addStepButton(home: nil)
            if !map.hidden.isEmpty {
                WorkMapHiddenButton(hidden: map.hidden, order: order, editor: editor(home: nil))
            }
        }
        .padding(.horizontal, 4)
        if map.groups.isEmpty, map.loose.isEmpty {
            nothingYet
        }
        ForEach(map.groups.filter { $0.graph == nil }) { group in
            VStack(alignment: .leading, spacing: 4) {
                Text(title(of: group))
                    .font(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                tooMany(group.items.count)
                stepsGrid(group.items.filter { $0.step != nil }, home: nil)
            }
        }
        let drawn = map.groups.filter { $0.graph != nil }
        if !drawn.isEmpty || !map.loose.isEmpty {
            allCanvas(drawn)
        }
    }

    /// All's graphs and grid, on one canvas, with where each is in the page's flow, for a mission or a card to scroll to, and
    /// for what's in sight.
    private func allCanvas(_ drawn: [WorkMap.Group]) -> some View {
        let blocks: [WorkMapCanvas.Block] = drawn.compactMap(block(of:))
        let said: (String, String) -> Void = { id, words in asked[id] = words }
        let canvas = WorkMapCanvas(
            blocks: blocks, columns: map.columns, grid: map.loose, width: canvasWidth, gridColumns: 4, editor: editor(home: nil),
            order: order, focus: $focused, ask: content.ask.map { ($0, said) }
        )
        let geometry = canvas.geometry(metrics: metrics)
        return canvas
            .padding(12)
            .scrollingSideways()
            .background(alignment: .topLeading) {
                WorkMapAnchors(geometry, offset: 12) { id, isInSight in
                    let group = drawn.first { "group \($0.id)" == id }
                    see(id, Set(group?.lanes.compactMap(\.missionKey) ?? []), isInSight)
                }
            }
    }

    /// A graph of All, on its canvas.
    private func block(of group: WorkMap.Group) -> WorkMapCanvas.Block? {
        guard let graph = group.graph else { return nil }
        let title = title(of: group)
        let id = "group \(group.id)"
        return WorkMapCanvas.Block(
            id: id, title: title, question: question(title: title, graph: graph), sessions: sessions(of: group), said: asked[id],
            graph: graph
        )
    }

    private func title(of group: WorkMap.Group) -> String {
        group.lanes.map(content.laneTitle).joined(separator: " · ")
    }

    /// The sessions of a graph's missions, each once, the first mission's first.
    private func sessions(of group: WorkMap.Group) -> [ItemRef] {
        guard content.asksSessions else { return [] }
        var seen: Set<ItemRef> = []
        return group.lanes.compactMap(\.missionKey).flatMap { key in missions.first { $0.key == key }?.sessions ?? [] }
            .filter { seen.insert($0).inserted }
    }

    // MARK: Pieces

    /// The steps the Map shows, but those you hid, in its order, of those that `in` takes.
    private func shownSteps(in kept: (MapNodeID) -> Bool) -> [WorkMapItem] {
        map.everything.filter { $0.step != nil && !order.mapHidden.contains($0.id) && kept($0.id) }
    }

    /// The steps of a band or a graph of All too big to draw, which the Board doesn't show, as a grid of their nodes, so
    /// that they can still be done, renamed, joined, hidden or deleted.
    @ViewBuilder
    private func stepsGrid(_ steps: [WorkMapItem], home: LaneOrderKey?) -> some View {
        if !steps.isEmpty {
            WorkMapCanvas(
                blocks: [], columns: [], grid: steps, width: canvasWidth, gridColumns: 2, gridTitle: WorkMapText.stepsTitle,
                editor: editor(home: home), order: order, focus: $focused
            )
            .padding(12)
            .scrollingSideways()
        }
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

    // MARK: Showing what's asked

    /// A mission a pull request's details asked My Work to show: its band, By Mission; with All, the graph that has it, or the
    /// grid, where only cards no line joins have it.
    private func reveal(_ key: MissionKey?, with proxy: ScrollViewProxy) {
        guard let key else { return }
        let target: String? = switch grouping {
        case .byMission:
            map.bands.first { $0.lane.mission == key }.map { "band \($0.lane.kind)" }
        case .all:
            map.groups.first { $0.graph != nil && $0.lanes.contains(.mission(key)) }.map { "group \($0.id)" }
                ?? (map.loose.contains { map.band(of: $0.id) == .mission(key) } ? WorkMapText.notConnected : nil)
        }
        DispatchQueue.main.async {
            if let target {
                withAnimation(.easeOut(duration: 0.25)) {
                    if grouping == .byMission, let band = map.bands.first(where: { $0.lane.mission == key }) {
                        proxy.scrollTo(band.lane.kind, anchor: .top)
                    } else {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
            order.revealed = nil
        }
    }

    /// A card the page asked My Work to show, as a search's Return does: its band, or the graph that has it, or All's grid;
    /// then its node takes the keyboard's focus, for Return or Space to show its details.
    private func reveal(card ref: ItemRef?, with proxy: ScrollViewProxy) {
        guard let ref else { return }
        let node = MapNodeID.card(ref)
        let band = map.bands.first { band in band.graph?.nodes.contains { $0.id == node && $0.elsewhere == nil } == true }
        let group = map.groups.first { $0.graph != nil && $0.items.contains { $0.id == node } }
        let isLoose = map.loose.contains { $0.id == node }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                switch grouping {
                case .byMission:
                    if let band { proxy.scrollTo(band.lane.kind, anchor: .top) }
                case .all:
                    if let group {
                        proxy.scrollTo("group \(group.id)", anchor: .top)
                    } else if isLoose {
                        proxy.scrollTo(WorkMapText.notConnected, anchor: .top)
                    }
                }
            }
            order.revealedCard = nil
            let shows = grouping == .byMission ? band != nil : group != nil || isLoose
            guard shows else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = node }
        }
    }
}

private extension BoardLane.Kind {
    /// The mission it's a lane of, for one.
    var missionKey: MissionKey? {
        if case .mission(let key) = self { return key }
        return nil
    }
}

private extension View {
    /// In a card that scrolls sideways when it's wider than the page.
    func scrollingSideways() -> some View {
        ScrollView(.horizontal) { self }
            .scrollBounceBehavior(.basedOnSize)
            .background(GlassCard(cornerRadius: 18))
    }
}

// MARK: - Editing

/// What a canvas of the Map does as you edit it, for its nodes, lines and menus.
@MainActor
struct WorkMapEditor {
    let map: WorkMap
    let order: PullRequestOrder
    let content: WorkMapContent
    /// The key of the band it is, By Mission: the steps added there go in it. Nil with All, where they go in the band of
    /// what they're added after.
    let home: LaneOrderKey?
    /// Asks for a step's name, to add one or rename one.
    let askName: (StepNaming) -> Void
    /// Shows a band, for one of its cards or steps dimmed in another.
    let showBand: (BoardLane.Kind) -> Void

    /// What a card or step is called in menus and lines: "!4102", "Task 5104", a step's name.
    func label(_ node: MapNodeID) -> String {
        switch map.item(node) {
        case .card(.work(let task))?: content.face(task)?.label ?? task.ref.shortOrderLabel
        case .step(let step)?: step.name
        default: node.ref?.shortOrderLabel ?? "A step"
        }
    }

    /// The key of the band a step added after or before one goes in.
    func home(near node: MapNodeID) -> LaneOrderKey? {
        home ?? map.band(of: node).flatMap { kind in map.bands.first { $0.lane.kind == kind }?.key }
    }

    func isHidden(_ node: MapNodeID) -> Bool {
        order.mapHidden.contains(node)
    }

    /// What one could wait for, in its menu: what's on the Map and still to do, but what it waits for, and what waits for it,
    /// which would close a loop; those of its band first.
    func candidates(for node: MapNodeID) -> (near: [MapNodeID], far: [MapNodeID]) {
        let current = Set(map.waitsFor(node).map(\.node))
        let band = map.band(of: node)
        let others = map.everything.filter { item in
            item.id != node && !item.isDone && !current.contains(item.id) && !isHidden(item.id)
                && !map.wouldLoop(before: item.id, after: node)
        }.map(\.id)
        return (others.filter { map.band(of: $0) == band }, others.filter { map.band(of: $0) != band })
    }

    /// Whether `later` can wait for `earlier`, as a drag would draw it, or why not.
    func verdict(_ earlier: MapNodeID, before later: MapNodeID) -> (allowed: Bool, words: String) {
        let (first, then) = (label(earlier), label(later))
        if earlier == later { return (false, "") }
        if map.waitsFor(later).contains(where: { $0.node == earlier }) { return (false, "\(then) waits for \(first) already") }
        if map.wouldLoop(before: earlier, after: later) { return (false, "\(first) waits for \(then) already") }
        if map.item(later)?.isDone == true { return (false, "\(then) is done: nothing holds it now") }
        return (true, "\(then) waits for \(first)")
    }

    func wait(_ later: MapNodeID, for earlier: MapNodeID) {
        order.setMapLine(from: earlier, to: later, on: true, undo: "You drew a line: \(label(later)) waits for \(label(earlier)).")
    }

    func stopWaiting(_ later: MapNodeID, for earlier: MapNodeID) {
        order.setMapLine(
            from: earlier, to: later, on: false, undo: "You took a line away: \(label(later)) no longer waits for \(label(earlier))."
        )
    }

    func hide(_ node: MapNodeID) {
        order.hideOnMap(node, undo: "You hid \(label(node)) on the Map.")
    }

    func addStep(after node: MapNodeID) {
        askName(StepNaming(kind: .add(home: home(near: node), after: node, before: nil), title: "Add a Step After \(label(node))"))
    }

    func rename(_ step: MapStep) {
        askName(StepNaming(kind: .rename(step.id), title: "Rename the Step", name: step.name))
    }

    func toggle(_ step: MapStep) {
        order.setMapStep(
            step.id, done: !step.isDone, undo: "You marked the step “\(step.name)” \(step.isDone ? "not done" : "done")."
        )
    }

    func delete(_ step: MapStep) {
        order.deleteMapStep(step.id, undo: "You deleted the step “\(step.name)”.")
    }

    /// Who said a line, for what it says of it: "You said so", "‘Cart’ said so".
    func who(_ author: MapAuthor) -> String {
        switch author {
        case .you: "You said so"
        case .session(let ref?): order.describe(ref).map { "‘\($0.title)’ said so" } ?? "A session said so"
        case .session(nil): "An agent said so"
        }
    }

    /// What a line says, for its tooltip, VoiceOver and when it's selected: "API tests waits for !4105 · You said so".
    func words(_ line: WorkMapLine) -> String {
        let (first, then) = (label(line.before), label(line.after))
        return switch line.style {
        case .stacked: "\(then) is stacked on \(first)"
        case .order: "\(then) comes after \(first) in its order"
        case .said(let author): "\(then) waits for \(first) · \(who(author))"
        case .through(let nodes):
            "\(then) waits for \(first), " + OrderText.through(nodes.map(label), hidden: nodes.filter(isHidden).count).lowercasedFirst
        }
    }
}

// MARK: - A canvas

/// How big things are on the Map, at a text size.
struct WorkMapMetrics {
    let scale: CGFloat
    var titleRow: CGFloat { 20 * scale }
    var nodeWidth: CGFloat { 196 * scale }
    var nodeHeight: CGFloat { 44 * scale }
    var columnGap: CGFloat { 40 * scale }
    var rowGap: CGFloat { 12 * scale }
    var blockTitle: CGFloat { 26 * scale }
    var blockGap: CGFloat { 26 * scale }
    /// Between two tiers of a fold: over and under the lines that wrap round through it.
    var foldGap: CGFloat { 14 * scale }
    /// How far past a tier's end, or before the next's start, a line that wraps round turns: its first lane.
    var wrapReach: CGFloat { 10 * scale }
    /// Between the lanes of lines that wrap round together, as far apart as `lanesAcross` lets them be.
    var laneGap: CGFloat { 3 * scale }
    var lanesAcross: CGFloat { 24 * scale }
    /// How round a wrapping line's corners are.
    var corner: CGFloat { 6 * scale }

    func x(_ column: Int) -> CGFloat { CGFloat(column) * (nodeWidth + columnGap) }
    func y(_ row: Int) -> CGFloat { CGFloat(row) * (nodeHeight + rowGap) }

    /// Between the lanes of so many lines that wrap round together.
    func laneGap(of lanes: Int) -> CGFloat {
        lanes > 1 ? min(laneGap, lanesAcross / CGFloat(lanes - 1)) : 0
    }

    /// The room a fold leaves on each side for so many lines wrapping round together: none for none.
    func margin(for lanes: Int) -> CGFloat {
        lanes > 0 ? wrapReach + laneGap(of: lanes) * CGFloat(lanes - 1) + 4 * scale : 0
    }
}

/// A line of a canvas, by its ends.
struct WorkMapLineID: Hashable {
    var before: MapNodeID
    var after: MapNodeID
}

/// Graphs of the Map, one under the other, their columns lined up, and a grid of what no line joins, on one surface, so that
/// a drag from any node can reach any other: a band's graph, By Mission, or All's graphs and grid. Its nodes, lines and titles
/// go where it works them out (`Geometry`), its graphs' columns folding into tiers where they don't all fit across the page.
struct WorkMapCanvas: View {
    struct Block: Identifiable {
        var id: String
        /// What it's about, over it, with All; nil By Mission, where the band's header says it.
        var title: String? = nil
        /// What its ✨ Ask Copilot asks, with All.
        var question: WorkMapQuestion? = nil
        /// The sessions ✨ Ask Copilot offers.
        var sessions: [ItemRef] = []
        /// What ✨ Ask Copilot did last for it.
        var said: String? = nil
        var graph: WorkMapGraph
    }

    /// Where everything goes on it.
    struct Geometry {
        struct Placed: Identifiable {
            var item: WorkMapItem
            var frame: CGRect
            var elsewhere: BoardLane.Kind?
            var id: MapNodeID { item.id }
        }

        struct Drawn {
            var line: WorkMapLine
            var path: Path
            var end: CGPoint
            var middle: CGPoint
            var id: WorkMapLineID { WorkMapLineID(before: line.before, after: line.after) }
        }

        struct Placement {
            var id: String
            var titleTop: CGFloat?
            var top: CGFloat
            var height: CGFloat
        }

        /// A column's title: over the first tier, and over each later tier of a fold that has a column with one.
        struct Title {
            var text: String
            var frame: CGRect
        }

        var nodes: [Placed] = []
        var lines: [Drawn] = []
        var blocks: [Placement] = []
        var titles: [Title] = []
        /// Where the grid's title is, with one.
        var gridTop: CGFloat?
        var size: CGSize = .zero
        var frames: [MapNodeID: CGRect] = [:]
        /// How the graphs' columns fold to the page's width.
        var fold = WorkMapFold(columns: 0)
        /// Where the columns and the grid start, past the room a fold leaves for the lines that wrap round it.
        var inset: CGFloat = 0
    }

    let blocks: [Block]
    let columns: [WorkMapColumn]
    let grid: [WorkMapItem]
    /// How wide the page lets it be, inside its card: its graphs fold to fit, and its grid has as many columns as fit. Nil
    /// until the page knows.
    let width: CGFloat?
    /// How many columns the grid has until the page knows its width.
    var gridColumns = 4
    /// The grid's title: Not connected, with All.
    var gridTitle: String = WorkMapText.notConnected
    let editor: WorkMapEditor
    @ObservedObject var order: PullRequestOrder
    var focus: FocusState<MapNodeID?>.Binding
    /// ✨ Ask Copilot, for All's graphs: what asks, and where to say what it did.
    var ask: ((WorkMapQuestion, WorkMapAsk) async -> String, (String, String) -> Void)? = nil

    @LocalState private var hovered: MapNodeID?
    /// A line being drawn, from a node to the pointer.
    @LocalState private var drawing: (from: MapNodeID, to: CGPoint)?
    @LocalState private var hoveredLine: WorkMapLineID?
    @LocalState private var selectedLine: WorkMapLineID?
    @Environment(\.textScale) private var textScale

    private static let space = "WorkMapCanvas"

    func geometry(metrics m: WorkMapMetrics) -> Geometry {
        Geometry(blocks: blocks, columns: columns, grid: grid, width: width, gridColumns: gridColumns, metrics: m)
    }

    var body: some View {
        let m = WorkMapMetrics(scale: textScale)
        let geometry = geometry(metrics: m)
        let lines = geometry.lines.map(\.line)
        let lit = (drawing?.from ?? hovered ?? focus.wrappedValue).map { WorkMapLines.related(to: $0, by: lines) }
        let into = Dictionary(grouping: lines, by: \.after)
        let target = drawing.flatMap { drawing in node(at: drawing.to, in: geometry).flatMap { $0 == drawing.from ? nil : $0 } }
        let across = geometry.size.width - geometry.inset
        CanvasLayout(size: geometry.size) {
            ForEach(Array(geometry.titles.enumerated()), id: \.offset) { _, title in
                Text(title.text)
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .at(title.frame)
                    .accessibilityHidden(true)
            }
            linesLayer(geometry, lit: lit, metrics: m)
                .at(CGRect(origin: .zero, size: geometry.size))
            ForEach(geometry.blocks, id: \.id) { placed in
                if let block = blocks.first(where: { $0.id == placed.id }), let title = block.title, let top = placed.titleTop {
                    blockTitle(block, title: title)
                        .at(CGRect(x: geometry.inset, y: top, width: across, height: m.blockTitle))
                }
            }
            if let top = geometry.gridTop {
                Text(gridTitle)
                    .font(size: 13, weight: .semibold)
                    .help(gridTitle == WorkMapText.notConnected ? WorkMapText.notConnectedHelp : WorkMapText.stepsHelp)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .at(CGRect(x: geometry.inset, y: top, width: across, height: m.blockTitle))
            }
            ForEach(geometry.nodes) { placed in
                nodeView(placed, through: (into[placed.id] ?? []).compactMap(through), lit: lit, target: target, geometry: geometry)
                    .at(placed.frame)
            }
            drawingLayer(geometry, target: target, metrics: m)
                .at(CGRect(origin: .zero, size: geometry.size))
            if let id = selectedLine, let drawn = geometry.lines.first(where: { $0.id == id }) {
                selectedLineCard(drawn)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .at(CGRect(x: drawn.middle.x - 170 * m.scale, y: drawn.middle.y - 16 * m.scale, width: 340 * m.scale, height: 32 * m.scale))
            }
        }
        .coordinateSpace(.named(Self.space))
        .onKeyPress(.escape) {
            guard selectedLine != nil else { return .ignored }
            selectedLine = nil
            return .handled
        }
        .accessibilityElement(children: .contain)
    }

    /// The node under a point, if any.
    private func node(at point: CGPoint, in geometry: Geometry) -> MapNodeID? {
        geometry.nodes.first { $0.frame.contains(point) }?.id
    }

    /// The line a point is on, give or take a few points.
    private func line(at point: CGPoint, in geometry: Geometry) -> WorkMapLineID? {
        let width = 9 * textScale
        return geometry.lines.first { $0.path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round)).contains(point) }?.id
    }

    /// What a dotted line into a node goes through, for its tooltip and VoiceOver.
    private func through(_ line: WorkMapLine) -> String? {
        guard case .through = line.style else { return nil }
        return editor.words(line)
    }

    // MARK: Lines

    private func linesLayer(_ geometry: Geometry, lit: Set<MapNodeID>?, metrics m: WorkMapMetrics) -> some View {
        Canvas { context, _ in
            for drawn in geometry.lines {
                let isPicked = drawn.id == selectedLine || drawn.id == hoveredLine
                let isLit = lit.map { $0.contains(drawn.line.before) && $0.contains(drawn.line.after) }
                let color: Color = if isPicked || isLit == true {
                    .accentColor
                } else if isLit == false {
                    .secondary.opacity(0.18)
                } else {
                    .secondary.opacity(0.6)
                }
                let width = (isPicked ? 2.5 : 1.5) * m.scale
                let style = switch drawn.line.style {
                case .stacked, .said: StrokeStyle(lineWidth: width, lineCap: .round)
                case .order: StrokeStyle(lineWidth: width, lineCap: .round, dash: [3 * m.scale, 3 * m.scale])
                case .through: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.5, 3.5 * m.scale])
                }
                context.stroke(drawn.path, with: .color(color), style: style)
                context.fill(Self.arrowhead(at: drawn.end, size: 4.5 * m.scale), with: .color(color))
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
            switch phase {
            case .active(let point): hoveredLine = line(at: point, in: geometry)
            case .ended: hoveredLine = nil
            }
        }
        .onTapGesture(coordinateSpace: .named(Self.space)) { point in
            selectedLine = line(at: point, in: geometry)
        }
        .contextMenu {
            if let id = hoveredLine ?? selectedLine, let drawn = geometry.lines.first(where: { $0.id == id }) {
                lineMenu(drawn.line)
                Divider()
            }
            Button("Add a Step…") {
                editor.askName(StepNaming(kind: .add(home: editor.home, after: nil, before: nil), title: "Add a Step"))
            }
        }
        .help(hoveredLine.flatMap { id in geometry.lines.first { $0.id == id } }.map { editor.words($0.line) } ?? "")
        .accessibilityHidden(true)
    }

    /// A line's menu: Take Away This Line, or, for a dotted one, Show what you hid that it goes through.
    @ViewBuilder
    private func lineMenu(_ line: WorkMapLine) -> some View {
        if case .through(let nodes) = line.style {
            let hidden = nodes.filter(editor.isHidden)
            if !hidden.isEmpty {
                Button(hidden.count == 1 ? "Show \(editor.label(hidden[0]))" : "Show \(hidden.count) Hidden") {
                    order.showOnMap(hidden)
                    selectedLine = nil
                }
            }
        } else {
            Button("Take This Line Away") {
                editor.stopWaiting(line.after, for: line.before)
                selectedLine = nil
            }
        }
    }

    /// A selected line's card, at its middle: what it says, and Take Away.
    private func selectedLineCard(_ drawn: Geometry.Drawn) -> some View {
        HStack(spacing: 8) {
            Text(editor.words(drawn.line))
                .font(size: 11.5)
                .lineLimit(1)
                .truncationMode(.middle)
            if case .through(let nodes) = drawn.line.style {
                let hidden = nodes.filter(editor.isHidden)
                if !hidden.isEmpty {
                    Button("Show") {
                        order.showOnMap(hidden)
                        selectedLine = nil
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button("Take Away") {
                    editor.stopWaiting(drawn.line.after, for: drawn.line.before)
                    selectedLine = nil
                }
                .buttonStyle(.borderless)
                .help("Only on the Map: \(editor.label(drawn.line.after)) no longer waits for \(editor.label(drawn.line.before)) there")
            }
            Button {
                selectedLine = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
        .fixedSize()
    }

    static func arrowhead(at end: CGPoint, size: CGFloat) -> Path {
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - size, y: end.y - size * 0.6))
        head.addLine(to: CGPoint(x: end.x - size, y: end.y + size * 0.6))
        head.closeSubpath()
        return head
    }

    // MARK: Drawing a line

    /// The line being drawn, from the node it starts at to the pointer, and what it would say there.
    @ViewBuilder
    private func drawingLayer(_ geometry: Geometry, target: MapNodeID?, metrics m: WorkMapMetrics) -> some View {
        if let drawing, let from = geometry.frames[drawing.from] {
            let verdict = target.map { editor.verdict(drawing.from, before: $0) }
            let end = target.flatMap { geometry.frames[$0] }.map { CGPoint(x: $0.minX, y: $0.midY) } ?? drawing.to
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let start = CGPoint(x: from.maxX, y: from.midY)
                    var path = Path()
                    path.move(to: start)
                    let reach = max(12 * m.scale, abs(end.x - start.x) / 2)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + reach, y: start.y), control2: CGPoint(x: end.x - reach, y: end.y))
                    let color: Color = verdict?.allowed == false ? .secondary : .accentColor
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2 * m.scale, lineCap: .round, dash: [4 * m.scale, 3 * m.scale]))
                    context.fill(Self.arrowhead(at: end, size: 5 * m.scale), with: .color(color))
                }
                if let verdict, !verdict.words.isEmpty {
                    Label(verdict.words, systemImage: verdict.allowed ? "arrow.right.circle.fill" : "nosign")
                        .font(size: 11.5, weight: .medium)
                        .foregroundStyle(verdict.allowed ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .fixedSize()
                        .offset(x: drawing.to.x + 12, y: drawing.to.y + 12)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Pieces

    private func blockTitle(_ block: Block, title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let ask, let question = block.question {
                WorkMapAskMenu(question: question, sessions: block.sessions, order: order, ask: ask.0) { ask.1(block.id, $0) }
            }
            if let words = block.said {
                Label(words, systemImage: "sparkles")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func nodeView(
        _ placed: Geometry.Placed, through: [String], lit: Set<MapNodeID>?, target: MapNodeID?, geometry: Geometry
    ) -> some View {
        let id = placed.id
        return WorkMapNodeView(
            item: placed.item, elsewhere: placed.elsewhere.map(editor.content.laneTitle), editor: editor, order: order, through: through,
            isDimmed: lit.map { !$0.contains(id) } ?? false, isTarget: target == id, focus: focus,
            showsHandle: hovered == id && drawing == nil
        )
        .onHover { inside in
            if inside {
                hovered = id
            } else if hovered == id {
                hovered = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    selectedLine = nil
                    drawing = (from: id, to: value.location)
                }
                .onEnded { value in
                    drawing = nil
                    guard let target = node(at: value.location, in: geometry), target != id else { return }
                    let verdict = editor.verdict(id, before: target)
                    if verdict.allowed {
                        editor.wait(target, for: id)
                    } else {
                        ThisMac.beep()
                    }
                }
        )
    }
}

extension WorkMapCanvas.Geometry {
    /// Where everything goes on a canvas: its graphs one under the other, then its grid. Where the graphs' columns don't all
    /// fit across `width`, they fold into tiers (`WorkMapFold`), as many across as fit beside the room the lines that wrap
    /// round need, and only the rows each tier's cards, steps and lines take. A line from one tier to the next goes on past the
    /// tier's end, down under it, back along the gap to the next's start and into it, each in a lane of its own: the one that
    /// leaves from highest outermost and lowest, so that they don't cross. The grid has as many columns as fit, or
    /// `gridColumns` until the page knows its width.
    init(
        blocks: [WorkMapCanvas.Block], columns: [WorkMapColumn], grid: [WorkMapItem], width: CGFloat?, gridColumns: Int,
        metrics m: WorkMapMetrics
    ) {
        let spans: [[ClosedRange<Int>]] = blocks.map(\.graph.spans)
        let fold: WorkMapFold
        var inset: CGFloat = 0
        if let width, columns.count > Self.across(width, metrics: m) {
            var across = Self.across(width, metrics: m)
            var folded = WorkMapFold(columns: columns.count, across: across, spans: spans.flatMap { $0 })
            var room = m.margin(for: Self.mostWrapping(folded, spans: spans))
            while across > 1, m.x(across) - m.columnGap + 2 * room > width {
                across -= 1
                folded = WorkMapFold(columns: columns.count, across: across, spans: spans.flatMap { $0 })
                room = m.margin(for: Self.mostWrapping(folded, spans: spans))
            }
            fold = folded
            inset = room
        } else {
            fold = WorkMapFold(columns: columns.count)
        }
        func x(_ column: Int) -> CGFloat {
            inset + m.x(column - fold.starts[fold.tier(of: column)])
        }
        var titles: [Title] = []
        /// Puts the titles of a tier's columns at a height: whether it has any.
        func title(_ tier: Int, at top: CGFloat) -> Bool {
            let count = titles.count
            for column in fold.columns(ofTier: tier) {
                guard let text = columns[column].title else { continue }
                titles.append(Title(text: text, frame: CGRect(x: x(column), y: top, width: m.nodeWidth, height: m.titleRow)))
            }
            return titles.count > count
        }

        var y: CGFloat = title(0, at: 0) ? m.titleRow : 0
        var nodes: [Placed] = []
        var lines: [Drawn] = []
        var placements: [Placement] = []
        var frames: [MapNodeID: CGRect] = [:]
        for (index, block) in blocks.enumerated() {
            var titleTop: CGFloat?
            if block.title != nil {
                titleTop = y
                y += m.blockTitle
            }
            let top = y
            let graph = block.graph
            let ends = spans[index]
            // Each tier the graph has anything in, with where it starts and ends, and its rows, from the top.
            var tierTop: [Int: CGFloat] = [:]
            var tierBottom: [Int: CGFloat] = [:]
            var tierRow: [Int: [Int: Int]] = [:]
            for tier in 0..<fold.tiers {
                let rows = graph.rows(in: fold.columns(ofTier: tier))
                guard !rows.isEmpty else { continue }
                if !tierTop.isEmpty {
                    let wrapping = ends.filter { fold.wraps($0, into: tier) }.count
                    y += 2 * m.foldGap + m.laneGap(of: wrapping) * CGFloat(max(wrapping - 1, 0))
                }
                if tier > 0, title(tier, at: y) {
                    y += m.titleRow
                }
                tierTop[tier] = y
                tierRow[tier] = Dictionary(rows.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                y += m.y(rows.count) - m.rowGap
                tierBottom[tier] = y
            }
            /// The top of a row in a column, in its tier.
            func rowTop(_ column: Int, _ row: Int) -> CGFloat {
                let tier = fold.tier(of: column)
                let at: Int = tierRow[tier]?[row] ?? 0
                return (tierTop[tier] ?? top) + m.y(at)
            }
            for node in graph.nodes {
                let frame = CGRect(x: x(node.column), y: rowTop(node.column, node.row), width: m.nodeWidth, height: m.nodeHeight)
                nodes.append(Placed(item: node.item, frame: frame, elsewhere: node.elsewhere))
                frames[node.id] = frame
            }
            let rowOf = Dictionary(graph.nodes.map { ($0.id, $0.row) }, uniquingKeysWith: { first, _ in first })
            /// The row a line is at in a column it goes through or ends in.
            func row(_ number: Int, at column: Int) -> Int {
                let line = graph.lines[number]
                let span = ends[number]
                if column <= span.lowerBound { return rowOf[line.before] ?? 0 }
                if column >= span.upperBound { return rowOf[line.after] ?? 0 }
                let offset = column - span.lowerBound - 1
                return line.rows.indices.contains(offset) ? line.rows[offset] : 0
            }
            // The lanes of the lines that wrap round into each tier: in the order they leave the tier above, from the top,
            // then come into it.
            var lane: [Int: [Int: Int]] = [:]
            var lanes: [Int: Int] = [:]
            for tier in fold.starts.indices.dropFirst() {
                let start = fold.starts[tier]
                /// Where a line leaves the tier above, then where it comes into this one.
                func key(_ number: Int) -> (CGFloat, CGFloat, Int) {
                    (rowTop(start - 1, row(number, at: start - 1)), rowTop(start, row(number, at: start)), number)
                }
                let ordered = ends.indices.filter { fold.wraps(ends[$0], into: tier) }.sorted { key($0) < key($1) }
                lane[tier] = Dictionary(ordered.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                lanes[tier] = ordered.count
            }
            for (number, line) in graph.lines.enumerated() {
                guard let from = frames[line.before], let to = frames[line.after], ends[number].lowerBound < ends[number].upperBound
                else { continue }
                let span = ends[number]
                let start = CGPoint(x: from.maxX, y: from.midY)
                var path = Path()
                path.move(to: start)
                var point = start
                var turned: CGPoint?
                // Through each column it skips, along the row it keeps there, wrapping round into each tier it goes on to.
                for column in (span.lowerBound + 1)...span.upperBound {
                    let entry = CGPoint(x: x(column), y: rowTop(column, row(number, at: column)) + m.nodeHeight / 2)
                    let tier = fold.tier(of: column)
                    if tier == fold.tier(of: column - 1) {
                        Self.curve(&path, from: point, to: entry, metrics: m)
                    } else {
                        let at = lane[tier]?[number] ?? 0
                        let count = lanes[tier] ?? 1
                        let gap = m.laneGap(of: count)
                        let outer = gap * CGFloat(count - 1 - at)
                        let right = point.x + m.wrapReach + outer
                        let under = (tierBottom[fold.tier(of: column - 1)] ?? point.y) + m.foldGap + outer
                        let left = entry.x - m.wrapReach - gap * CGFloat(at)
                        let corners: [CGPoint] = [
                            CGPoint(x: right, y: point.y), CGPoint(x: right, y: under),
                            CGPoint(x: left, y: under), CGPoint(x: left, y: entry.y),
                        ]
                        Self.turn(&path, through: corners, to: entry, radius: m.corner)
                        if turned == nil { turned = CGPoint(x: (right + left) / 2, y: under) }
                    }
                    point = entry
                    if column < span.upperBound {
                        point.x += m.nodeWidth
                        path.addLine(to: point)
                    }
                }
                let end = CGPoint(x: to.minX, y: to.midY)
                let middle: CGPoint
                if let first = line.rows.first {
                    let column = span.lowerBound + 1
                    middle = CGPoint(x: x(column) + m.nodeWidth / 2, y: rowTop(column, first) + m.nodeHeight / 2)
                } else if let turned {
                    middle = turned
                } else {
                    middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                }
                lines.append(Drawn(line: line, path: path, end: end, middle: middle))
            }
            placements.append(Placement(id: block.id, titleTop: titleTop, top: top, height: y - top))
            y += m.blockGap
        }
        var gridAcross = 0
        if !grid.isEmpty {
            gridTop = y
            y += m.blockTitle
            gridAcross = width.map { Self.across($0 - inset, metrics: m) } ?? max(gridColumns, 1)
            for (index, item) in grid.enumerated() {
                let frame = CGRect(
                    x: inset + m.x(index % gridAcross), y: y + m.y(index / gridAcross), width: m.nodeWidth, height: m.nodeHeight
                )
                nodes.append(Placed(item: item, frame: frame, elsewhere: nil))
                frames[item.id] = frame
            }
            y += m.y((grid.count + gridAcross - 1) / gridAcross) - m.rowGap
        } else if !blocks.isEmpty {
            y -= m.blockGap
        }
        let widest = fold.starts.indices.map { fold.columns(ofTier: $0).count }.max() ?? 0
        let graphs: CGFloat = widest > 0 ? 2 * inset + m.x(widest) - m.columnGap : 0
        let gridWidth: CGFloat = gridAcross > 0 ? inset + m.x(gridAcross) - m.columnGap : 0
        self.nodes = nodes
        self.lines = lines
        self.blocks = placements
        self.titles = titles
        self.frames = frames
        self.fold = fold
        self.inset = inset
        size = CGSize(width: max(graphs, gridWidth, m.nodeWidth), height: max(y, 0))
    }

    /// How many columns fit across a width: at least one.
    static func across(_ width: CGFloat, metrics m: WorkMapMetrics) -> Int {
        max(Int((width + m.columnGap) / (m.nodeWidth + m.columnGap)), 1)
    }

    /// The most lines of one graph that wrap round into one tier of a fold together.
    static func mostWrapping(_ fold: WorkMapFold, spans: [[ClosedRange<Int>]]) -> Int {
        var most = 0
        for tier in fold.starts.indices.dropFirst() {
            for ends in spans {
                most = max(most, ends.filter { fold.wraps($0, into: tier) }.count)
            }
        }
        return most
    }

    /// A curve from one point to another further right, level at each end, as a line goes from a column to the next.
    static func curve(_ path: inout Path, from start: CGPoint, to end: CGPoint, metrics m: WorkMapMetrics) {
        let reach = max(12 * m.scale, (end.x - start.x) / 2)
        path.addCurve(to: end, control1: CGPoint(x: start.x + reach, y: start.y), control2: CGPoint(x: end.x - reach, y: end.y))
    }

    /// Straight through these corners, each rounded, to the end, as a line wraps round a fold.
    static func turn(_ path: inout Path, through corners: [CGPoint], to end: CGPoint, radius: CGFloat) {
        var current = path.currentPoint ?? end
        for (index, corner) in corners.enumerated() {
            let next = index + 1 < corners.count ? corners[index + 1] : end
            let room = min(hypot(corner.x - current.x, corner.y - current.y), hypot(next.x - corner.x, next.y - corner.y)) / 2
            path.addArc(tangent1End: corner, tangent2End: next, radius: min(radius, room))
            current = corner
        }
        path.addLine(to: end)
    }
}

/// Where a canvas lays its pieces: each at the frame it says (`at`), the canvas as big as it says.
private struct CanvasLayout: Layout {
    var size: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let frame = subview[CanvasFrame.self]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct CanvasFrame: LayoutValueKey {
    static let defaultValue = CGRect.zero
}

private extension View {
    /// Where it goes on a canvas.
    func at(_ frame: CGRect) -> some View {
        self.frame(width: frame.width, height: frame.height).layoutValue(key: CanvasFrame.self, value: frame)
    }
}

/// Where All's graphs and grid are, in the page's flow, outside the card that scrolls sideways: what a mission or a card
/// scrolls to, and what says which are in sight.
private struct WorkMapAnchors: View {
    let geometry: WorkMapCanvas.Geometry
    let offset: CGFloat
    let sight: (String, Bool) -> Void

    init(_ geometry: WorkMapCanvas.Geometry, offset: CGFloat, sight: @escaping (String, Bool) -> Void) {
        self.geometry = geometry
        self.offset = offset
        self.sight = sight
    }

    var body: some View {
        CanvasLayout(size: CGSize(width: 1, height: geometry.size.height + 2 * offset)) {
            ForEach(geometry.blocks, id: \.id) { block in
                let top = (block.titleTop ?? block.top) + offset
                Color.clear
                    .id(block.id)
                    .onSightChange { sight(block.id, $0) }
                    .at(CGRect(x: 0, y: top, width: 1, height: max(block.top + block.height + offset - top, 1)))
            }
            if let top = geometry.gridTop {
                Color.clear
                    .id(WorkMapText.notConnected)
                    .at(CGRect(x: 0, y: top + offset, width: 1, height: max(geometry.size.height - top, 1)))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// What hovering a node lights up.
enum WorkMapLines {
    /// The node, what comes before it and what comes after it, directly or through others, by these lines.
    static func related(to node: MapNodeID, by lines: [WorkMapLine]) -> Set<MapNodeID> {
        func reach(_ step: (WorkMapLine) -> (from: MapNodeID, to: MapNodeID)) -> Set<MapNodeID> {
            var reached: Set<MapNodeID> = []
            var pending = [node]
            while let current = pending.popLast() {
                for line in lines {
                    let (from, to) = step(line)
                    if from == current, reached.insert(to).inserted { pending.append(to) }
                }
            }
            return reached
        }
        return reach { ($0.after, $0.before) }.union(reach { ($0.before, $0.after) }).union([node])
    }
}

// MARK: - A node

/// A card's node: a pull request's mark, number and short title, with the work items of yours it's for, in its stage's
/// color; or a work item's type, ID, state and title, in the color of where it is: gray, outlined dashed, before it starts,
/// then In progress's, Merged's once resolved, and green once done. Or a step's: its circle, which marks it done, its name,
/// and who added it, outlined dashed until it's done, then green. Of another band, By Mission, dimmed, with that band's name.
/// A click does what clicking its card does, or, on a step, Rename…; its menu is its card's, with what it waits for, Add Step
/// After… and Hide on Map.
struct WorkMapNodeView: View {
    let item: WorkMapItem
    /// The band it's in, for one of another band's, By Mission; nil for the band's own.
    let elsewhere: String?
    let editor: WorkMapEditor
    @ObservedObject var order: PullRequestOrder
    /// What the dotted lines into it go through: "API tests waits for !4101, through !4102, which you hid".
    let through: [String]
    let isDimmed: Bool
    /// A line being drawn would end on it.
    let isTarget: Bool
    /// Which node has the keyboard's focus, which lights up what it's joined to.
    var focus: FocusState<MapNodeID?>.Binding
    /// Whether it shows where a line can be drawn from: its right edge, while the pointer's on it.
    var showsHandle = false

    @Environment(\.textScale) private var textScale

    var body: some View {
        let card = cardContent
        let isSelected = item.card.map { editor.content.isSelected($0.ref) } ?? false
        let color = self.color
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let isDashed = (isToStart || elsewhere != nil) && !isSelected && !isTarget
        face
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(color.opacity(0.12)))
            .overlay(
                shape.strokeBorder(
                    isSelected || isTarget ? Color.accentColor : color.opacity(0.4),
                    style: isDashed ? StrokeStyle(lineWidth: 1, dash: [3, 2]) : StrokeStyle(lineWidth: isSelected || isTarget ? 2 : 1)
                )
            )
            .overlay(alignment: .trailing) {
                if showsHandle {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8 * textScale, height: 8 * textScale)
                        .offset(x: 4 * textScale)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .modifier(StepDoubleClick(step: elsewhere == nil ? item.step : nil) { editor.rename($0) })
            .onTapGesture(perform: click)
            // As a card on the Board takes the keyboard's focus, on a click and with Tab, whatever the Mac's keyboard
            // navigation: Return or Space shows its details, or renames a step.
            .focusable(interactions: .edit)
            .focused(focus, equals: item.id)
            .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                press()
                return .handled
            }
            .opacity(isDimmed ? 0.45 : elsewhere != nil ? 0.6 : item.card.map { editor.content.related.contains($0.ref) } == true ? 0.55 : 1)
            .help(help(card))
            .contextMenu { menu(card) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label(card))
            .accessibilityValue(((details(card)) + through).joined(separator: ", "))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, press)
            .modifier(CardMissionActions(ref: item.card?.ref, context: card?.mission))
            .accessibilityActions { actions(card) }
    }

    /// A card's click shows its details; a step's takes the focus, which lights up what it's joined to, or, for one of another
    /// band, shows that band.
    private func click() {
        switch item {
        case .card(let card):
            editor.content.select(card.ref)
        case .step:
            if elsewhere != nil, let band = editor.map.band(of: item.id) {
                editor.showBand(band)
            } else {
                focus.wrappedValue = item.id
            }
        }
    }

    /// Return or Space: a card's details, or a step's Rename….
    private func press() {
        if let step = item.step, elsewhere == nil {
            editor.rename(step)
        } else {
            click()
        }
    }

    private var cardContent: BoardCardContent? {
        switch item {
        case .card(.pullRequest(let card)): editor.content.card(card)
        case .card(.work(let task)): editor.content.work?.card(task)
        case .step: nil
        }
    }

    private var isToStart: Bool {
        switch item {
        case .card(.work(let task)): task.column == .toStart
        case .card(.pullRequest): false
        case .step(let step): !step.isDone
        }
    }

    private var color: Color {
        switch item {
        case .card(.pullRequest(let card)):
            card.stage.color
        case .card(.work(let task)):
            switch task.column {
            case .toStart: .secondary
            case .inProgress: PullRequestStage.inProgress.color
            case .merged: PullRequestStage.merged.color
            case .completed: .green
            }
        case .step(let step):
            step.isDone ? .green : .secondary
        }
    }

    @ViewBuilder
    private var face: some View {
        switch item {
        case .card(.pullRequest(let card)):
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
                        if let words = elsewhere.map({ "· in " + $0 }) ?? editor.content.workOf(card.ref).map({ "· " + $0 }) {
                            Text(words)
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
        case .card(.work(let task)):
            let face = editor.content.face(task)
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
                        if let words = elsewhere.map({ "in " + $0 }) ?? face?.state {
                            Text("· " + words)
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
        case .step(let step):
            HStack(spacing: 7) {
                Button {
                    editor.toggle(step)
                } label: {
                    Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                        .font(size: 12, weight: .medium)
                        .foregroundStyle(step.isDone ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(step.isDone ? "Mark Not Done" : "Mark Done")
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.name)
                        .font(size: 11, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 3) {
                        if case .session = step.addedBy {
                            Image(systemName: "sparkles")
                                .font(size: 9, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Text(stepLine(step))
                            .font(size: 10.5)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A step's second line: "Step · To do", "Step · Done", or its band's, "Step · in Faster checkout".
    private func stepLine(_ step: MapStep) -> String {
        "Step · " + (elsewhere.map { "in " + $0 } ?? (step.isDone ? "Done" : "To do"))
    }

    private func label(_ card: BoardCardContent?) -> String {
        switch item {
        case .card(let item): card?.label ?? item.ref.shortOrderLabel
        case .step(let step): "Step: \(step.name)"
        }
    }

    /// What it says, for VoiceOver and its tooltip: its card's words, or a step's, with who added it; where it is, for one
    /// of another band.
    private func details(_ card: BoardCardContent?) -> [String] {
        var details: [String] = []
        switch item {
        case .card: details = card?.details ?? []
        case .step(let step):
            details.append(step.isDone ? "Done" : "To do")
            details.append(editor.who(step.addedBy).replacingOccurrences(of: "said so", with: "added it"))
        }
        if let elsewhere { details.append("In \(elsewhere)") }
        return details
    }

    /// Its tooltip: what it is, then what its card says of it, what dotted lines into it go through, and how to draw a line
    /// from it.
    private func help(_ card: BoardCardContent?) -> String {
        let lines = [card?.label ?? (item.step.map { "Step: \($0.name)" } ?? item.card?.ref.fullOrderLabel ?? "")] + details(card)
        return (lines + through + [WorkMapText.dragHelp]).joined(separator: "\n")
    }

    @ViewBuilder
    private func menu(_ card: BoardCardContent?) -> some View {
        if let card {
            card.menu
            Divider()
        }
        if let step = item.step {
            Button("Rename…") { editor.rename(step) }
            Button(step.isDone ? "Mark Not Done" : "Mark Done") { editor.toggle(step) }
            Divider()
        }
        WorkMapWaitsMenu(node: item.id, editor: editor)
        Button("Add Step After…") { editor.addStep(after: item.id) }
        Button("Hide on Map") { editor.hide(item.id) }
        if elsewhere != nil, let band = editor.map.band(of: item.id) {
            Button("Show Its Band") { editor.showBand(band) }
        }
        if let step = item.step {
            Divider()
            Button("Delete Step", role: .destructive) { editor.delete(step) }
        }
    }

    @ViewBuilder
    private func actions(_ card: BoardCardContent?) -> some View {
        card?.actions
        if let step = item.step {
            Button("Rename") { editor.rename(step) }
            Button(step.isDone ? "Mark Not Done" : "Mark Done") { editor.toggle(step) }
            Button("Delete Step") { editor.delete(step) }
        }
        Button("Add Step After") { editor.addStep(after: item.id) }
        Button("Hide on Map") { editor.hide(item.id) }
    }
}

/// A node's Waits For menu: what it waits for, checked, to take one away; then what it could wait for, its band's first, then
/// the rest, Elsewhere.
struct WorkMapWaitsMenu: View {
    let node: MapNodeID
    let editor: WorkMapEditor

    var body: some View {
        let current = editor.map.waitsFor(node).map(\.node)
        let (near, far) = editor.candidates(for: node)
        Menu("Waits For") {
            ForEach(current, id: \.self) { other in
                Toggle(editor.label(other), isOn: Binding(get: { true }, set: { if !$0 { editor.stopWaiting(node, for: other) } }))
            }
            if !current.isEmpty, !(near.isEmpty && far.isEmpty) {
                Divider()
            }
            ForEach(near.prefix(40), id: \.self) { other in
                Button(editor.label(other)) { editor.wait(node, for: other) }
            }
            if !far.isEmpty {
                Menu("Elsewhere") {
                    ForEach(far.prefix(60), id: \.self) { other in
                        Button(editor.label(other)) { editor.wait(node, for: other) }
                    }
                }
            }
        }
    }
}

/// A card's mission actions, as the Board's card has them; none for a step.
private struct CardMissionActions: ViewModifier {
    let ref: ItemRef?
    let context: MissionMenuContext?

    func body(content: Content) -> some View {
        if let ref {
            content.missionActions(ref, context: context)
        } else {
            content
        }
    }
}

/// A step's double-click, which renames it; nothing for a card, whose click shows its details at once.
private struct StepDoubleClick: ViewModifier {
    let step: MapStep?
    let rename: (MapStep) -> Void

    func body(content: Content) -> some View {
        if let step {
            content.onTapGesture(count: 2) { rename(step) }
        } else {
            content
        }
    }
}

// MARK: - Ask Copilot

/// ✨ Ask Copilot, on a band's header or a graph's title: asks a session of its missions, or a fork of one, to work out what
/// waits for what there and tell BriefBar; or copies the prompt for a new session.
struct WorkMapAskMenu: View {
    let question: WorkMapQuestion
    let sessions: [ItemRef]
    @ObservedObject var order: PullRequestOrder
    let ask: (WorkMapQuestion, WorkMapAsk) async -> String
    /// Says what it did.
    let said: (String) -> Void

    var body: some View {
        Menu {
            ForEach(sessions.prefix(5), id: \.self) { session in
                let name = order.describe(session)?.title ?? "Its Session"
                Button("Ask ‘\(name)’") { run(.session(session)) }
                Button("Ask a Fork of ‘\(name)’") { run(.fork(session)) }
            }
            if !sessions.isEmpty {
                Divider()
            }
            Button("Copy a Prompt for a New Session") { run(.copy) }
        } label: {
            WorkMapControlLabel(title: "Ask Copilot", systemImage: "sparkles", isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(WorkMapText.askHelp)
        .accessibilityLabel("Ask Copilot What Waits for What")
    }

    private func run(_ target: WorkMapAsk) {
        Task { @MainActor in said(await ask(question, target)) }
    }
}

/// A quiet control's label in a band's header, as its sessions' menu is, at the page's text size: "+ Step", "✨ Ask Copilot ⌄".
private struct WorkMapControlLabel: View {
    let title: String
    let systemImage: String
    var isMenu = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(size: 10, weight: .bold)
            Text(title)
            if isMenu {
                Image(systemName: "chevron.down")
                    .font(size: 8, weight: .bold)
            }
        }
        .font(size: 12, weight: .semibold)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
}

// MARK: - Undo

/// Your last change of the Map, with Undo, until you make another or dismiss it.
struct WorkMapUndoLine: View {
    @ObservedObject var order: PullRequestOrder

    var body: some View {
        if let undo = order.mapUndo {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(undo.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Undo") { order.undoMapChange() }
                    .buttonStyle(.borderless)
                    .help("Put back what this change did")
                Spacer(minLength: 4)
                Button {
                    order.dismissMapUndo()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .font(size: 12)
        }
    }
}

// MARK: - Hidden cards

/// A band's cards and steps you hid, or All's, as a quiet button, "2 hidden", whose popover lists them, each with Show, and
/// Show All.
struct WorkMapHiddenButton: View {
    let hidden: [WorkMapItem]
    @ObservedObject var order: PullRequestOrder
    let editor: WorkMapEditor

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
        // Tab reaches it, whatever the Mac's keyboard navigation, as it's the only way back to what it hides there.
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(hidden) { item in
                            row(item)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                if hidden.count > 1 {
                    Divider()
                    Button("Show All") {
                        order.showOnMap(hidden.map(\.id))
                        isShown = false
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
        }
    }

    private func row(_ item: WorkMapItem) -> some View {
        let (label, title) = name(of: item)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(size: 12, weight: .semibold)
                .monospacedDigit()
            Text(title)
                .font(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Show") { order.showOnMap([item.id]) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show \(label)")
        }
    }

    /// What one is called in the list: "!4102" and its title, "Task 5104" and its, "Step" and its name.
    private func name(of item: WorkMapItem) -> (label: String, title: String) {
        switch item {
        case .card(.pullRequest(let card)):
            (card.ref.shortOrderLabel, order.describe(card.ref)?.title ?? "")
        case .card(.work(let task)):
            editor.content.face(task).map { ($0.label, $0.title) } ?? (task.ref.shortOrderLabel, "")
        case .step(let step):
            ("Step", step.name)
        }
    }
}

// MARK: - Words

/// What My Work's Map says.
package enum WorkMapText {
    /// With nothing to draw.
    static let nothingYet = "Nothing to draw yet: your pull requests show here as they come, and, with + Sprint Tasks, your sprint work."

    /// Until you or a session first change the Map.
    static let tip = """
        Drag from a card to what waits for it to draw a line; click a line to take it away. + Step adds what has no pull \
        request yet, such as enabling it in production, and ✨ Ask Copilot has a session work out the rest.
        """

    /// A band whose cards you all hid.
    static let allHidden = "You hid all its cards on the Map."

    /// All's last part's title: the cards no line joins.
    static let notConnected = "Not connected"

    /// The title of the steps of a band or graph too big to draw.
    static let stepsTitle = "Its steps"

    static let stepsHelp = "Its steps, which the Board doesn't show: right-click one to rename it, mark it done or delete it"

    static let notConnectedHelp = """
        No line joins these to other cards or steps: drag from one to what waits for it, or onto it from what it waits for
        """

    /// "1 hidden", "3 hidden".
    static func hidden(_ count: Int) -> String {
        "\(count) hidden"
    }

    static let hiddenHelp = "The cards and steps you hid on the Map, as they're not your focus now. They stay on the Board"

    static let addStepHelp = """
        Add a step: work with no pull request or work item yet, such as API tests, monitoring or enabling it in production. \
        It shows on the Map only
        """

    static let stepMessage = """
        Work with no pull request or work item yet, such as API tests, monitoring, or enabling it in production. It shows on \
        the Map only.
        """

    static let dragHelp = "Drag from it to what waits for it to draw a line"

    static let askHelp = """
        Ask a Copilot session what waits for what here: it reads the code and the work, and tells BriefBar, and the Map shows \
        it. Nothing else changes
        """

    /// The Map's tooltip in My Work's header.
    package static let viewHelp = "Board: a column for each stage, a lane for each mission. Map: what holds what, as a graph"

    /// By Mission | All's tooltip.
    package static let groupingHelp = """
        By Mission: a graph for each mission, as the Board's lanes. All: every graph together, whatever their missions, and \
        a grid of what no line joins
        """
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
