import AppKit
import BriefBarCore
import SwiftUI

// By Mission's Board, on Azure DevOps' Pull Requests page: a column for each stage, as a kanban board has them, a lane for
// each mission, and a card for each pull request on your board. Drag a card to another column of its lane to change its
// stage, or move it with ⌘→ and ⌘←; the columns that take it light up as you drag, and those that don't say why as you hover
// them. Its column titles stay at the top as the page scrolls, and the board scrolls sideways when the window is too narrow
// for its columns, which grow with the text.

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

/// A card where it shows: a pull request in two missions' lanes has a card in each.
private struct CardSpot: Hashable {
    var lane: BoardLane.Kind
    var ref: ItemRef
}

/// Where Up Next's "2 more ›" scrolls the Board to.
private struct ColumnAnchor: Hashable {
    var stage: PullRequestStage
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

/// By Mission's Board: Up Next's pull request wears Next in its column, and each mission's lane has its header, its next
/// steps and the Undo line of your last change to one of its stages. With Lanes: None, every card is in one lane.
package struct OrderBoardView: View {
    let board: PullRequestBoard
    /// The missions the page shows, as By Mission lists them, for the lanes' headers.
    let missions: [OrderMission]
    @ObservedObject var order: PullRequestOrder
    /// The kinds of pull request the page lists.
    let kinds: Set<ItemRef.Kind>
    /// The page that lists the missions' other pull requests, "GitHub", and opening it; nil when it can't open.
    let elsewhere: String
    let openElsewhere: (() -> Void)?
    /// The repository most of a mission's pull requests are in, as the page names it.
    let place: (OrderMission) -> String?
    /// A card's content as the page draws it; nil for one it doesn't list.
    let card: (BoardCard) -> BoardCardContent?
    let isSelected: (ItemRef) -> Bool
    let select: (ItemRef) -> Void
    /// Who opened someone else's pull request: why it can't go to Teammate's review says so.
    let author: (ItemRef) -> String?
    /// Set as Next to Merge, which dropping a card from Waits onto Can merge does: nil until you can change missions
    /// yourself, and the Board says what it waits for instead.
    let setAsNext: ((ItemRef) -> Void)?
    /// How many of the page's pull requests aren't on the board.
    let notOnBoard: Int
    /// Lists them By Status; nil where it can't.
    let showByStatus: (() -> Void)?
    let now: Date

    @LocalState private var dragging: BoardCard?
    @LocalState private var hovered: BoardCell?
    @LocalState private var notice: BoardNotice?
    @LocalState private var showsMerged = false
    @LocalState private var unfolded: Set<MissionKey> = []
    @LocalState private var scrollX: CGFloat = 0
    @LocalState private var width: CGFloat = 0
    @LocalState private var flashing: PullRequestStage?
    @LocalState private var isHeaderPinned = false
    @FocusState private var focused: CardSpot?
    @Environment(\.textScale) private var textScale

    package init(
        board: PullRequestBoard, missions: [OrderMission], order: PullRequestOrder, kinds: Set<ItemRef.Kind>, elsewhere: String,
        openElsewhere: (() -> Void)?, place: @escaping (OrderMission) -> String?, card: @escaping (BoardCard) -> BoardCardContent?,
        isSelected: @escaping (ItemRef) -> Bool, select: @escaping (ItemRef) -> Void, author: @escaping (ItemRef) -> String?,
        setAsNext: ((ItemRef) -> Void)?, notOnBoard: Int, showByStatus: (() -> Void)?, now: Date
    ) {
        self.board = board
        self.missions = missions
        self.order = order
        self.kinds = kinds
        self.elsewhere = elsewhere
        self.openElsewhere = openElsewhere
        self.place = place
        self.card = card
        self.isSelected = isSelected
        self.select = select
        self.author = author
        self.setAsNext = setAsNext
        self.notOnBoard = notOnBoard
        self.showByStatus = showByStatus
        self.now = now
    }

    package var body: some View {
        let metrics = BoardMetrics(scale: textScale, available: width, showsMerged: showsMerged)
        VStack(alignment: .leading, spacing: 12) {
            if board.lanes.isEmpty {
                Text("Nothing's on your board yet. Your pull requests, and those you're asked to review, show here by stage.")
                    .font(size: 12.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else {
                // Its column titles stay at the top as the page scrolls.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        lanes(metrics)
                    } header: {
                        columnTitles(metrics)
                    }
                }
            }
            notOnBoardLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A drag that ends anywhere, dropped or not: the columns stop lighting up.
        .task(id: dragging?.ref) {
            while !Task.isCancelled, dragging != nil {
                try? await Task.sleep(for: .milliseconds(200))
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    dragging = nil
                    hovered = nil
                }
            }
        }
    }

    // MARK: Columns

    private func columnTitles(_ metrics: BoardMetrics) -> some View {
        HStack(alignment: .bottom, spacing: metrics.gap) {
            ForEach(PullRequestStage.columns, id: \.self) { stage in
                columnTitle(stage, width: metrics.width(stage))
            }
        }
        .offset(x: -scrollX)
        .frame(width: metrics.visible, alignment: .leading)
        .clipped()
        .padding(.vertical, 6)
        .background {
            // Once it stays at the top, over the cards that scroll under it.
            if isHeaderPinned {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .bottom) { Divider().opacity(0.6) }
                    .padding(.horizontal, -18)
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            // At the page's top, where it stays as the cards scroll under it.
            (proxy.bounds(of: .scrollView)?.minY).map { $0 <= 0.5 } ?? false
        } action: { isHeaderPinned = $0 }
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

    private func lanes(_ metrics: BoardMetrics) -> some View {
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
                        ForEach(board.lanes) { lane in
                            laneView(lane, metrics: metrics)
                        }
                    }
                }
                .padding(.top, 8)
                .frame(width: metrics.content, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(metrics.content > metrics.visible + 1 ? .automatic : .hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollX = x }
            .onChange(of: order.revealedColumn) { _, stage in reveal(stage, with: proxy) }
            .onAppear { reveal(order.revealedColumn, with: proxy) }
        }
    }

