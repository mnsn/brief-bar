import AppKit
import BriefBarCore
import SwiftUI

// By Mission's Board, on Azure DevOps' Pull Requests page: a column for each stage, as a kanban board has them, a lane for
// each mission, and a card for each pull request on your board. Drag a card to another column of its lane to change its
// stage, or click it and press ⌘→ or ⌘←; the columns that take it light up as you drag, and those that don't say why as you
// hover them. Its column titles stay at the top as the page scrolls. A click on a column's title folds it to a thin strip,
// with its count, in a pill where something in it needs you, and a click on the strip opens it; BriefBar folds the rest
// itself (`BoardFolding`): a column with no cards, and where the window is too narrow for the open columns, which grow with
// the text, the least needed. Only then does the board scroll sideways. Scrolling redraws only what follows it: the column
// titles and the lanes' headers. On My Work, with + Sprint Tasks, your sprint work has cards of its own
// (`PullRequestBoard.withWork`): in To start, a column before In progress, until it's started, then in In progress, after
// the pull requests. They don't move: their work does, in Azure DevOps.

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

    /// Its color for words, as its stage's is (`PullRequestStage.textColor`); To start's is Waits' gray.
    var textColor: Color {
        switch self {
        case .toStart: PullRequestStage.waits.textColor
        case .stage(let stage): stage.textColor
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

/// The column a card you moved with a key went to, while it keeps the keyboard's focus, or another card in that column has
/// it since: open for the moment, folded or not, so that the next key moves it on from there.
private struct KeyOpened: Equatable {
    var column: BoardColumn
    var spot: CardSpot
}

/// What decides how long the column a key moved a card to stays open: which card has the keyboard's focus, whether the
/// board can take it, which card a move still owes it, and that column.
private struct KeyMoment: Equatable {
    var focused: CardSpot?
    var isEnabled: Bool
    var owed: CardSpot?
    var opened: KeyOpened?
}

/// How wide the Board's columns are (`BoardWidths`): an open one as wide as the page allows, never narrower than its cards
/// need, and a folded one a strip; all of it from the columns it shows, and those that show folded.
private struct BoardMetrics {
    let widths: BoardWidths
    /// The columns it shows, from left to right.
    let columns: [BoardColumn]
    let folding: BoardFolding
    private let folded: Set<BoardColumn>
    /// An open column's width.
    let open: CGFloat

    init(widths: BoardWidths, columns: [BoardColumn], folding: BoardFolding) {
        self.widths = widths
        self.columns = columns
        self.folding = folding
        folded = Set(folding.folded.keys)
        open = widths.open(columns, folded: folded)
    }

    func isFolded(_ column: BoardColumn) -> Bool {
        folded.contains(column)
    }

    /// Every column shows folded: none is open to set a lane's height.
    var isAllFolded: Bool {
        columns.allSatisfy(folded.contains)
    }

    func width(_ column: BoardColumn) -> CGFloat {
        isFolded(column) ? widths.strip : open
    }

    /// The room after a column, before the next: less beside a strip.
    func gap(after column: BoardColumn) -> CGFloat {
        widths.gap(after: column, in: columns, folded: folded)
    }

    var content: CGFloat {
        columns.reduce(0) { $0 + width($1) + gap(after: $1) }
    }

    /// What shows of the board at once: the page's width, once it's known.
    var visible: CGFloat {
        widths.available > 0 ? widths.available : content
    }

    /// How wide the lanes are: their columns, but never narrower than the page, so that a lane's header has the page's
    /// width though every column is folded.
    var lanes: CGFloat {
        max(content, visible)
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
    /// How long the column a key opened stays open once no card has the keyboard's focus, as when you click elsewhere: the
    /// app's half second, `foldBackWait`, or a test's own, where the main actor's turns can come later than that.
    let keyMomentWait: Duration
    /// The app's wait for that: half a second.
    package static let foldBackWait: Duration = .milliseconds(500)

    /// The card you drag, or dragged last: only what this drag carries drops.
    @LocalState private var drag: BoardDrag?
    /// A card is being dragged now: the columns that take it light up.
    @LocalState private var isDragging = false
    @LocalState private var hovered: BoardCell?
    /// The strip a card you drag hovers, which springs open if it stays there, as Finder's folders do.
    @LocalState private var springing: BoardCell?
    /// The folded columns a drag sprang open, until it ends.
    @LocalState private var sprung: Set<BoardColumn> = []
    /// The column a card you moved with a key went to, open while it keeps the keyboard's focus.
    @LocalState private var keyOpened: KeyOpened?
    /// The folded columns Up Next's "2 more ›", or My Work's Show Them, opened, for the moment: until you fold them, or the
    /// board goes.
    @LocalState private var revealedOpen: Set<BoardColumn> = []
    @LocalState private var notice: BoardNotice?
    @LocalState private var unfolded: Set<MissionKey> = []
    @LocalState private var width: CGFloat = 0
    @LocalState private var flashing: BoardColumn?
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
        focusWait: (@MainActor () async -> Void)? = nil, keyMomentWait: Duration = OrderBoardView.foldBackWait
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
        self.keyMomentWait = keyMomentWait
    }

    package var body: some View {
        let metrics = currentMetrics()
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
        // Once the drag ends, the columns it sprang open fold back, as they were.
        .onChange(of: isDragging) { _, dragging in
            guard !dragging else { return }
            springing = nil
            if !sprung.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) { sprung = [] }
            }
        }
        // A strip the dragged card hovers springs open once it has stayed there a moment.
        .task(id: springing) {
            guard let cell = springing else { return }
            try? await Task.sleep(for: Self.springDelay)
            guard !Task.isCancelled, springing == cell, isDragging else { return }
            _ = withAnimation(.easeOut(duration: 0.15)) { sprung.insert(cell.column) }
        }
        // The column a key moved a card to folds back once no card in it has the keyboard's focus: at once where a card in
        // another column has it, a moment later where none has, as you click elsewhere, but not while the card's owed it to
        // be drawn anew there, nor while the details cover the board. Another card in that column that takes it keeps it open.
        .task(id: KeyMoment(focused: focused, isEnabled: isEnabled, owed: refocus.spot, opened: keyOpened)) {
            guard let opened = keyOpened, focused != opened.spot else { return }
            if let spot = focused, column(of: spot) == opened.column {
                keyOpened = KeyOpened(column: opened.column, spot: spot)
                return
            }
            if focused == nil {
                try? await Task.sleep(for: keyMomentWait)
                guard !Task.isCancelled, focused == nil, isEnabled, refocus.spot != opened.spot else { return }
            }
            if keyOpened == opened {
                withAnimation(.easeOut(duration: 0.15)) { keyOpened = nil }
            }
        }
    }

    /// How long a dragged card hovers a strip before it springs open.
    static let springDelay: Duration = .milliseconds(600)

    // MARK: Folding

    /// The columns open for the moment, whatever else says: those a drag sprang open, the one a card you moved with a key
    /// went to while a card there keeps the keyboard's focus, and those Up Next's "2 more ›" or My Work's Show Them opened.
    private var openForNow: Set<BoardColumn> {
        var open = sprung.union(revealedOpen)
        if let opened = keyOpened, column(of: opened.spot) == opened.column {
            open.insert(opened.column)
        }
        return open
    }

    /// The column a card is in on the board: a pull request's stage's, or a work item's.
    private func column(of spot: CardSpot) -> BoardColumn? {
        if let card = board.card(spot.ref, preferring: spot.lane) { return .stage(card.stage) }
        return board.lanes.lazy.flatMap(\.tasks).first { $0.ref == spot.ref }.map { BoardColumn($0.column) }
    }

    /// Which columns show folded, and how wide each is, as the board is now.
    private func currentMetrics() -> BoardMetrics {
        let widths = BoardWidths(scale: textScale, available: width)
        return BoardMetrics(widths: widths, columns: board.columns, folding: folding(widths, open: openForNow, choices: order.boardFolds))
    }

    private func folding(_ widths: BoardWidths, open: Set<BoardColumn>, choices: BoardFolds) -> BoardFolding {
        BoardFolding.make(
            columns: board.columns, count: board.count(of:), yourMove: board.hasYourMove(in:), choices: choices, open: open,
            widths: widths
        )
    }

    /// Whether BriefBar would fold a column by itself, without your choice for it or its own moment: the same as the board
    /// is now and once the other columns' moments end. Nil where those differ, as while one open for the moment takes the
    /// room this one would have: then a click on it is kept, rather than forgotten for a moment that ends.
    private func foldsByItself(_ column: BoardColumn, widths: BoardWidths) -> Bool? {
        var choices = order.boardFolds
        choices[column] = nil
        let now = folding(widths, open: openForNow.subtracting([column]), choices: choices).isFolded(column)
        let later = folding(widths, open: [], choices: choices).isFolded(column)
        return now == later ? now : nil
    }

    /// No longer open for the moment.
    private func endMoment(_ column: BoardColumn) {
        sprung.remove(column)
        revealedOpen.remove(column)
        if keyOpened?.column == column { keyOpened = nil }
    }

    /// Folds a column, as a click on its title does: one open for the moment folds back, where it was folded; else
    /// remembered, unless BriefBar would fold it by itself now, when it forgets that you opened it.
    private func fold(_ column: BoardColumn, metrics: BoardMetrics) {
        withAnimation(.easeOut(duration: 0.15)) {
            let wasOpenForNow = openForNow.contains(column)
            endMoment(column)
            if wasOpenForNow, currentMetrics().isFolded(column) { return }
            let byItself = foldsByItself(column, widths: metrics.widths) ?? false
            order.setBoardFolds(order.boardFolds.choosing(.folded, for: column, byItself: byItself))
        }
    }

    /// Opens a column, as a click on its strip does: remembered, unless BriefBar would open it by itself now, when it
    /// forgets that you folded it.
    private func open(_ column: BoardColumn, metrics: BoardMetrics) {
        withAnimation(.easeOut(duration: 0.15)) {
            let byItself = foldsByItself(column, widths: metrics.widths) ?? true
            order.setBoardFolds(order.boardFolds.choosing(.open, for: column, byItself: byItself))
        }
    }

    /// Let BriefBar Decide: forgets what you chose for a column.
    private func letBriefBarDecide(_ column: BoardColumn) {
        withAnimation(.easeOut(duration: 0.15)) {
            endMoment(column)
            var choices = order.boardFolds
            choices[column] = nil
            order.setBoardFolds(choices)
        }
    }

    /// Return or Space on a lane's strip: its column opens for the moment, as a key move into it opens it, while a card in
    /// it has the keyboard, which goes to the first one there, owed it until it's drawn.
    private func openForKeyboard(_ column: BoardColumn, at spot: CardSpot) {
        withAnimation(.easeOut(duration: 0.15)) { keyOpened = KeyOpened(column: column, spot: spot) }
        oweFocus(to: spot)
    }

    /// A lane's first card in a column, a pull request's, else a work item's: where the keyboard goes as its strip opens.
    private func firstSpot(in lane: BoardLane, column: BoardColumn) -> CardSpot? {
        let card = column.stage.flatMap { lane.cards(in: $0).first?.ref }
        let ref = card ?? lane.tasks.first { BoardColumn($0.column) == column }?.ref
        return ref.map { CardSpot(lane: lane.kind, ref: $0) }
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
        FollowsScroll(scroll: scroll, direction: -1, content: HStack(alignment: .bottom, spacing: 0) {
            ForEach(board.columns, id: \.self) { column in
                columnTitle(column, metrics: metrics)
                    .padding(.trailing, metrics.gap(after: column))
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

    /// A column's title, which folds it, or its strip's, which opens it; either's menu has both, and Let BriefBar Decide
    /// once you chose.
    @ViewBuilder
    private func columnTitle(_ column: BoardColumn, metrics: BoardMetrics) -> some View {
        let count = board.count(of: column)
        let isFlashing = flashing == column
        if let why = metrics.folding.folded[column] {
            let needing = board.needingYou(in: column)
            Button {
                open(column, metrics: metrics)
            } label: {
                VStack(spacing: 3 * textScale) {
                    ColumnMarker(column: column)
                    StripCount(count: count, column: column, needsYou: needing > 0)
                }
                .padding(.top, 4)
                .padding(.bottom, 7)
                .frame(width: metrics.width(column))
                .background(titleBackground(column, isFlashing: isFlashing))
                .overlay(alignment: .bottom) { titleRule(column) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.stripHelp(title: column.title, count: count, needing: needing, why: why) + "\nClick to open it")
            .contextMenu { columnMenu(column, isFolded: true, metrics: metrics) }
            .accessibilityLabel(Self.stripWords(title: column.stage?.title ?? column.title, count: count, needing: needing))
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Opens it")
            .accessibilityActions { columnActions(column) }
        } else {
            Button {
                fold(column, metrics: metrics)
            } label: {
                HStack(spacing: 6 * textScale) {
                    ColumnMarker(column: column)
                    Text(column.title)
                        .font(size: 13, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Text("\(count)")
                        .font(size: 12.5, weight: .medium)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 7)
                .frame(width: metrics.width(column), alignment: .leading)
                .background(titleBackground(column, isFlashing: isFlashing))
                .overlay(alignment: .bottom) { titleRule(column) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help(column) + (order.boardFolds[column] == .open ? "\nYou opened it. Click to fold it" : "\nClick to fold it"))
            .contextMenu { columnMenu(column, isFolded: false, metrics: metrics) }
            .accessibilityLabel("\(column.stage?.title ?? column.title), \(count)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Folds it")
            .accessibilityActions { columnActions(column) }
        }
    }

    /// Under a title, a flash in its color as Up Next's "2 more ›" shows it, or a card moves into it while it's folded.
    private func titleBackground(_ column: BoardColumn, isFlashing: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(column.color.opacity(isFlashing ? 0.22 : 0))
    }

    /// The rule in its color under a title.
    private func titleRule(_ column: BoardColumn) -> some View {
        Capsule()
            .fill(column.color)
            .frame(height: 3 * textScale)
    }

    /// A column's menu, on its title or strip: Fold or Open, then Let BriefBar Decide once you chose, with why it's folded
    /// or open first.
    @ViewBuilder
    private func columnMenu(_ column: BoardColumn, isFolded: Bool, metrics: BoardMetrics) -> some View {
        if let why = metrics.folding.folded[column] {
            Text(BoardText.folded(why))
        } else if order.boardFolds[column] == .open {
            Text(BoardText.openedByYou)
        }
        if isFolded {
            Button("Open") { open(column, metrics: metrics) }
        } else {
            Button("Fold") { fold(column, metrics: metrics) }
        }
        if order.boardFolds[column] != nil {
            Divider()
            Button("Let BriefBar Decide") { letBriefBarDecide(column) }
        }
    }

    /// VoiceOver's actions on a column's title or strip, besides opening or folding it.
    @ViewBuilder
    private func columnActions(_ column: BoardColumn) -> some View {
        if order.boardFolds[column] != nil {
            Button("Let BriefBar Decide") { letBriefBarDecide(column) }
        }
    }

    /// What a folded column's strip says to VoiceOver: "Teammate's review, folded, 3, 1 needs you".
    static func stripWords(title: String, count: Int, needing: Int, here: Bool = false) -> String {
        var parts = ["\(title), folded", here ? (count == 0 ? "none here" : "\(count) here") : "\(count)"]
        if needing > 0 { parts.append(needing == 1 ? "1 needs you" : "\(needing) need you") }
        return parts.joined(separator: ", ")
    }

    /// A folded column's tooltip: its title, its count, how many need you, and why it's folded.
    static func stripHelp(title: String, count: Int, needing: Int, why: BoardFolding.Why) -> String {
        let needs = needing == 0 ? "" : needing == 1 ? ", 1 needs you" : ", \(needing) need you"
        return "\(title): \(count)\(needs)\n\(BoardText.folded(why))"
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
        case .inProgress: "Its work isn't done: a draft, a session still writes it before anyone else reviews it, or it waits for the changes you asked for"
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
                    // Where Up Next's "2 more ›", or My Work's Show Them, scrolls to.
                    HStack(spacing: 0) {
                        ForEach(board.columns, id: \.self) { column in
                            Color.clear
                                .frame(width: metrics.width(column), height: 0)
                                .id(ColumnAnchor(column: column))
                                .padding(.trailing, metrics.gap(after: column))
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
                .frame(width: metrics.lanes, alignment: .leading)
                .coordinateSpace(.named(Self.lanesSpace))
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(metrics.content > metrics.visible + 1 ? .automatic : .hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scroll.x = x }
            .onChange(of: order.revealedColumn) { _, column in reveal(column, with: proxy) }
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
                HStack(alignment: .top, spacing: 0) {
                    ForEach(board.columns, id: \.self) { column in
                        cell(lane, column: column, metrics: metrics, moves: moves)
                            .padding(.trailing, metrics.gap(after: column))
                            // Why a strip doesn't take the card you drag shows over its neighbors.
                            .zIndex(hovered == BoardCell(lane: lane.kind, column: column) ? 1 : 0)
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

    /// A column of a lane: its cards, or its strip while it's folded. Either is the one place a card you drag drops there,
    /// which stays as a strip springs open under the card, rather than another taking its place in the middle of the drag.
    private func cell(_ lane: BoardLane, column: BoardColumn, metrics: BoardMetrics, moves: BoardMoves) -> some View {
        let target = BoardCell(lane: lane.kind, column: column)
        let isFolded = metrics.isFolded(column)
        let takes = dropping(on: column, in: lane, moves: moves)?.isTaken == true
        return ZStack(alignment: .topLeading) {
            if isFolded {
                stripCell(lane, column: column, metrics: metrics, moves: moves)
            } else {
                openCell(lane, column: column, width: metrics.width(column), moves: moves)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            drop(items, on: column, in: lane, moves: moves)
        } isTargeted: { isOver in
            if isOver {
                hovered = target
                // A strip that takes the card springs open once the card stays over it a moment.
                if isFolded, takes { springing = target }
            } else {
                if hovered == target { hovered = nil }
                if springing == target { springing = nil }
            }
        }
    }

    /// What dropping the card you drag on a column of a lane would do, to the card as it is now: nil while you drag none.
    private func dropping(on column: BoardColumn, in lane: BoardLane, moves: BoardMoves) -> BoardMove? {
        isDragging ? drag.flatMap { moving($0.ref, to: column, in: lane, moves: moves) } : nil
    }

    private func openCell(_ lane: BoardLane, column: BoardColumn, width: CGFloat, moves: BoardMoves) -> some View {
        let cards = column.stage.map(lane.cards(in:)) ?? []
        // Your sprint work's own cards, after the pull requests'.
        let tasks = lane.tasks.filter { BoardColumn($0.column) == column }
        let target = BoardCell(lane: lane.kind, column: column)
        let move = dropping(on: column, in: lane, moves: moves)
        let takes = move?.isTaken == true
        let isHovered = hovered == target
        let refusal: String? = if case .refused(let why)? = move { why } else { nil }
        return VStack(alignment: .leading, spacing: 8 * textScale) {
            ForEach(cards) { card in
                cardView(card, in: lane, moves: moves)
            }
            ForEach(tasks) { task in
                taskView(task, in: lane)
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
                refusalBubble(refusal)
                    .padding(6)
            }
        }
    }

    /// A folded column's strip in a lane: how many cards it has there, in a pill where one needs you, and its name, cut
    /// short where the lane is shorter. A click opens the column. A card you drag drops on it as on the open column, and
    /// springs it open once it stays a moment, where it would go there. One with cards takes the keyboard's focus as a card
    /// does, on a click or with Tab, whatever the Mac's keyboard navigation, and hands it to its first card in the lane as
    /// its column opens: Return or Space opens it for the moment, until the keyboard leaves it.
    private func stripCell(_ lane: BoardLane, column: BoardColumn, metrics: BoardMetrics, moves: BoardMoves) -> some View {
        let count = lane.count(of: column)
        let needing = lane.needingYou(in: column).count
        let target = BoardCell(lane: lane.kind, column: column)
        let first = firstSpot(in: lane, column: column)
        let move = dropping(on: column, in: lane, moves: moves)
        let takes = move?.isTaken == true
        let isHovered = hovered == target
        let refusal: String? = if case .refused(let why)? = move { why } else { nil }
        let index = board.columns.firstIndex(of: column) ?? 0
        // Why it can't go there opens toward the board's middle.
        let toTheRight = index < board.columns.count / 2
        return VStack(spacing: 6 * textScale) {
            if count > 0 {
                StripCount(count: count, column: column, needsYou: needing > 0)
            }
            Sideways(isWhole: metrics.isAllFolded) {
                Text(column.title)
                    .font(size: 11, weight: .medium)
                    .foregroundStyle(count > 0 ? .secondary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .rotationEffect(.degrees(90))
            }
        }
        .padding(.vertical, 8 * textScale)
        .opacity(isDragging && refusal != nil ? 0.4 : 1)
        .frame(width: metrics.width(column))
        .frame(minHeight: 70 * textScale, maxHeight: .infinity, alignment: .top)
        .background(cellBackground(column, takes: takes, isHovered: isHovered, cornerRadius: 7))
        .overlay(alignment: toTheRight ? .topLeading : .topTrailing) {
            if isHovered, let refusal {
                refusalBubble(refusal)
                    .frame(width: 200 * textScale, alignment: .leading)
                    .offset(y: 6)
            }
        }
        .contentShape(Rectangle())
        // Its ring inside the strip, where the lanes' scroll view would cut one drawn outside it, at the Board's leading
        // edge.
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 7, style: .continuous).inset(by: 3))
        .onTapGesture {
            open(column, metrics: metrics)
            // The click gave the strip the keyboard, as it gives a card: the card it opens on here has it.
            if let first { oweFocus(to: first) }
        }
        .contextMenu { columnMenu(column, isFolded: true, metrics: metrics) }
        // As a field takes the keyboard's focus, on a click and with Tab, whatever the Mac's keyboard navigation, as a card.
        .focusable(first != nil, interactions: .edit)
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            guard let first else { return .ignored }
            openForKeyboard(column, at: first)
            return .handled
        }
        .help(stripCellHelp(lane, column: column, count: count, needing: needing, why: metrics.folding.folded[column]))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.stripWords(title: column.stage?.title ?? column.title, count: count, needing: needing, here: true))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens it")
        .accessibilityAction {
            open(column, metrics: metrics)
            // VoiceOver follows the keyboard onto that card, rather than lose its place as the strip goes.
            if let first { oweFocus(to: first) }
        }
    }

    /// A lane's strip's tooltip: what's in it there, by number and title, and why it's folded.
    private func stripCellHelp(_ lane: BoardLane, column: BoardColumn, count: Int, needing: Int, why: BoardFolding.Why?) -> String {
        var lines = [Self.stripHelp(title: column.title, count: count, needing: needing, why: why ?? .yours)]
        if let stage = column.stage {
            lines += lane.cards(in: stage).map { [$0.ref.shortOrderLabel, order.name(of: $0.ref)].compactMap { $0 }.joined(separator: " ") }
        }
        lines += lane.tasks.filter { BoardColumn($0.column) == column }.compactMap { work?.card($0)?.label }
        return (lines + ["Click to open it"]).joined(separator: "\n")
    }

    /// Why a column can't take the card you drag, as you hover it.
    private func refusalBubble(_ refusal: String) -> some View {
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
    }

    private func cellBackground(_ column: BoardColumn, takes: Bool, isHovered: Bool, cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(column.color.opacity(takes ? (isHovered ? 0.24 : 0.14) : 0.06))
            .overlay(shape.strokeBorder(column.color.opacity(takes ? (isHovered ? 0.9 : 0.55) : 0), lineWidth: isHovered ? 2 : 1.5))
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
                takesFocus: refocus.spot == spot, tookFocus: { refocus.took(spot) }, mayTakeFocus: { !keys.isEditingText },
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
        return apply(move, to: card, in: lane.kind, keepsFocus: focused?.ref == card.ref, opensColumn: false)
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
        _ = apply(move, to: card, in: lane, keepsFocus: keepsFocus, opensColumn: true)
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

    /// Moves a card as a drop or a key asks.
    /// - Parameters:
    ///   - keepsFocus: it has the keyboard's focus, which it keeps, drawn anew where it goes.
    ///   - opensColumn: a key moved it, and the column it goes to opens, folded or not, while it keeps the keyboard's focus,
    ///     or has it back once the details that cover the board close, so that the next key moves it on from there. A drop
    ///     leaves each column as it folds once the drag's springs end.
    private func apply(_ move: BoardMove, to card: BoardCard, in lane: BoardLane.Kind, keepsFocus: Bool, opensColumn: Bool) -> Bool {
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
        let spot = CardSpot(lane: lane, ref: card.ref)
        if keepsFocus { keepFocus(on: spot, leaving: card.stage) }
        let reading = order.stage(of: card.ref)
        guard Self.owesFocus(after: reading, leaving: card.stage), let reading else { return true }
        let column = BoardColumn.stage(reading.stage)
        if opensColumn {
            withAnimation(.easeOut(duration: 0.15)) { keyOpened = KeyOpened(column: column, spot: spot) }
            return true
        }
        // A key opened the column it was in: that's over.
        if keyOpened?.spot.ref == card.ref { keyOpened = nil }
        // Into a column that stays folded once the drag's springs end: its title flashes, and its strip counts the card.
        let widths = BoardWidths(scale: textScale, available: width)
        if board.foldsOnceMoved(card, as: reading, choices: order.boardFolds, open: openForNow.subtracting(sprung), widths: widths) {
            flash(column)
        }
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
    /// seconds, as in a lane you fold, or a column folded as you dropped it there, it isn't owed it later.
    private func keepFocus(on spot: CardSpot, leaving column: PullRequestStage) {
        let reading = order.stage(of: spot.ref)
        guard Self.owesFocus(after: reading, leaving: column) else {
            refocus.took(spot)
            return
        }
        oweFocus(to: spot)
    }

    /// A card is owed the keyboard's focus, which it takes as it's drawn: until it does, or ten seconds on, the test's own
    /// wait where it has one.
    private func oweFocus(to spot: CardSpot) {
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

    /// Up Next's "2 more ›", or My Work's Show Them: the page scrolls the board to that column, opened for the moment where it
    /// would be folded but for its own moment, or where the board doesn't know its width yet to tell, and its title flashes.
    private func reveal(_ column: BoardColumn?, with proxy: ScrollViewProxy) {
        guard let column else { return }
        let widths = BoardWidths(scale: textScale, available: width)
        if width <= 0 || folding(widths, open: openForNow.subtracting([column]), choices: order.boardFolds).isFolded(column) {
            revealedOpen.insert(column)
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(ColumnAnchor(column: column), anchor: .leading) }
            order.revealedColumn = nil
            flash(column)
        }
    }

    /// A column's title flashes in its color, for a moment.
    private func flash(_ column: BoardColumn) {
        flashing = column
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if flashing == column { flashing = nil }
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

// MARK: - A column's marks

/// A column's mark, by its title and on its strip: To start's dashed ring, as the Sprint page's To Do has it, else a dot in
/// its stage's color; a shape as well as a color, for those who can't tell the colors apart.
private struct ColumnMarker: View {
    let column: BoardColumn
    @Environment(\.textScale) private var textScale

    var body: some View {
        Group {
            if column == .toStart {
                // Not started, as the Sprint page's To Do says it.
                Image(systemName: "circle.dashed")
                    .font(size: 9, weight: .heavy)
                    .foregroundStyle(column.color)
            } else if column == .stage(.approved) {
                // Its seal, not a dot: as some see colors, its mint reads as Waits' grey or Can merge's green.
                Image(systemName: PullRequestStage.approved.symbol)
                    .font(size: 10, weight: .bold)
                    .foregroundStyle(column.color)
            } else {
                Circle()
                    .fill(column.color)
            }
        }
        .frame(width: 8 * textScale, height: 8 * textScale)
        .accessibilityHidden(true)
    }
}

/// How many cards a folded column has, on its strip: in a pill in its color where one of them needs you, a shape as well
/// as a color.
private struct StripCount: View {
    let count: Int
    let column: BoardColumn
    let needsYou: Bool
    @Environment(\.textScale) private var textScale

    var body: some View {
        Text(String(count))
            .font(size: 10.5, weight: needsYou ? .bold : .medium)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(needsYou ? column.textColor : .secondary)
            .padding(.horizontal, needsYou ? 3 * textScale : 0)
            .padding(.vertical, needsYou ? 1 * textScale : 0)
            .background {
                if needsYou {
                    Capsule()
                        .fill(column.color.opacity(0.2))
                        .overlay(Capsule().strokeBorder(column.color.opacity(0.85), lineWidth: 1))
                }
            }
    }
}

/// What it holds, turned a quarter to the right to read from top to bottom, as a folded column's name on its strip: as long
/// as it is, but only as long as it's given room for, cut short there, so that it never makes a lane taller; whole where
/// it sets the lane's height, as no open column does when every column is folded.
private struct Sideways: Layout {
    var isWhole = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(.unspecified)
        return CGSize(width: size.height, height: isWhole ? size.width : min(size.width, proposal.height ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let thickness = content.sizeThatFits(.unspecified).height
        // Laid out across, as long as the room is tall, then turned about its middle.
        content.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
            proposal: ProposedViewSize(width: bounds.height, height: thickness)
        )
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
        withBadgeLine
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
                if nexts.count == 1, let slot = nexts.first {
                    badge(slot)
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

    /// Its content, under the line of its own that two badges take, Fix next and Next: in the corner, where one stays, they
    /// would cover its number.
    private var withBadgeLine: some View {
        VStack(alignment: .leading, spacing: 4 * textScale) {
            if nexts.count > 1 {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    ForEach(nexts) { slot in
                        badge(slot)
                    }
                }
                // As far in as one in the corner.
                .padding(.top, -2 * textScale)
                .padding(.trailing, -2 * textScale)
                .allowsHitTesting(false)
            }
            content.view
        }
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
    /// Owed the keyboard's focus as it's drawn, as when Return on its column's strip opened the column for it: it takes it
    /// as it appears.
    let takesFocus: Bool
    let tookFocus: () -> Void
    /// Whether it may take the focus now: not from a field you type in.
    let mayTakeFocus: () -> Bool
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
            .onAppear {
                guard takesFocus else { return }
                tookFocus()
                // Once this update is done: unless another card, or a field you type in, took the keyboard meanwhile.
                DispatchQueue.main.async {
                    guard focus.wrappedValue == nil || focus.wrappedValue == spot, mayTakeFocus() else { return }
                    focus.wrappedValue = spot
                }
            }
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
