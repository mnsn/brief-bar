import AppKit
import BriefBarCore
import SwiftUI

// By Mission's Board, on Azure DevOps' Pull Requests page: a column for each stage, as a kanban board has them, a lane for
// each mission, and a card for each pull request on your board. Drag a card to another column of its lane to change its
// stage, or click it and press ⌘→ or ⌘←; the columns that take it light up as you drag, and those that don't say why as you
// hover them. Its column titles stay at the top as the page scrolls, and the board scrolls sideways when the window is too
// narrow for its columns, which grow with the text. Scrolling redraws only what follows it: the column titles and the lanes'
// headers. On My Work, with + Sprint Tasks, your sprint work has cards of its own (`PullRequestBoard.withWork`): in To start,
// a column before In progress, until it's started, then in In progress, after the pull requests. They don't move: their work
// does, in Azure DevOps.

/// What a page draws on a card, which the Board frames: its content, its menu, and what VoiceOver says of it.
package struct BoardCardContent {
    package var view: AnyView
    package var menu: AnyView
    /// What VoiceOver calls it: "!4102 Retry backoff".
    package var label: String
    /// What else VoiceOver says of it, after its stage: what needs you on it, where it stands in its order.
    package var details: [String]
    /// Its Mission menu, for VoiceOver's actions as its row has them; nil where it has none.
    package var mission: MissionMenuContext?

    package init(view: AnyView, menu: AnyView, label: String, details: [String] = [], mission: MissionMenuContext? = nil) {
        self.view = view
        self.menu = menu
        self.label = label
        self.details = details
        self.mission = mission
    }
}

/// What a page draws of your sprint work on the Board, on My Work with + Sprint Tasks: a work item's card, and the header of a
/// story's lane.
package struct BoardWorkContent {
    /// A work item's card: its content, its menu, and what VoiceOver says of it; nil for one the page doesn't know.
    package var card: (BoardTask) -> BoardCardContent?
    /// The header of a story's lane, for a story with no mission.
    package var story: (ItemRef) -> AnyView
    /// Whether a work item's details show.
    package var isSelected: (ItemRef) -> Bool
    /// Shows a work item's details.
    package var select: (ItemRef) -> Void

    package init(
        card: @escaping (BoardTask) -> BoardCardContent?, story: @escaping (ItemRef) -> AnyView,
        isSelected: @escaping (ItemRef) -> Bool, select: @escaping (ItemRef) -> Void
    ) {
        self.card = card
        self.story = story
        self.isSelected = isSelected
        self.select = select
    }
}

/// A column of a lane.
private struct BoardCell: Hashable {
    var lane: BoardLane.Kind
    var column: BoardColumn
}

extension BoardColumn {
    /// Its title on the Board.
    var title: String {
        switch self {
        case .toStart: BoardText.toStart
        case .stage(let stage): stage.columnTitle
        }
    }

    /// Its color: its stage's; for To start, the gray of the Sprint page's To Do, which is Waits' too: only To start's
    /// dashed ring, in place of a dot, tells them apart, and the two are never side by side.
    var color: Color {
        switch self {
        case .toStart: Color(nsColor: .systemGray)
        case .stage(let stage): stage.color
        }
    }

    /// The column a work item's card is in.
    init(_ column: BoardTask.Column) {
        switch column {
        case .toStart: self = .toStart
        case .inProgress: self = .stage(.inProgress)
        }
    }
}

/// A card where it shows, for the keyboard's focus: a pull request in two missions' lanes has a card in each. It stays the
/// same as the card moves to another column.
private struct CardSpot: Hashable {
    var lane: BoardLane.Kind
    var ref: ItemRef
}

/// Where Up Next's "2 more ›" scrolls the Board to.
private struct ColumnAnchor: Hashable {
    var column: BoardColumn
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
    /// The pull request it's about, and how its stage read then: once that changes, from anywhere, it's said no more; a new
    /// name for a mission its stage's words name is no change (`StageReading.readTheSame`).
    var ref: ItemRef
    var reading: StageReading?
    /// Why it didn't move; false for where it still waits once it did.
    var isRefusal = true
}

/// How wide the Board's columns are: as wide as the page allows, never narrower than their text needs, Merged narrow while
/// it's folded; all of it from the columns it shows.
private struct BoardMetrics {
    let scale: CGFloat
    /// The page's width.
    let available: CGFloat
    /// The columns it shows, from left to right.
    let columns: [BoardColumn]
    let showsMerged: Bool

    var gap: CGFloat { 10 * scale }
    var minimum: CGFloat { 172 * scale }
    var folded: CGFloat { 132 * scale }

    private func isFolded(_ column: BoardColumn) -> Bool {
        column == .stage(.merged) && !showsMerged
    }

    /// The room the gaps between the columns take.
    private var gaps: CGFloat {
        gap * CGFloat(max(0, columns.count - 1))
    }

    var column: CGFloat {
        let foldedCount = CGFloat(columns.filter(isFolded).count)
        let room = available - gaps - folded * foldedCount
        return max(minimum, room / max(1, CGFloat(columns.count) - foldedCount))
    }

    func width(_ column: BoardColumn) -> CGFloat {
        isFolded(column) ? folded : self.column
    }