    private func laneView(_ lane: BoardLane, metrics: BoardMetrics) -> some View {
        let mission = lane.mission.flatMap { key in missions.first { $0.key == key } }
        let isFolded = mission.map { $0.isFinished && !unfolded.contains($0.key) } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            // The lane's header stays in view as the board scrolls sideways. Every card in one lane has none, but for the
            // Undo line or why a card couldn't move.
            if lane.kind != .all || hasLines(lane) {
                laneHeader(lane, mission: mission, isFolded: isFolded)
                    .frame(width: metrics.visible, alignment: .leading)
                    .offset(x: scrollX)
            }
            if !isFolded {
                HStack(alignment: .top, spacing: metrics.gap) {
                    ForEach(PullRequestStage.columns, id: \.self) { stage in
                        cell(lane, stage: stage, width: metrics.width(stage))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func laneHeader(_ lane: BoardLane, mission: OrderMission?, isFolded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch lane.kind {
            case .mission:
                if let mission {
                    MissionHeader(mission: mission, order: order, place: place(mission))
                    let outside = mission.count(outside: kinds)
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
            StageUndoLine(refs: Set(lane.cards.map(\.ref)), order: order)
                .padding(.horizontal, 4)
            if let notice, notice.lane == lane.kind {
                noticeLine(notice)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Whether a lane has the Undo line of your last change to one of its stages, or why a card couldn't move.
    private func hasLines(_ lane: BoardLane) -> Bool {
        let refs = Set(lane.cards.map(\.ref))
        return order.lastChange.map { refs.contains($0.ref) } == true || notice?.lane == lane.kind
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

    private func cell(_ lane: BoardLane, stage: PullRequestStage, width: CGFloat) -> some View {
        let cards = lane.cards(in: stage)
        let target = BoardCell(lane: lane.kind, stage: stage)
        let move = dragging.map { self.move($0, to: stage, in: lane) }
        let takes = move?.isTaken == true
        let isHovered = hovered == target
        let refusal: String? = if case .refused(let why)? = move { why } else { nil }
        return VStack(alignment: .leading, spacing: 8 * textScale) {
            if stage == .merged, !showsMerged {
                foldedMerged(cards)
            } else {
                ForEach(cards) { card in
                    cardView(card, in: lane)
                }
            }
        }
        // Those that don't take the card dim while you drag it.
        .opacity(dragging != nil && refusal != nil ? 0.4 : 1)
        .padding(6 * textScale)
        .frame(width: width, alignment: .topLeading)
        .frame(minHeight: 70 * textScale, alignment: .top)
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
            drop(items, on: stage, in: lane)
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
    private func cardView(_ card: BoardCard, in lane: BoardLane) -> some View {
        if let content = self.card(card) {
            BoardCardView(
                card: card, content: content, isNext: board.next[card.stage] == card.ref, isSelected: isSelected(card.ref),
                order: order, now: now, spot: CardSpot(lane: lane.kind, ref: card.ref), focus: $focused,
                select: { select(card.ref) },
                drag: {
                    // As the drag starts: the columns that take it light up.
                    DispatchQueue.main.async {
                        dragging = card
                        notice = nil
                    }
                    return card.ref.description
                },
                move: { forward in keyMove(card, in: lane, forward: forward) },
                setAsNext: setAsNext.flatMap { setAsNext in card.stage == .waits ? { setAsNext(card.ref) } : nil }
            )
        }
    }

    // MARK: Moving

    private func move(_ card: BoardCard, to stage: PullRequestStage, in lane: BoardLane) -> BoardMove {
        let sameLane = lane.kind == .all || lane.cards.contains { $0.ref == card.ref }
        return BoardRules.move(
            card, to: stage, sameLane: sameLane, isYours: order.isYours(card.ref), author: author(card.ref),
            missionChanges: setAsNext != nil, missions: missions.filter { $0.contains(card.ref) }
        )
    }

    private func drop(_ items: [String], on stage: PullRequestStage, in lane: BoardLane) -> Bool {
        let dragged = dragging
        dragging = nil
        hovered = nil
        // Only a card of this board: not text dragged in from another app.
        guard let raw = items.first, let ref = ItemRef(raw), board.refs.contains(ref),
              let card = dragged?.ref == ref ? dragged : board.lanes.lazy.compactMap({ $0.cards.first { $0.ref == ref } }).first
        else { return false }
        return apply(move(card, to: stage, in: lane), to: card, in: lane)
    }

    /// ⌘→ and ⌘← on a card: the next or previous stage you can set, or why it can't go further.
    private func keyMove(_ card: BoardCard, in lane: BoardLane, forward: Bool) {
        guard let stage = BoardRules.keyTarget(from: card.stage, forward: forward) else {
            NSSound.beep()
            return
        }
        _ = apply(move(card, to: stage, in: lane), to: card, in: lane)
    }

    private func apply(_ move: BoardMove, to card: BoardCard, in lane: BoardLane) -> Bool {
        switch move {
        case .setStage(let stage):
            notice = nil
            StageCommand.set(stage, of: card.ref, order: order)
            keepFocus(on: card, in: lane)
            return true
        case .setAsNext:
            notice = nil
            setAsNext?(card.ref)
            keepFocus(on: card, in: lane)
            return true
        case .stays:
            return false
        case .refused(let why):
            NSSound.beep()
            SpokenText.announce(why)
            notice = BoardNotice(lane: lane.kind, text: why)
            return false
        }
    }

    /// The card keeps the keyboard's focus in its new column.
    private func keepFocus(on card: BoardCard, in lane: BoardLane) {
        guard focused?.ref == card.ref else { return }
        let spot = CardSpot(lane: lane.kind, ref: card.ref)
        DispatchQueue.main.async { focused = spot }
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

/// A card on the Board: the page's content, framed in its stage's color, Next on Up Next's, a click showing its details. It
/// drags to another column, and moves with ⌘→ and ⌘←; VoiceOver has every move among its actions.
private struct BoardCardView: View {
    let card: BoardCard
    let content: BoardCardContent
    let isNext: Bool
    let isSelected: Bool
    @ObservedObject var order: PullRequestOrder
    let now: Date
    let spot: CardSpot
    var focus: FocusState<CardSpot?>.Binding
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
            .onHover { isHovered = $0 }
            .onTapGesture(perform: select)
            .contextMenu { content.menu }
            .draggable(drag()) {
                preview
            }
            .focusable(interactions: .activate)
            .focused(focus, equals: spot)
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                move(press.key == .rightArrow)
                return .handled
            }
            .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                select()
                return .handled
            }
            .help("\(content.label)\nClick to see its details. Drag it to another column, or press ⌘→ or ⌘←, to change its stage")
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
