import AppKit
import BriefBarCore
import SwiftUI

// By Mission's Board, on Azure DevOps' Pull Requests page: a column for each stage, as a kanban board has them, a lane for
// each mission, and a card for each pull request on your board. Drag a card to another column of its lane to change its
// stage, or click it and press ⌘→ or ⌘←; the columns that take it light up as you drag, and those that don't say why as you
// hover them. Its column titles stay at the top as the page scrolls, and the board scrolls sideways when the window is too
// narrow for its columns, which grow with the text. Scrolling redraws only what follows it: the column titles and the lanes'
// headers.

/// What a page draws on a card, which the Board frames: its content, its menu, and what VoiceOver says of it.
package struct BoardCardContent {
    package var view: AnyView
    package var menu: AnyView
    /// What VoiceOver calls it: "!4102 Retry backoff".
    package var label: String
    /// What else VoiceOver says of it, after its stage: what needs you on it, where it stands in its order.
    package var details: [String]

    package init(view: AnyView, menu: AnyView, label: String, details: [String] = []) {
        self.view = view
        self.menu = menu
        self.label = label
        self.details = details
    }
}

/// A column of a lane.
private struct BoardCell: Hashable {
    var lane: BoardLane.Kind
    var stage: PullRequestStage
}

/// A card where it shows, for the keyboard's focus: a pull request in two missions' lanes has a card in each. It stays the
/// same as the card moves to another column.
private struct CardSpot: Hashable {
    var lane: BoardLane.Kind
    var ref: ItemRef
}

/// Where Up Next's "2 more ›" scrolls the Board to.
private struct ColumnAnchor: Hashable {
    var stage: PullRequestStage
}

/// Where a mission's lane starts, for the page to scroll to: an identity of its own for its spacer, so that only the anchor
/// at the lane's top has the mission's key.
private struct LaneAnchor: Hashable {
    var mission: MissionKey
}

/// Why a card couldn't move, under its lane until your next move.
private struct BoardNotice: Equatable {
    var lane: BoardLane.Kind
    var text: String
}

/// How wide the Board's columns are: as wide as the page allows, never narrower than their text needs, Merged narrow while
/// it's folded.
private struct BoardMetrics {
    let scale: CGFloat
    /// The page's width.
    let available: CGFloat
    let showsMerged: Bool

    var gap: CGFloat { 10 * scale }
    var minimum: CGFloat { 172 * scale }
    var folded: CGFloat { 132 * scale }

    var column: CGFloat {
        let open = CGFloat(showsMerged ? 6 : 5)
        let room = available - gap * 5 - (showsMerged ? 0 : folded)
        return max(minimum, room / open)
    }

    func width(_ stage: PullRequestStage) -> CGFloat {
        stage == .merged && !showsMerged ? folded : column
    }

    var content: CGFloat {
        PullRequestStage.columns.reduce(gap * 5) { $0 + width($1) }
    }

    /// What shows of the board at once.
    var visible: CGFloat {
        available > 0 ? min(available, content) : content
    }
}

/// How far the board is scrolled sideways, which only the column titles and the lanes' headers follow: the rest of the
/// board isn't drawn again as it scrolls.
@MainActor
private final class BoardScroll: ObservableObject {
    @Published var x: CGFloat = 0
}

/// What follows the board as it scrolls sideways: the column titles, which move with the columns under them, and a lane's
/// header, which stays in view.
private struct FollowsScroll<Content: View>: View {
    @ObservedObject var scroll: BoardScroll
    /// -1 to move with the columns, 1 to stay in view.
    let direction: CGFloat
    let content: Content

    var body: some View {
        content.offset(x: direction * scroll.x)
    }
}