    var content: CGFloat {
        columns.reduce(gaps) { $0 + width($1) }
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

/// Where the page's top is on the board as the page scrolls, which only the column titles follow, to stay there.
@MainActor
private final class BoardPin: ObservableObject {
    @Published var place = BoardPlace(top: -1, height: 0)
}

/// Where the page's top is on the board: how far below the board's top, -1 while it's above it, and as far as the board's
/// height once the board is above it; and how tall the board is, with its column titles.
private struct BoardPlace: Equatable, Sendable {
    var top: CGFloat
    var height: CGFloat
}

/// The column titles, which stay at the page's top while it shows the board, over the cards that scroll under them, until
/// the board's end, as a lazy stack's pinned header does. Not one: with the board as its one row, a lazy stack misplaces the
/// lanes when the page narrows while it's scrolled down the board, as when the details open beside it, and leaves room
/// above them until the page is back at its top.
private struct PinnedTitles<Content: View>: View {
    @ObservedObject var pin: BoardPin
    let content: Content

    @LocalState private var height: CGFloat = 0

    var body: some View {
        let place = pin.place
        content
            .background {
                // Once they stay at the top, over the cards that scroll under them.
                if place.top > -1 {
                    Rectangle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
                        .padding(.horizontal, -18)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .offset(y: min(max(0, place.top), max(0, place.height - height)))
    }
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

/// By Mission's Board: Up Next's pull request wears Next in its column, with ✎ where you chose it (`UpNextPicks`), and each
/// mission's lane has its header, its next steps and the Undo line of your last change to one of its pull requests, on the
/// board or not. With Lanes: None, every card is in one lane. A change that takes a pull request in no mission off the board
/// keeps a lane for its Undo line.
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
    /// The pull request whose own details show, with nothing over them, such as a linked item's page or a file's: while
    /// they cover the board, ⌘→ and ⌘← move its card, where you see it move. Nil while none show, or something is over them.
    let shownOnTop: ItemRef?
    /// Set as Next to Merge in a mission, which dropping a card from Waits onto Can merge does, saying where its Undo is:
    /// nil where you can't change missions yourself, and the Board says what it waits for instead.
    let setAsNext: ((ItemRef, MissionKey, MissionMenuContext.UndoPlace) -> Void)?
    /// Your sprint work's cards and its stories' lanes' headers, as the page draws them, on My Work with + Sprint Tasks.
    let work: BoardWorkContent?
    /// How many of the page's pull requests aren't on the board.
    let notOnBoard: Int
    /// Lists them By Status; nil where it can't.
    let showByStatus: (() -> Void)?
    let now: Date
    /// A mission's lane came into the page's sight, or left it: Apple Intelligence names the missions on screen.
    let see: (MissionKey, Bool) -> Void
    /// How long a card a key moved is owed the keyboard's focus, for the board to draw it in its new column: until this
    /// ends, as a test ends it itself; nil for the app's wait, `owedFocusWait`.
    let focusWait: (@MainActor () async -> Void)?
    /// The app's wait for that: ten seconds.
    package static let owedFocusWait: Duration = .seconds(10)

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
    @LocalState private var scroll = BoardScroll()
    /// The column titles stay at the page's top, over the cards that scroll under them.
    @LocalState private var pin = BoardPin()
    /// Where each mission's lane starts, for By Mission to show it, as a row's capsule asks.
    @LocalState private var laneTops: [MissionKey: CGFloat] = [:]
    /// The mission a row's capsule asked to show, for a moment, while the board settles.
    @LocalState private var revealing: MissionKey?
    /// Each time the page shows it, for when to stop.
    @LocalState private var revealCount = 0
    @FocusState private var focused: CardSpot?
    /// The card a key, or a drop, just moved while it had the keyboard's focus: drawn anew in its new column, it takes the
    /// focus back as it appears, so that the next key moves it on.
    @LocalState private var refocus = OwedFocus<CardSpot>()
    /// The card that had the keyboard's focus while the board could take it, or that you clicked last: when the details
    /// cover the board, which can't take the focus then, it has it back once they close, and the keys move it meanwhile.
    @LocalState private var lastFocus: CardSpot?
    @LocalState private var keys = BoardKeys()
    @Environment(\.textScale) private var textScale
    /// False while the details of what you clicked cover the board: in a narrow window or at a bigger text size, or while a
    /// file's page in them fills the page (⤢).
    @Environment(\.isEnabled) private var isEnabled

    package init(
        board: PullRequestBoard, missions: [OrderMission], order: PullRequestOrder, elsewhere: String, openElsewhere: (() -> Void)?,
        place: @escaping (OrderMission) -> String?, card: @escaping (BoardCard) -> BoardCardContent?,
        isSelected: @escaping (ItemRef) -> Bool, select: @escaping (ItemRef) -> Void, shownOnTop: ItemRef?,
        setAsNext: ((ItemRef, MissionKey, MissionMenuContext.UndoPlace) -> Void)?, work: BoardWorkContent? = nil, notOnBoard: Int,
        showByStatus: (() -> Void)?, now: Date, see: @escaping (MissionKey, Bool) -> Void = { _, _ in },
        focusWait: (@MainActor () async -> Void)? = nil
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
        self.shownOnTop = shownOnTop
        self.setAsNext = setAsNext
        self.work = work
        self.notOnBoard = notOnBoard
        self.showByStatus = showByStatus
        self.now = now
        self.see = see
        self.focusWait = focusWait
    }

    package var body: some View {
        let metrics = BoardMetrics(scale: textScale, available: width, columns: board.columns, showsMerged: showsMerged)
        let lanes = board.lanes(keepingUndoOf: order.lastStageChange?.ref, missions: missions)
        let moves = BoardMoves(board: board, missions: missions, order: order, missionChanges: setAsNext != nil)
        VStack(alignment: .leading, spacing: 12) {
            if lanes.isEmpty {
                Text(board.showsWork
                    ? "Nothing's on your board yet. Your pull requests, those you're asked to review, and your sprint work show here by stage."
                    : "Nothing's on your board yet. Your pull requests, and those you're asked to review, show here by stage.")
                    .font(size: 12.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else {
                lanesSection(lanes, metrics: metrics, moves: moves)
            }
            notOnBoardLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(alignment: .topLeading) { coveredKeys(lanes, moves: moves) }
        .onChange(of: focused) { _, spot in
            if isEnabled { lastFocus = spot }
        }
        .onChange(of: isEnabled) { _, enabled in
            guard enabled else { return }
            giveFocusBack()
            // The details' line of why a key couldn't move a card goes: the board's own, under its lane, shows again.
            if order.stageRefusal != nil { order.stageRefusal = nil }
        }
        // Each change to a stage, as it comes: once the refused one's changes, from anywhere, as from its stage's menu, the
        // details say why no more, even back in the stage it couldn't leave; nor does its lane. A mission's new name, which
        // its words may say, as where two orders go round, changes no stage.
        .onReceive(order.$stages) { stages in
            if let refusal = order.stageRefusal, !StageReading.readTheSame(stages[refusal.ref], refusal.reading) {
                order.stageRefusal = nil
            }
            if let notice, !StageReading.readTheSame(stages[notice.ref], notice.reading) { self.notice = nil }
        }
        .onDisappear {
            if order.stageRefusal != nil { order.stageRefusal = nil }
        }
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

    /// The column titles over the lanes, with where each mission's lane starts. The titles stay at the page's top while it
    /// shows the board (`PinnedTitles`).
    private func lanesSection(_ lanes: [BoardLane], metrics: BoardMetrics, moves: BoardMoves) -> some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                PinnedTitles(pin: pin, content: columnTitles(metrics))
                    // Over the cards that scroll under them.
                    .zIndex(1)
                lanesView(lanes, metrics: metrics, moves: moves)
            }
            // Each time the page scrolls while its top is on the board, but for the titles only.
            .onGeometryChange(for: BoardPlace.self) { geometry in
                let height = geometry.size.height
                return BoardPlace(top: min(max(-1, geometry.bounds(of: .scrollView)?.minY ?? -1), height), height: height)
            } action: { pin.place = $0 }
            .overlay(alignment: .topLeading) { missionAnchors(lanes, proxy: proxy) }
            .onAppear { takeReveal(order.revealed, with: proxy) }
            .onChange(of: order.revealed) { _, key in takeReveal(key, with: proxy) }
        }
    }

    // MARK: Keys while the details cover the board

    /// While the details cover the board, its cards can't have the keyboard's focus: ⌘→ and ⌘← move the card of the pull
    /// request whose own details show. Not while a page is over them, such as a linked pull request's, whose card isn't the
    /// one they'd move, or a file's, which doesn't show its stage: the keys are the page's then.
    private func coveredKeys(_ lanes: [BoardLane], moves: BoardMoves) -> some View {
        let move: (@MainActor (Bool) -> Void)? = if isEnabled || shownSpot(in: lanes) == nil {
            nil
        } else {
            { forward in moveShown(forward: forward, lanes: lanes, moves: moves) }
        }
        return BoardKeysView(keys: keys, move: move)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// Once the details that covered the board close, or go beside it: the card that had the keyboard's focus has it back,
    /// once it can take it, unless you're typing in a field.
    private func giveFocusBack() {
        guard let spot = lastFocus else { return }
        DispatchQueue.main.async {
            if isEnabled, !keys.isEditingText { focused = spot }
        }
    }

    // MARK: Columns

    private func columnTitles(_ metrics: BoardMetrics) -> some View {
        FollowsScroll(scroll: scroll, direction: -1, content: HStack(alignment: .bottom, spacing: metrics.gap) {
            ForEach(board.columns, id: \.self) { column in
                columnTitle(column, width: metrics.width(column))
            }
        })
        // As wide as the page, whatever the columns need: they scroll sideways under it.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        // To start isn't a stage.
        .accessibilityLabel(board.showsWork ? "Columns" : "Stages")
    }

    @ViewBuilder
    private func columnTitle(_ column: BoardColumn, width: CGFloat) -> some View {
        let count = board.count(of: column)
        let label = HStack(spacing: 6 * textScale) {
            // `font(size:)` grows with the text size itself.
            if column == .toStart {
                // Not started, as the Sprint page's To Do says it.
                Image(systemName: "circle.dashed")
                    .font(size: 9, weight: .heavy)
                    .foregroundStyle(column.color)
                    .frame(width: 8 * textScale, height: 8 * textScale)
            } else if column == .stage(.approved) {
                // Its seal, not a dot: as some see colors, its mint reads as Waits' grey or Can merge's green.
                Image(systemName: PullRequestStage.approved.symbol)
                    .font(size: 10, weight: .bold)
                    .foregroundStyle(column.color)
                    .frame(width: 8 * textScale, height: 8 * textScale)
            } else {
                Circle()
                    .fill(column.color)
                    .frame(width: 8 * textScale, height: 8 * textScale)
            }
            Text(column.title)
                .font(size: 13, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            Text("\(count)")
                .font(size: 12.5, weight: .medium)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if column == .stage(.merged) {
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
                .fill(column.color.opacity(column.stage != nil && flashing == column.stage ? 0.22 : 0))
        )
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(column.color)
                .frame(height: 3 * textScale)
        }
        .contentShape(Rectangle())
        if column == .stage(.merged) {
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
                .help(help(column))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(column.stage?.title ?? column.title), \(count)")
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// What a column holds, for its title's tooltip: In progress also your sprint work that has started, while the board
    /// shows it.
    private func help(_ column: BoardColumn) -> String {
        switch column {
        case .toStart: BoardText.toStartHelp
        case .stage(.inProgress) where board.showsWork:
            Self.help(.inProgress) + "; then your sprint work that has started, with no pull request on your board"
        case .stage(let stage): Self.help(stage)
        }
    }

    /// What a column holds, for its title's tooltip.
    static func help(_ stage: PullRequestStage) -> String {
        switch stage {
        case .inProgress: "Its work isn't done: a draft, or a session still writes it before anyone else reviews it"
        case .yourReview: "You review it next"
        case .teammateReview: "Others review it next: yours that wait for reviewers, and those you finished reviewing"
        case .approved: "The reviewers Azure DevOps requires approved it, but it can't complete it yet: its card says why"
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
                        ForEach(board.columns, id: \.self) { column in
                            Color.clear
                                .frame(width: metrics.width(column), height: 0)
                                .id(ColumnAnchor(column: column))
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
            .onAppear { reveal(order.revealedColumn, with: proxy) }
        }
    }

    /// Where each mission's lane starts, as By Mission shows a mission a row's capsule asks for: from the board's top, where
    /// its column titles start, so that with the anchor at the page's top, as far above the lane as they're tall, the
    /// titles that stay there are just over the lane, its first too. Outside the board's sideways scroll, so that it
    /// scrolls the page. The page scrolls to the one it shows once that anchor is laid out where its lane starts, and again
    /// as it moves while the board settles.
    private func missionAnchors(_ lanes: [BoardLane], proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(lanes.compactMap(\.mission).map(LaneAnchor.init), id: \.self) { anchor in
                VStack(spacing: 0) {
                    Color.clear.frame(width: 1, height: max(0, laneTops[anchor.mission] ?? 0))
                    Color.clear.frame(width: 1, height: 1).id(anchor.mission)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                    if revealing == anchor.mission { revealMission(with: proxy) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Takes the mission a row's capsule asks By Mission to show, and shows it: within a few seconds, for a lane that isn't
    /// laid out yet, as when the Board just showed a lane for each mission for it.
    private func takeReveal(_ key: MissionKey?, with proxy: ScrollViewProxy) {
        guard let key else { return }
        revealing = key
        endReveal(of: key, after: .seconds(5))
        revealMission(with: proxy)
        DispatchQueue.main.async {
            if order.revealed == key { order.revealed = nil }
        }
    }

    /// The page scrolls to the lane of the mission it shows, once the lane is laid out, and again as the board settles, until
    /// it has kept still for a second. Without animation, as the page has just changed from By Status to By Mission under it.
    private func revealMission(with proxy: ScrollViewProxy) {
        guard let key = revealing, laneTops[key] != nil else { return }
        endReveal(of: key, after: .seconds(1))
        DispatchQueue.main.async { proxy.scrollTo(key, anchor: .top) }
    }

    /// Stops showing that mission after a while, unless the page shows it again meanwhile.
    private func endReveal(of key: MissionKey, after delay: Duration) {
        revealCount += 1
        let count = revealCount
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if revealCount == count, revealing == key { revealing = nil }
        }
    }

    private func laneView(_ lane: BoardLane, metrics: BoardMetrics, moves: BoardMoves) -> some View {
        let mission = lane.mission.flatMap { key in missions.first { $0.key == key } }
        // A finished mission's lane folds, but not while it holds your work's cards, which it would hide.
        let isFolded = mission.map { $0.isFinished && lane.tasks.isEmpty && !unfolded.contains($0.key) } ?? false
        let undoRefs = board.undoRefs(of: lane, missions: missions, changed: order.lastStageChange?.ref)
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
                    ForEach(board.columns, id: \.self) { column in
                        cell(lane, column: column, width: metrics.width(column), moves: moves)
                    }
                }
                // Its columns are as tall as its tallest, so that each is as big a place to drop a card.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .onSightChange { isInSight in
            if let key = lane.mission { see(key, isInSight) }
        }
    }

    @ViewBuilder
    private func laneHeader(_ lane: BoardLane, mission: OrderMission?, isFolded: Bool, undoRefs: Set<ItemRef>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch lane.kind {
            case .mission:
                if let mission {
                    MissionHeader(mission: mission, order: order, place: place(mission))
                    SplitSuggestionView(mission: mission, order: order, select: select)
                    let outside = mission.count(outside: board.kinds)
                    if outside > 0 {
                        OrderElsewhereLine(count: outside, elsewhere: elsewhere, open: openElsewhere)
                            .padding(.leading, 4)
                    }
                    if mission.isFinished {
                        foldedLine(mission, isFolded: isFolded, canFold: lane.tasks.isEmpty)
                    }
                    MissionNextStepsLine(lane: lane, order: order, select: select)
                        .padding(.leading, 4)
                }
            case .story(let story):
                work?.story(story)
            case .notInAMission:
                Text("Not in a mission")
                    .font(size: 15, weight: .semibold)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
            case .all:
                EmptyView()
            }
            if let key = lane.mission, order.said.contains(where: { $0.mission == key }) {
                OrderUndoLine(order: order, in: key)
                    .padding(.horizontal, 4)
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
        order.lastStageChange.map { undoRefs.contains($0.ref) } == true || notice?.lane == lane.kind
    }

    /// A finished mission's lane folds to its header, as List's merged line does.
    /// - Parameter canFold: false for a lane with your work's cards, which doesn't fold: the line only says it's finished.
    @ViewBuilder
    private func foldedLine(_ mission: OrderMission, isFolded: Bool, canFold: Bool) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(OrderText.folded(mission.steps))
            if canFold {
                Image(systemName: "chevron.right")
                    .font(size: 9, weight: .bold)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
            }
        }
        .font(size: 11.5, weight: .medium)
        .foregroundStyle(.secondary)
        if canFold {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isFolded { unfolded.insert(mission.key) } else { unfolded.remove(mission.key) }
                }
            } label: {
                label
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help(isFolded ? "Show its lane" : "Fold its lane")
            .accessibilityLabel(isFolded ? "Show \(OrderText.folded(mission.steps))" : "Hide \(OrderText.folded(mission.steps))")
        } else {
            label
                .padding(.leading, 4)
                .accessibilityElement(children: .combine)
        }
    }

    private func noticeLine(_ notice: BoardNotice) -> some View {
        StageRefusalLine.Line(text: notice.text, isRefusal: notice.isRefusal) { self.notice = nil }
    }

    // MARK: Cells

    private func cell(_ lane: BoardLane, column: BoardColumn, width: CGFloat, moves: BoardMoves) -> some View {
        let cards = column.stage.map(lane.cards(in:)) ?? []
        // Your sprint work's own cards, after the pull requests'.
        let tasks = lane.tasks.filter { BoardColumn($0.column) == column }
        let target = BoardCell(lane: lane.kind, column: column)
        // What dropping the dragged card here would do, to the card as it is now.
        let move = isDragging ? drag.flatMap { moving($0.ref, to: column, in: lane, moves: moves) } : nil
        let takes = move?.isTaken == true
        let isHovered = hovered == target
        let refusal: String? = if case .refused(let why)? = move { why } else { nil }
        return VStack(alignment: .leading, spacing: 8 * textScale) {
            if column == .stage(.merged), !showsMerged {
                foldedMerged(cards)
            } else {
                ForEach(cards) { card in
                    cardView(card, in: lane, moves: moves)
                }
                ForEach(tasks) { task in
                    taskView(task, in: lane)
                }
            }
        }
        // Those that don't take the card dim while you drag it.
        .opacity(isDragging && refusal != nil ? 0.4 : 1)
        .padding(6 * textScale)
        .frame(width: width, alignment: .topLeading)
        .frame(minHeight: 70 * textScale, maxHeight: .infinity, alignment: .top)
        .background(cellBackground(column, takes: takes, isHovered: isHovered))
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
            drop(items, on: column, in: lane, moves: moves)
        } isTargeted: { isOver in
            if isOver {
                hovered = target
            } else if hovered == target {
                hovered = nil
            }
        }
    }

    private func cellBackground(_ column: BoardColumn, takes: Bool, isHovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return shape
            .fill(column.color.opacity(takes ? (isHovered ? 0.24 : 0.14) : 0.06))
            .overlay(shape.strokeBorder(column.color.opacity(takes ? (isHovered ? 0.9 : 0.55) : 0), lineWidth: isHovered ? 2 : 1.5))
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
                card: card, content: content, nexts: UpNextSlot.allCases.filter { board.next[$0] == card.ref },
                picked: Set(board.picked.filter { $0.value == card.ref }.keys), isSelected: isSelected(card.ref),
                order: order, now: now, spot: spot, focus: $focused, takesFocus: refocus.spot == spot,
                tookFocus: { refocus.took(spot) }, mayTakeFocus: { !keys.isEditingText },
                select: {
                    // A click gives it the keyboard's focus, which it has back once its details close, should they cover
                    // the board.
                    lastFocus = spot
                    select(card.ref)
                },
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
                move: { forward in keyMove(card.ref, in: lane.kind, forward: forward, moves: moves) },
                setAsNext: Self.setAsNext(card, in: lane.kind, moves: moves, with: setAsNext)
            )
        }
    }

    /// A work item's own card, which shows its details as a pull request's does, but doesn't move: ⌘→ and ⌘← say why.
    @ViewBuilder
    private func taskView(_ task: BoardTask, in lane: BoardLane) -> some View {
        if let work, let content = work.card(task) {
            let spot = CardSpot(lane: lane.kind, ref: task.ref)
            BoardTaskCardView(
                task: task, content: content, isSelected: work.isSelected(task.ref), spot: spot, focus: $focused,
                select: {
                    lastFocus = spot
                    work.select(task.ref)
                },
                drag: {
                    // As a pull request's card starts, for the columns to say why they don't take it.
                    let started = BoardDrag(ref: task.ref)
                    DispatchQueue.main.async {
                        drag = started
                        isDragging = true
                        notice = nil
                    }
                    return started.payload
                },
                move: { refuse(BoardText.workStays, about: task.ref, in: lane.kind) }
            )
        }
    }

    /// Set as Next to Merge for a card that waits, as dropping it onto Can merge and ⌘← do, for VoiceOver's action: in its
    /// lane's mission, where that one holds it, with its Undo there, or at the top with a lane for every card. Nil where the
    /// Board wouldn't take it there, such as for one that doesn't wait, one that waits in another of its missions, or where
    /// you can't change missions yourself.
    package static func setAsNext(
        _ card: BoardCard, in lane: BoardLane.Kind, moves: BoardMoves,
        with setAsNext: ((ItemRef, MissionKey, MissionMenuContext.UndoPlace) -> Void)?
    ) -> (() -> Void)? {
        guard let setAsNext, case .setAsNext(let mission) = moves.move(card, to: .canMerge, in: lane) else { return nil }
        return { setAsNext(card.ref, mission, .onBoard(moves.board.mode)) }
    }

    // MARK: Moving

    private func drop(_ items: [String], on column: BoardColumn, in lane: BoardLane, moves: BoardMoves) -> Bool {
        let started = drag
        isDragging = false
        hovered = nil
        // Only a card dragged from this board, as it is now: never text dragged in from another app.
        guard let payload = items.first, let ref = started?.ref(dropped: payload),
              let outcome = moving(ref, to: column, in: lane, moves: moves) else {
            return false
        }
        drag = nil
        guard let stage = column.stage, let (card, move) = moves.drop(payload, of: started, on: stage, in: lane.kind) else {
            // A work item's card, or a pull request's on To start, stays where it is.
            if case .refused(let why) = outcome { refuse(why, about: ref, in: lane.kind) }
            return false
        }
        return apply(move, to: card, in: lane.kind, keepsFocus: focused?.ref == card.ref)
    }

    /// What dropping a card on a column of a lane does, to the card as it is now: a work item's stays where its work puts it,
    /// and To start takes no pull request. Nil for a card that left the board.
    private func moving(_ ref: ItemRef, to column: BoardColumn, in lane: BoardLane, moves: BoardMoves) -> BoardMove? {
        if let task = board.lanes.lazy.flatMap(\.tasks).first(where: { $0.ref == ref }) {
            let stays = BoardColumn(task.column) == column && lane.tasks.contains { $0.ref == ref }
            return stays ? .stays : .refused(BoardText.workStays)
        }
        guard let card = moves.card(ref, in: lane.kind) else { return nil }
        guard let stage = column.stage else { return .refused(BoardText.toStartTakesNoPullRequest) }
        return moves.move(card, to: stage, in: lane.kind)
    }

    /// Why a card can't go where you moved it: a beep, which VoiceOver says, and its lane says until its stage changes.
    private func refuse(_ why: String, about ref: ItemRef, in lane: BoardLane.Kind) {
        ThisMac.beep()
        SpokenText.announce(why)
        say(why, about: ref, in: lane)
    }

    /// ⌘→ and ⌘← on a card: the next or previous stage you can set, or why it can't go further. The card keeps the
    /// keyboard's focus, where the board can take it.
    private func keyMove(_ ref: ItemRef, in lane: BoardLane.Kind, forward: Bool, moves: BoardMoves, keepsFocus: Bool = true) {
        guard let (card, move) = moves.key(ref, in: lane, forward: forward) else {
            ThisMac.beep()
            return
        }
        _ = apply(move, to: card, in: lane, keepsFocus: keepsFocus)
    }

    /// ⌘→ and ⌘← while the details cover the board, which can't take the keyboard's focus then: on the card of the pull
    /// request whose own details show, as its own keys would. That card has the focus once they close.
    private func moveShown(forward: Bool, lanes: [BoardLane], moves: BoardMoves) {
        guard let spot = shownSpot(in: lanes) else { return }
        lastFocus = spot
        keyMove(spot.ref, in: spot.lane, forward: forward, moves: moves, keepsFocus: false)
    }

    /// The card of the pull request whose own details show, with nothing over them: in the lane of the card you clicked,
    /// where it has it, else in the lane of the mission whose order holds it, where ⌘← sets it as next to merge, as its card
    /// in Up Next and with a lane for every card is that one's, else in the first that has it; nil for one that isn't on the
    /// board, and while something is over them.
    private func shownSpot(in lanes: [BoardLane]) -> CardSpot? {
        guard let shown = shownOnTop else { return nil }
        if let spot = lastFocus, spot.ref == shown,
           lanes.contains(where: { $0.kind == spot.lane && $0.cards.contains { $0.ref == shown } }) {
            return spot
        }
        let having = lanes.filter { $0.cards.contains { $0.ref == shown } }
        let holder = StageOrder.holders(of: shown, in: missions).first
        let lane = having.first { holder != nil && $0.mission == holder } ?? having.first
        return lane.map { CardSpot(lane: $0.kind, ref: shown) }
    }

    private func apply(_ move: BoardMove, to card: BoardCard, in lane: BoardLane.Kind, keepsFocus: Bool) -> Bool {
        switch move {
        case .setStage(let stage):
            notice = nil
            // As the row's menu and VoiceOver's action move it, saying where Undo is.
            StageCommand.perform(.move(stage), on: card.ref, order: order, undo: .lane)
        case .setAsNext(let mission):
            guard let setAsNext else { return false }
            notice = nil
            // Its Undo is beside its mission in the details while they cover the board.
            setAsNext(card.ref, mission, isEnabled ? .onBoard(board.mode) : .details)
            // Another mission's order that holds it too keeps it waiting: the lane says where, and what frees it, as
            // VoiceOver hears it; not where BriefBar refused the change, which says why itself.
            if let still = order.stillWaits(card.ref, nextIn: mission) {
                say(still, about: card.ref, in: lane, isRefusal: false)
            }
        case .stays:
            return false
        case .refused(let why):
            refuse(why, about: card.ref, in: lane)
            return false
        }
        if keepsFocus { keepFocus(on: CardSpot(lane: lane, ref: card.ref), leaving: card.stage) }
        return true
    }

    /// Why a card didn't move, or where it still waits once it did, under its lane until its stage changes; and while the
    /// details cover the board, which hides that line, under its stage in them.
    private func say(_ why: String, about ref: ItemRef, in lane: BoardLane.Kind, isRefusal: Bool = true) {
        let reading = order.stage(of: ref)
        notice = BoardNotice(lane: lane, text: why, ref: ref, reading: reading, isRefusal: isRefusal)
        if !isEnabled, let reading {
            order.stageRefusal = StageRefusal(ref: ref, why: why, reading: reading, isRefusal: isRefusal)
        }
    }

    /// The card keeps the keyboard's focus as a move takes it to another column: drawn anew there, it takes the focus back
    /// as it appears, however long the board takes to draw it, unless another card, or a field you type in, has it by then.
    /// One the move leaves in its column, as one that still waits, isn't drawn anew and keeps it; one the move takes off the
    /// board has nowhere to take it back: neither is owed it. Should the board not draw it in its new column within ten
    /// seconds, as in a lane you fold, it isn't owed it later.
    private func keepFocus(on spot: CardSpot, leaving column: PullRequestStage) {
        guard Self.owesFocus(after: order.stage(of: spot.ref), leaving: column) else {
            refocus.took(spot)
            return
        }
        let move = refocus.owe(spot)
        Task { @MainActor [focusWait] in
            if let focusWait {
                await focusWait()
            } else {
                try? await Task.sleep(for: Self.owedFocusWait)
            }
            refocus.waitEnded(move)
        }
    }

    /// Whether a move owes its card the keyboard's focus: where it takes it to another column of the board, where it's
    /// drawn anew. Not one it leaves in its column, as one that still waits, which keeps it, nor one it takes off the board.
    /// - Parameter reading: its stage once moved.
    package static func owesFocus(after reading: StageReading?, leaving column: PullRequestStage) -> Bool {
        guard let reading else { return false }
        return reading.isOnBoard && reading.stage != column
    }

    private func reveal(_ stage: PullRequestStage?, with proxy: ScrollViewProxy) {
        guard let stage else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(ColumnAnchor(column: .stage(stage)), anchor: .leading) }
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

/// A card on the Board: the page's content, framed in its stage's color, Next on its column's Up Next, Fix next on Fix
/// next's, wherever it is, with ✎ where you chose it, a click showing its details and giving it the keyboard's focus, as a
/// field takes it, whatever the Mac's keyboard navigation: then ⌘→ and ⌘← move it, and Return or Space shows its details.
/// Tab goes from card to card. It drags to another column, and VoiceOver has every move among its actions, and Make Next.
private struct BoardCardView: View {
    let card: BoardCard
    let content: BoardCardContent
    /// The Up Next slots it's the pull request of: Fix next's, and its column's.
    let nexts: [UpNextSlot]
    /// Of those, the ones you chose it for (`UpNextPicks`).
    let picked: Set<UpNextSlot>
    let isSelected: Bool
    @ObservedObject var order: PullRequestOrder
    let now: Date
    let spot: CardSpot
    var focus: FocusState<CardSpot?>.Binding
    /// Drawn anew in another column by a move it made with the keyboard's focus: it takes the focus back as it appears.
    let takesFocus: Bool
    let tookFocus: () -> Void
    /// Whether it may take the focus back now: not from a field you type in.
    let mayTakeFocus: () -> Bool
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
                if !nexts.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(nexts) { slot in
                            badge(slot)
                        }
                    }
                    .padding(7 * textScale)
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
                // Once this update is done, which also takes its old card away, and the focus with it: unless another card,
                // or a field you type in, took the keyboard while the board drew it here.
                DispatchQueue.main.async {
                    guard focus.wrappedValue == nil || focus.wrappedValue == spot, mayTakeFocus() else { return }
                    focus.wrappedValue = spot
                }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                // ⌘ alone, as the board's key monitor takes it while the details cover the board: ⇧⌘→ is another shortcut.
                guard press.modifiers.isCommandAlone else { return .ignored }
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
                if let slot = UpNextSlot.of(card) {
                    if picked.contains(slot) {
                        Button("Let BriefBar Choose Next") { order.letBriefBarChoose(slot) }
                    } else {
                        Button("Make Next") { order.pickNext(card.ref, in: slot) }
                    }
                }
                Button("Show Details", action: select)
            }
            // Its Mission menu's, as its row has them; but for one that waits, Set as Next to Merge is the Board's, above,
            // only where its lane's mission holds it.
            .missionActions(card.ref, context: content.mission, offersNext: card.stage != .waits)
    }

    /// Next, or Fix next, in its slot's color, with ✎ where you chose it.
    private func badge(_ slot: UpNextSlot) -> some View {
        let isPicked = picked.contains(slot)
        return HStack(spacing: 2) {
            if isPicked {
                Image(systemName: "pencil")
            }
            Text(slot == .fix ? slot.title : "Next")
        }
        .font(size: 10, weight: .bold)
        .foregroundStyle(slot.stage.textColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(slot.stage.color.opacity(0.2)))
        .help(Self.help(slot, isPicked: isPicked))
    }

    static func help(_ slot: UpNextSlot, isPicked: Bool) -> String {
        switch (slot, isPicked) {
        case (.fix, true): "Fix next: you chose it, until it moves on"
        case (.fix, false): "Fix next: it needs you first, of every column"
        case (_, true): "Up Next: you chose it, until it moves on"
        case (_, false): "Up Next: it comes first in its column"
        }
    }

    private var accessibilityValue: String {
        var parts = [StageWords.spoken(card.reading, order: order, now: now)]
        parts += content.details
        for slot in nexts {
            let name = slot == .fix ? "Fix next" : "Up Next"
            parts.append(picked.contains(slot) ? "\(name), you chose it" : name)
        }
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

/// A work item's own card on the Board, on My Work with + Sprint Tasks: the page's content, framed in its column's color, a
/// click showing its details and giving it the keyboard's focus, as a pull request's card does. It doesn't move, as its work
/// does in Azure DevOps: ⌘→ and ⌘←, and dropping it on another column, say why.
private struct BoardTaskCardView: View {
    let task: BoardTask
    let content: BoardCardContent
    let isSelected: Bool
    let spot: CardSpot
    var focus: FocusState<CardSpot?>.Binding
    let select: () -> Void
    /// The drag's payload, as it starts.
    let drag: () -> String
    /// ⌘→ or ⌘←: why it doesn't move.
    let move: () -> Void

    @LocalState private var isHovered = false
    @Environment(\.textScale) private var textScale

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private var column: BoardColumn {
        BoardColumn(task.column)
    }

    var body: some View {
        content.view
            .padding(.leading, 13 * textScale)
            .padding(.trailing, 9 * textScale)
            .padding(.vertical, 9 * textScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassCard(cornerRadius: 10, isHovered: isHovered, raised: true))
            .overlay {
                // Its column's color on its edge.
                shape
                    .fill(column.color)
                    .mask(alignment: .leading) { Rectangle().frame(width: 4 * textScale) }
                    .allowsHitTesting(false)
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
            .focusable(interactions: .edit)
            .focused(focus, equals: spot)
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                guard press.modifiers.isCommandAlone else { return .ignored }
                move()
                return .handled
            }
            .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                select()
                return .handled
            }
            .help("\(content.label)\nClick to see its details. It moves by itself, as its work goes on in Azure DevOps")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.label)
            .accessibilityValue(([column.stage?.title ?? column.title] + content.details).joined(separator: ", "))
            .accessibilityHint("Shows its details")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
            .accessibilityActions {
                Button("Show Details", action: select)
            }
    }

    /// What follows the pointer as it's dragged: its name and title, in its column's color.
    private var preview: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(column.color)
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
                        .strokeBorder(column.color, lineWidth: 1.5)
                )
        )
    }
}

/// Make Next, in a Board card's menu: chooses its pull request for its Up Next slot, which shows it, first in its column,
/// until it moves on (`UpNextPicks`); checked once you chose it, when it gives the slot back to BriefBar's order. Nothing
/// for a card in no slot, such as a draft, or one that merged.
package struct MakeNextToggle: View {
    let card: BoardCard
    @ObservedObject var order: PullRequestOrder

    package init(card: BoardCard, order: PullRequestOrder) {
        self.card = card
        self.order = order
    }

    package var body: some View {
        if let slot = UpNextSlot.of(card) {
            Toggle("Make Next", isOn: Binding(get: { order.picks[slot] == card.ref }, set: { on in
                if on {
                    order.pickNext(card.ref, in: slot)
                } else {
                    order.letBriefBarChoose(slot)
                }
            }))
        }
    }
}