/// By Mission's Board: Up Next's pull request wears Next in its column, and each mission's lane has its header, its next
/// steps and the Undo line of your last change to one of its pull requests, on the board or not. With Lanes: None, every card
/// is in one lane. A change that takes a pull request in no mission off the board keeps a lane for its Undo line.
package struct OrderBoardView: View {
    let board: PullRequestBoard
    /// The missions the page shows, as By Mission lists them, for the lanes' headers.
    let missions: [OrderMission]
    @ObservedObject var order: PullRequestOrder
    /// The page that lists the missions' other pull requests, "GitHub", and opening it; nil when it can't open.
    let elsewhere: String
    let openElsewhere: (() -> Void)?
    /// The repository most of a mission's pull requests are in, as the page names it.
    let place: (OrderMission) -> String?
    /// A card's content as the page draws it; nil for one it doesn't list.
    let card: (BoardCard) -> BoardCardContent?
    let isSelected: (ItemRef) -> Bool
    let select: (ItemRef) -> Void
    /// Set as Next to Merge, which dropping a card from Waits onto Can merge does: nil until you can change missions
    /// yourself, and the Board says what it waits for instead.
    let setAsNext: ((ItemRef) -> Void)?
    /// How many of the page's pull requests aren't on the board.
    let notOnBoard: Int
    /// Lists them By Status; nil where it can't.
    let showByStatus: (() -> Void)?
    let now: Date

    /// The card you drag, or dragged last: only what this drag carries drops.
    @LocalState private var drag: BoardDrag?
    /// A card is being dragged now: the columns that take it light up.
    @LocalState private var isDragging = false
    @LocalState private var hovered: BoardCell?
    @LocalState private var notice: BoardNotice?
    @LocalState private var showsMerged = false
    @LocalState private var unfolded: Set<MissionKey> = []
    @LocalState private var width: CGFloat = 0
    @LocalState private var flashing: PullRequestStage?
    /// The column titles stay at the page's top, over the cards that scroll under them.
    @LocalState private var isPinned = false
    @LocalState private var scroll = BoardScroll()
    /// Where each mission's lane starts, for By Mission to show it, as a row's capsule asks.
    @LocalState private var laneTops: [MissionKey: CGFloat] = [:]
    /// The mission a row's capsule asked to show, for a moment, while the board settles.
    @LocalState private var revealing: MissionKey?
    @LocalState private var titlesHeight: CGFloat = 0
    @FocusState private var focused: CardSpot?
    /// The card a key, or a drop, just moved while it had the keyboard's focus: drawn anew in its new column, it takes the
    /// focus back as it appears, so that the next key moves it on.
    @LocalState private var refocus: CardSpot?
    @Environment(\.textScale) private var textScale

    package init(
        board: PullRequestBoard, missions: [OrderMission], order: PullRequestOrder, elsewhere: String, openElsewhere: (() -> Void)?,
        place: @escaping (OrderMission) -> String?, card: @escaping (BoardCard) -> BoardCardContent?,
        isSelected: @escaping (ItemRef) -> Bool, select: @escaping (ItemRef) -> Void, setAsNext: ((ItemRef) -> Void)?,
        notOnBoard: Int, showByStatus: (() -> Void)?, now: Date
    ) {
        self.board = board
        self.missions = missions
        self.order = order
        self.elsewhere = elsewhere
        self.openElsewhere = openElsewhere
        self.place = place
        self.card = card
        self.isSelected = isSelected
        self.select = select
        self.setAsNext = setAsNext
        self.notOnBoard = notOnBoard
        self.showByStatus = showByStatus
        self.now = now
    }

    package var body: some View {
        let metrics = BoardMetrics(scale: textScale, available: width, showsMerged: showsMerged)
        let lanes = board.lanes(keepingUndoOf: order.lastChange?.ref, missions: missions)
        let moves = BoardMoves(board: board, missions: missions, order: order, missionChanges: setAsNext != nil)
        VStack(alignment: .leading, spacing: 12) {
            if lanes.isEmpty {
                Text("Nothing's on your board yet. Your pull requests, and those you're asked to review, show here by stage.")
                    .font(size: 12.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else {
                // Its column titles stay at the top as the page scrolls.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        lanesView(lanes, metrics: metrics, moves: moves)
                    } header: {
                        columnTitles(metrics)
                    }
                }
            }
            notOnBoardLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // On the Board, a card that a change takes off it leaves its Undo at the top of its lane, as VoiceOver says.
        .environment(\.stageUndoPlace, .lane)
        // A drag that ends anywhere, dropped or not: the columns stop lighting up.
        .task(id: isDragging) {
            while !Task.isCancelled, isDragging {
                try? await Task.sleep(for: .milliseconds(200))
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    isDragging = false
                    hovered = nil
                }
            }
        }
    }

    // MARK: Columns

    private func columnTitles(_ metrics: BoardMetrics) -> some View {
        FollowsScroll(scroll: scroll, direction: -1, content: HStack(alignment: .bottom, spacing: metrics.gap) {
            ForEach(PullRequestStage.columns, id: \.self) { stage in
                columnTitle(stage, width: metrics.width(stage))
            }
        })
        .frame(width: metrics.visible, alignment: .leading)
        .clipped()
        .padding(.vertical, 6)
        .background {
            // Once it stays at the top, over the cards that scroll under it.
            if isPinned {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .bottom) { Divider().opacity(0.6) }
                    .padding(.horizontal, -18)
            }
        }
        // Only as it reaches the top and leaves it, not each time the page scrolls.
        .onGeometryChange(for: Bool.self) { proxy in
            (proxy.bounds(of: .scrollView)?.minY ?? -1) > -1
        } action: { isPinned = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titlesHeight = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stages")
    }

    @ViewBuilder
    private func columnTitle(_ stage: PullRequestStage, width: CGFloat) -> some View {
        let count = board.counts[stage] ?? 0
        let label = HStack(spacing: 6 * textScale) {
            Circle()
                .fill(stage.color)
                .frame(width: 8 * textScale, height: 8 * textScale)
            Text(stage.columnTitle)
                .font(size: 13, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            Text("\(count)")
                .font(size: 12.5, weight: .medium)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if stage == .merged {
                Image(systemName: "chevron.right")
                    .font(size: 9, weight: .bold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showsMerged ? 90 : 0))
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 7)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(stage.color.opacity(flashing == stage ? 0.22 : 0))
        )
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(stage.color)
                .frame(height: 3 * textScale)
        }
        .contentShape(Rectangle())
        if stage == .merged {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsMerged.toggle() }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help(showsMerged ? "Fold Merged to its count" : "Show what merged: Done lists it for a day")
            .accessibilityLabel("Merged, \(count)")
            .accessibilityHint(showsMerged ? "Folds it" : "Shows its cards")
        } else {
            label
                .help(Self.help(stage))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(stage.title), \(count)")
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// What a column holds, for its title's tooltip.
    static func help(_ stage: PullRequestStage) -> String {
        switch stage {
        case .inProgress: "Its work isn't done: a session or someone writes or fixes it, or its builds or what else Azure DevOps requires aren't"
        case .yourReview: "You review it next"
        case .teammateReview: "Others review it next: yours that wait for reviewers, and those you finished reviewing"
        case .canMerge: "Azure DevOps says it's ready to complete, and BriefBar saw everything its order puts before it merge"
        case .waits: "Azure DevOps says it's ready to complete, but its order puts it after one BriefBar hasn't seen merge"
        case .merged: "BriefBar saw it merge"
        }
    }

    // MARK: Lanes

    /// The coordinate space of the board's lanes, where each lane's top is measured.
    private static let lanesSpace = "boardLanes"

    private func lanesView(_ lanes: [BoardLane], metrics: BoardMetrics, moves: BoardMoves) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    // Where Up Next's "2 more ›" scrolls to.
                    HStack(spacing: metrics.gap) {
                        ForEach(PullRequestStage.columns, id: \.self) { stage in
                            Color.clear
                                .frame(width: metrics.width(stage), height: 0)
                                .id(ColumnAnchor(stage: stage))
                        }
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(lanes) { lane in
                            laneView(lane, metrics: metrics, moves: moves)
                                // Changes as lanes grow or shrink, never as the board scrolls.
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.lanesSpace)).minY } action: { top in
                                    if let key = lane.mission { laneTops[key] = top }
                                }
                        }
                    }
                }
                .padding(.top, 8)
                .frame(width: metrics.content, alignment: .leading)
                .coordinateSpace(.named(Self.lanesSpace))
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(metrics.content > metrics.visible + 1 ? .automatic : .hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scroll.x = x }
            .onChange(of: order.revealedColumn) { _, stage in reveal(stage, with: proxy) }
            .onAppear {
                reveal(order.revealedColumn, with: proxy)
                takeReveal(order.revealed, with: proxy)
            }
            .onChange(of: order.revealed) { _, key in takeReveal(key, with: proxy) }
            .onChange(of: laneTops) { _, _ in revealMission(with: proxy) }
            .onChange(of: titlesHeight) { _, _ in revealMission(with: proxy) }
            .overlay(alignment: .topLeading) { missionAnchors(lanes) }
        }
    }

    /// Where each mission's lane starts, as By Mission shows a mission a row's capsule asks for: outside the board's sideways
    /// scroll, so that it scrolls the page, just under the column titles that stay at its top.
    private func missionAnchors(_ lanes: [BoardLane]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(lanes.compactMap(\.mission).map(LaneAnchor.init), id: \.self) { anchor in
                VStack(spacing: 0) {
                    Color.clear.frame(width: 1, height: max(0, (laneTops[anchor.mission] ?? 0) - titlesHeight))
                    Color.clear.frame(width: 1, height: 1).id(anchor.mission)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Takes the mission a row's capsule asks By Mission to show, and shows it.
    private func takeReveal(_ key: MissionKey?, with proxy: ScrollViewProxy) {
        guard let key else { return }
        revealing = key
        revealMission(with: proxy)
        DispatchQueue.main.async {
            if order.revealed == key { order.revealed = nil }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if revealing == key { revealing = nil }
        }
    }

    /// The page scrolls to the lane of the mission it shows, once the lane is laid out, and again as the board settles, as
    /// when it just showed a lane for each mission for it: where the lane is moves until then.
    private func revealMission(with proxy: ScrollViewProxy) {
        guard let key = revealing, laneTops[key] != nil else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(key, anchor: .top) }
        }
    }

    private func laneView(_ lane: BoardLane, metrics: BoardMetrics, moves: BoardMoves) -> some View {
        let mission = lane.mission.flatMap { key in missions.first { $0.key == key } }
        let isFolded = mission.map { $0.isFinished && !unfolded.contains($0.key) } ?? false
        let undoRefs = board.undoRefs(of: lane, missions: missions, changed: order.lastChange?.ref)
        return VStack(alignment: .leading, spacing: 8) {
            // The lane's header stays in view as the board scrolls sideways. Every card in one lane has none, but for the
            // Undo line or why a card couldn't move.
            if lane.kind != .all || hasLines(lane, undoRefs: undoRefs) {
                FollowsScroll(
                    scroll: scroll, direction: 1, content: laneHeader(lane, mission: mission, isFolded: isFolded, undoRefs: undoRefs)
                )
                .frame(width: metrics.visible, alignment: .leading)
            }
            // A lane kept only for the Undo line of a pull request that left the board has no columns to show.
            if !isFolded, !(lane.isEmpty && lane.mission == nil) {
                HStack(alignment: .top, spacing: metrics.gap) {
                    ForEach(PullRequestStage.columns, id: \.self) { stage in
                        cell(lane, stage: stage, width: metrics.width(stage), moves: moves)
                    }
                }
                // Its columns are as tall as its tallest, so that each is as big a place to drop a card.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func laneHeader(_ lane: BoardLane, mission: OrderMission?, isFolded: Bool, undoRefs: Set<ItemRef>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch lane.kind {
            case .mission:
                if let mission {
                    MissionHeader(mission: mission, order: order, place: place(mission))
                    let outside = mission.count(outside: board.kinds)
                    if outside > 0 {
                        OrderElsewhereLine(count: outside, elsewhere: elsewhere, open: openElsewhere)
                            .padding(.leading, 4)
                    }
                    if mission.isFinished {
                        foldedLine(mission, isFolded: isFolded)
                    }
                    MissionNextStepsLine(lane: lane, order: order, select: select)
                        .padding(.leading, 4)
                }
            case .notInAMission:
                Text("Not in a mission")
                    .font(size: 15, weight: .semibold)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
            case .all:
                EmptyView()
            }
            StageUndoLine(refs: undoRefs, order: order)
                .padding(.horizontal, 4)
            if let notice, notice.lane == lane.kind {
                noticeLine(notice)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Whether a lane has the Undo line of your last change, or why a card couldn't move.
    private func hasLines(_ lane: BoardLane, undoRefs: Set<ItemRef>) -> Bool {
        order.lastChange.map { undoRefs.contains($0.ref) } == true || notice?.lane == lane.kind
    }

    /// A finished mission's lane folds to its header, as List's merged line does.
    private func foldedLine(_ mission: OrderMission, isFolded: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if isFolded { unfolded.insert(mission.key) } else { unfolded.remove(mission.key) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(OrderText.folded(mission.steps))
                Image(systemName: "chevron.right")
                    .font(size: 9, weight: .bold)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
            }
            .font(size: 11.5, weight: .medium)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
        .help(isFolded ? "Show its lane" : "Fold its lane")
        .accessibilityLabel(isFolded ? "Show \(OrderText.folded(mission.steps))" : "Hide \(OrderText.folded(mission.steps))")
    }

    private func noticeLine(_ notice: BoardNotice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "nosign")
                .foregroundStyle(.orange)
            Text(notice.text + ".")
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                self.notice = nil
            } label: {
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

    // MARK: Cells

    private func cell(_ lane: BoardLane, stage: PullRequestStage, width: CGFloat, moves: BoardMoves) -> some View {
        let cards = lane.cards(in: stage)
        let target = BoardCell(lane: lane.kind, stage: stage)
        // What dropping the dragged card here would do, to the card as it is now.
        let move = isDragging ? drag.flatMap { moves.card($0.ref, in: lane.kind) }.map { moves.move($0, to: stage, in: lane.kind) } : nil
        let takes = move?.isTaken == true
        let isHovered = hovered == target
        let refusal: String? = if case .refused(let why)? = move { why } else { nil }
        return VStack(alignment: .leading, spacing: 8 * textScale) {
            if stage == .merged, !showsMerged {
                foldedMerged(cards)
            } else {
                ForEach(cards) { card in
                    cardView(card, in: lane, moves: moves)
                }
            }
        }
        // Those that don't take the card dim while you drag it.
        .opacity(isDragging && refusal != nil ? 0.4 : 1)
        .padding(6 * textScale)
        .frame(width: width, alignment: .topLeading)
        .frame(minHeight: 70 * textScale, maxHeight: .infinity, alignment: .top)
        .background(cellBackground(stage, takes: takes, isHovered: isHovered))
        .overlay(alignment: .top) {
            // Why it can't go there, as you hover.
            if isHovered, let refusal {
                Text(refusal)
                    .font(size: 11, weight: .medium)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    )
                    .padding(6)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, on: stage, in: lane, moves: moves)
        } isTargeted: { isOver in
            if isOver {
                hovered = target
            } else if hovered == target {
                hovered = nil
            }
        }
    }

    private func cellBackground(_ stage: PullRequestStage, takes: Bool, isHovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return shape
            .fill(stage.color.opacity(takes ? (isHovered ? 0.24 : 0.14) : 0.06))
            .overlay(shape.strokeBorder(stage.color.opacity(takes ? (isHovered ? 0.9 : 0.55) : 0), lineWidth: isHovered ? 2 : 1.5))
    }

    /// Merged, folded: how many merged in the lane, which a click shows.
    @ViewBuilder
    private func foldedMerged(_ cards: [BoardCard]) -> some View {
        if !cards.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsMerged = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PullRequestStage.merged.color)
                    Text("\(cards.count) merged")
                        .lineLimit(1)
                }
                .font(size: 11.5, weight: .medium)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
            .help(cards.map { [$0.ref.shortOrderLabel, order.name(of: $0.ref)].compactMap { $0 }.joined(separator: " ") }
                .joined(separator: "\n") + "\nClick to show them")
            .accessibilityLabel("\(cards.count) merged")
            .accessibilityHint("Shows them")
        }
    }

    @ViewBuilder
    private func cardView(_ card: BoardCard, in lane: BoardLane, moves: BoardMoves) -> some View {
        if let content = self.card(card) {
            let spot = CardSpot(lane: lane.kind, ref: card.ref)
            BoardCardView(
                card: card, content: content, isNext: board.next[card.stage] == card.ref, isSelected: isSelected(card.ref),
                order: order, now: now, spot: spot, focus: $focused, takesFocus: refocus == spot,
                tookFocus: { if refocus == spot { refocus = nil } },
                select: { select(card.ref) },
                drag: {
                    // As the drag starts: only what it carries drops, and the columns that take it light up.
                    let started = BoardDrag(ref: card.ref)
                    DispatchQueue.main.async {
                        drag = started
                        isDragging = true
                        notice = nil
                    }
                    return started.payload
                },
                move: { forward in keyMove(card.ref, in: lane, forward: forward, moves: moves) },
                setAsNext: setAsNext.flatMap { setAsNext in card.stage == .waits ? { setAsNext(card.ref) } : nil }
            )
        }
    }

    // MARK: Moving

    private func drop(_ items: [String], on stage: PullRequestStage, in lane: BoardLane, moves: BoardMoves) -> Bool {
        let started = drag
        isDragging = false
        hovered = nil
        // Only a card dragged from this board, as it is now: never text dragged in from another app.
        guard let payload = items.first, let (card, move) = moves.drop(payload, of: started, on: stage, in: lane.kind) else {
            return false
        }
        drag = nil
        return apply(move, to: card, in: lane, keepsFocus: focused?.ref == card.ref)
    }

    /// ⌘→ and ⌘← on a card: the next or previous stage you can set, or why it can't go further. The card keeps the
    /// keyboard's focus.
    private func keyMove(_ ref: ItemRef, in lane: BoardLane, forward: Bool, moves: BoardMoves) {
        guard let (card, move) = moves.key(ref, in: lane.kind, forward: forward) else {
            NSSound.beep()
            return
        }
        _ = apply(move, to: card, in: lane, keepsFocus: true)
    }

    private func apply(_ move: BoardMove, to card: BoardCard, in lane: BoardLane, keepsFocus: Bool) -> Bool {
        switch move {
        case .setStage(let stage):
            notice = nil
            // As the row's menu and VoiceOver's action move it, saying where Undo is.
            StageCommand.perform(.move(stage), on: card.ref, order: order, undo: .lane)
        case .setAsNext:
            notice = nil
            setAsNext?(card.ref)
        case .stays:
            return false
        case .refused(let why):
            NSSound.beep()
            SpokenText.announce(why)
            notice = BoardNotice(lane: lane.kind, text: why)
            return false
        }
        if keepsFocus { keepFocus(on: CardSpot(lane: lane.kind, ref: card.ref)) }
        return true
    }

    /// The card keeps the keyboard's focus in its new column: drawn anew there once the board has its new stage, it takes it
    /// as it appears. Should it not be drawn anew, as when nothing changed, it still has it, and isn't owed it later.
    private func keepFocus(on spot: CardSpot) {
        refocus = spot
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if refocus == spot { refocus = nil }
        }
    }

    private func reveal(_ stage: PullRequestStage?, with proxy: ScrollViewProxy) {
        guard let stage else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(ColumnAnchor(stage: stage), anchor: .leading) }
            order.revealedColumn = nil
            flashing = stage
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if flashing == stage { flashing = nil }
            }
        }
    }

    // MARK: Under the board

    @ViewBuilder
    private var notOnBoardLine: some View {
        if let text = BoardText.notOnBoard(notOnBoard) {
            HStack(spacing: 6) {
                Text(text)
                    .foregroundStyle(.secondary)
                    .help(BoardText.notOnBoardHelp)
                if let showByStatus {
                    Button("Show By Status", action: showByStatus)
                        .buttonStyle(.borderless)
                }
            }
            .font(size: 12)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - A card

/// A card on the Board: the page's content, framed in its stage's color, Next on Up Next's, a click showing its details and
/// giving it the keyboard's focus, as a field takes it, whatever the Mac's keyboard navigation: then ⌘→ and ⌘← move it, and
/// Return or Space shows its details. Tab goes from card to card. It drags to another column, and VoiceOver has every move
/// among its actions.
private struct BoardCardView: View {
    let card: BoardCard
    let content: BoardCardContent
    let isNext: Bool
    let isSelected: Bool
    @ObservedObject var order: PullRequestOrder
    let now: Date
    let spot: CardSpot
    var focus: FocusState<CardSpot?>.Binding
    /// Drawn anew in another column by a move it made with the keyboard's focus: it takes the focus back as it appears.
    let takesFocus: Bool
    let tookFocus: () -> Void
    let select: () -> Void
    /// The drag's payload, as it starts.
    let drag: () -> String
    let move: (_ forward: Bool) -> Void
    let setAsNext: (() -> Void)?

    @LocalState private var isHovered = false
    @Environment(\.textScale) private var textScale

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        content.view
            .padding(.leading, 13 * textScale)
            .padding(.trailing, 9 * textScale)
            .padding(.vertical, 9 * textScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassCard(cornerRadius: 10, isHovered: isHovered, raised: true))
            .overlay {
                // Its stage's color on its edge.
                shape
                    .fill(card.stage.color)
                    .mask(alignment: .leading) { Rectangle().frame(width: 4 * textScale) }
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if isNext {
                    Text("Next")
                        .font(size: 10, weight: .bold)
                        .foregroundStyle(card.stage.textColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(card.stage.color.opacity(0.2)))
                        .padding(7 * textScale)
                        .help("Up Next: it comes first in its column")
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isSelected {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .onHover { isHovered = $0 }
            .onTapGesture {
                focus.wrappedValue = spot
                select()
            }
            .contextMenu { content.menu }
            .draggable(drag()) {
                preview
            }
            // As a field takes the keyboard's focus, on a click and with Tab, whatever the Mac's keyboard navigation.
            .focusable(interactions: .edit)
            .focused(focus, equals: spot)
            .onAppear {
                guard takesFocus else { return }
                tookFocus()
                // Once this update is done, which also takes its old card away, and the focus with it.
                DispatchQueue.main.async { focus.wrappedValue = spot }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                move(press.key == .rightArrow)
                return .handled
            }
            .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                select()
                return .handled
            }
            .help("\(content.label)\nClick to see its details. Drag it to another column, or click it and press ⌘→ or ⌘←, to change its stage")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.label)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Shows its details")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
            .accessibilityActions {
                StageAccessibilityActions(ref: card.ref, order: order)
                if let setAsNext {
                    Button("Set as Next to Merge", action: setAsNext)
                }
                Button("Show Details", action: select)
            }
    }

    private var accessibilityValue: String {
        var parts = [StageWords.spoken(card.reading, order: order, now: now)]
        parts += content.details
        if isNext { parts.append("Up Next") }
        return parts.joined(separator: ", ")
    }

    /// What follows the pointer as it's dragged: its number and title, in its stage's color.
    private var preview: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(card.stage.color)
                .frame(width: 8, height: 8)
            Text(content.label)
                .font(size: 12.5, weight: .semibold)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(card.stage.color, lineWidth: 1.5)
                )
        )
    }
}
