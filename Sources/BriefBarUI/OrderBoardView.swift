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
// titles and the lanes' headers. Hover the gap between two titles for →|←, which joins them into one column, its cards
// keeping their own stages and colors, and ←|→ on a joined title splits it; Merged and Completed hide from a title's menu
// into the tab at the titles' end, which brings them back; the menu has Simple Columns and Reset Columns too
// (`BoardLayout`). A joined column folds as one, and springs open into its columns as you drag a card over it, so that a
// drop sets one stage. On My Work, with + Sprint Tasks, your sprint work has cards of its own
// (`PullRequestBoard.withWork`): in To start, a column before In progress, until it's started, then in In progress, after
// the pull requests; in Merged once it's resolved, and in Completed, a column after Merged, once it's done, where a merged
// pull request's card goes too once it's out, with your work on it done. They don't move: their work does, in Azure DevOps.

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
    /// The header of a story's lane, for a story with no mission; for one whose work is all resolved or done, without
    /// saying it has no pull requests yet: the line under it says what it holds.
    package var story: (ItemRef, _ isFinished: Bool) -> AnyView
    /// Whether a work item's details show.
    package var isSelected: (ItemRef) -> Bool
    /// Shows a work item's details.
    package var select: (ItemRef) -> Void

    package init(
        card: @escaping (BoardTask) -> BoardCardContent?, story: @escaping (ItemRef, _ isFinished: Bool) -> AnyView,
        isSelected: @escaping (ItemRef) -> Bool, select: @escaping (ItemRef) -> Void
    ) {
        self.card = card
        self.story = story
        self.isSelected = isSelected
        self.select = select
    }
}

/// A column of a lane, as the Board shows it.
private struct BoardCell: Hashable {
    var lane: BoardLane.Kind
    var column: ShownColumn
}

extension BoardColumn {
    /// Its color: its stage's; for To start, the gray of the Sprint page's To Do, which is Waits' too: only To start's
    /// dashed ring, in place of a dot, tells them apart, and the two are never side by side. Completed is gray too, with the
    /// Sprint page's Done checkmark in place of a dot, Merged between it and Waits: what's done needs nothing from you.
    var color: Color {
        switch self {
        case .toStart, .completed: Color(nsColor: .systemGray)
        case .stage(let stage): stage.color
        }
    }

    /// Its color for words, as its stage's is (`PullRequestStage.textColor`); To start's and Completed's are Waits' gray.
    var textColor: Color {
        switch self {
        case .toStart, .completed: PullRequestStage.waits.textColor
        case .stage(let stage): stage.textColor
        }
    }
}

extension ShownColumn {
    /// Its color, for its lanes' tint, its strip's pill and its title's flash: its first column's. Its title's rule is in
    /// each of its columns' colors, and its cards in their own.
    var color: Color {
        first.color
    }

    var textColor: Color {
        first.textColor
    }
}

/// A card where it shows, for the keyboard's focus: a pull request in two missions' lanes has a card in each. It stays the
/// same as the card moves to another column.
private struct CardSpot: Hashable {
    var lane: BoardLane.Kind
    var ref: ItemRef
}

/// Where Up Next's "2 more ›" scrolls the Board to: the column as it shows, joined or not.
private struct ColumnAnchor: Hashable {
    var column: ShownColumn
}

/// Where a lane starts, for the page to scroll to: a mission's, as By Mission shows it, or that of the card My Work's Show
/// Them shows. An identity of its own for its spacer, so that only the anchor at the lane's top has its `LaneTop`.
private struct LaneAnchor: Hashable {
    var lane: BoardLane.Kind
}

/// The top of a lane, which the page scrolls to.
private struct LaneTop: Hashable {
    var lane: BoardLane.Kind
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

/// Where the pointer is over the column titles, for the control it shows there: the gap between two columns that can join,
/// where →|← joins them, or a joined column's open title, where ←|→ splits it.
private enum TitleHover: Equatable {
    case gap(ShownColumn, ShownColumn)
    case split(ShownColumn)
}

/// What dropping the card you drag on a lane's column would do: a move to one of its columns; or, on a joined column where
/// more than one of its columns would take it, nothing until it springs open into them, saying so.
private enum Dropping {
    case move(BoardMove, to: BoardColumn)
    case choose(String)

    /// The column lights up: one of its columns takes it.
    var takes: Bool {
        switch self {
        case .move(let move, _): move.isTaken
        case .choose: true
        }
    }

    /// Why it doesn't go there, or what to do first, as you hover it.
    var words: String? {
        switch self {
        case .move(.refused(let why), _): why
        case .move: nil
        case .choose(let words): words
        }
    }

    var isRefused: Bool {
        if case .move(.refused, _) = self { true } else { false }
    }
}

/// How wide the Board's columns are (`BoardWidths`): an open one as wide as the page allows, never narrower than its cards
/// need, and a folded one a strip; all of it from the columns it shows, joined as you joined them, those that show folded,
/// and the tab of those you hid at the titles' end.
private struct BoardMetrics {
    let widths: BoardWidths
    /// The columns it shows, from left to right.
    let columns: [BoardColumn]
    /// Those it shows, joined as you joined them, from left to right.
    let shown: [ShownColumn]
    /// Those you hid, as they'd show, in the tab at the titles' end.
    let hidden: [ShownColumn]
    let folding: BoardFolding
    private let folded: Set<ShownColumn>
    /// An open column's width.
    let open: CGFloat

    init(widths: BoardWidths, columns: [BoardColumn], shown: [ShownColumn], hidden: [ShownColumn], folding: BoardFolding) {
        self.widths = widths
        self.columns = columns
        self.shown = shown
        self.hidden = hidden
        self.folding = folding
        folded = Set(folding.folded.keys)
        open = widths.open(shown, folded: folded)
    }

    func isFolded(_ column: ShownColumn) -> Bool {
        folded.contains(column)
    }

    /// Every column shows folded: none is open to set a lane's height.
    var isAllFolded: Bool {
        shown.allSatisfy(folded.contains)
    }

    func width(_ column: ShownColumn) -> CGFloat {
        isFolded(column) ? widths.strip : open
    }

    /// The room after a column, before the next: less beside a strip.
    func gap(after column: ShownColumn) -> CGFloat {
        widths.gap(after: column, in: shown, folded: folded)
    }

    /// The column as it shows that holds one of the Board's columns: itself, or the one it's joined into.
    func shown(holding column: BoardColumn) -> ShownColumn? {
        shown.first { $0.contains(column) }
    }

    /// Where a column ends, from the titles' start.
    func end(of column: ShownColumn) -> CGFloat {
        guard let index = shown.firstIndex(of: column) else { return 0 }
        return shown[...index].reduce(0) { $0 + width($1) } + shown[..<index].reduce(0) { $0 + gap(after: $1) }
    }

    var content: CGFloat {
        shown.reduce(0) { $0 + width($1) + gap(after: $1) } + widths.reserved
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
    /// The strip a card you drag hovers, which springs open if it stays there, as Finder's folders do; or the joined column,
    /// which springs open into its columns.
    @LocalState private var springing: BoardCell?
    /// The folded columns a drag sprang open, until it ends.
    @LocalState private var sprung: Set<BoardColumn> = []
    /// The joined columns a drag sprang open into their columns, until it ends.
    @LocalState private var sprungJoins: Set<ShownColumn> = []
    /// Where the pointer is over the column titles: a gap where →|← joins two, or a joined title, where ←|→ splits it.
    @LocalState private var titleHover: TitleHover?
    /// The column a card you moved with a key went to, open while it keeps the keyboard's focus.
    @LocalState private var keyOpened: KeyOpened?
    /// The folded columns Up Next's "2 more ›", or My Work's Show Them, opened, for the moment: until you fold them, or the
    /// board goes.
    @LocalState private var revealedOpen: Set<BoardColumn> = []
    /// The hidden columns Show Them showed, for the card it shows in one, for the moment: until you hide one again, or the
    /// board goes.
    @LocalState private var unhiddenForNow: Set<BoardColumn> = []
    @LocalState private var notice: BoardNotice?
    @LocalState private var unfolded: Set<BoardLane.Kind> = []
    @LocalState private var width: CGFloat = 0
    @LocalState private var flashing: BoardColumn?
    @LocalState private var scroll = BoardScroll()
    /// The column titles stay at the page's top, over the cards that scroll under them.
    @LocalState private var pin = BoardPin()
    /// Where each lane starts, for the page to show it: a mission's, as a row's capsule asks, or the lane of the card My
    /// Work's Show Them shows.
    @LocalState private var laneTops: [BoardLane.Kind: CGFloat] = [:]
    /// The lane the page shows, for a moment, while the board settles.
    @LocalState private var revealing: BoardLane.Kind?
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
        // Once the drag ends, the columns it sprang open fold back, as they were, and those it sprang open into their columns
        // join again.
        .onChange(of: isDragging) { _, dragging in
            guard !dragging else { return }
            springing = nil
            if !sprung.isEmpty || !sprungJoins.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) {
                    sprung = []
                    sprungJoins = []
                }
            }
        }
        // A column Show Them showed for the moment is just shown once you show it.
        .onChange(of: order.boardLayout.hidden) { _, hidden in
            unhiddenForNow.formIntersection(hidden)
        }
        // A strip the dragged card hovers springs open once it has stayed there a moment, and a joined column into its
        // columns.
        .task(id: springing) {
            guard let cell = springing else { return }
            try? await Task.sleep(for: Self.springDelay)
            guard !Task.isCancelled, springing == cell, isDragging else { return }
            withAnimation(.easeOut(duration: 0.15)) { spring(cell, moves: moves) }
        }
        // The column a key moved a card to folds back once no card in it has the keyboard's focus: at once where a card in
        // another column has it, a moment later where none has, as you click elsewhere, but not while the card's owed it to
        // be drawn anew there, nor while the details cover the board. Another card in that column that takes it keeps it open.
        .task(id: KeyMoment(focused: focused, isEnabled: isEnabled, owed: refocus.spot, opened: keyOpened)) {
            guard let opened = keyOpened, focused != opened.spot else { return }
            // Another of a joined column's columns is that column too.
            if let spot = focused, let column = column(of: spot), shownColumn(holding: opened.column).contains(column) {
                keyOpened = KeyOpened(column: column, spot: spot)
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
        if let opened = keyOpened, let column = column(of: opened.spot), shownColumn(holding: opened.column).contains(column) {
            open.insert(column)
        }
        return open
    }

    /// How you laid out the columns, with those Show Them showed for the moment.
    private var shownLayout: BoardLayout {
        unhiddenForNow.reduce(order.boardLayout) { $0.showing(ShownColumn($1)) }
    }

    /// The column as the board shows it that holds one of its columns: a joined one, unless a drag sprang it open.
    private func shownColumn(holding column: BoardColumn) -> ShownColumn {
        shownLayout.shown(board.columns, splitting: sprungJoins).first { $0.contains(column) } ?? ShownColumn(column)
    }

    /// The column a card is in on the board: a pull request's stage's, or Completed for one in it, whose stage stays Merged;
    /// or a work item's.
    private func column(of spot: CardSpot) -> BoardColumn? {
        if let card = board.card(spot.ref, preferring: spot.lane) {
            return board.completed.contains(card.ref) ? .completed : .stage(card.stage)
        }
        return board.lanes.lazy.flatMap(\.tasks).first { $0.ref == spot.ref }.map { BoardColumn($0.column) }
    }

    /// Which columns show, joined as you joined them, and which folded, and how wide each is, as the board is now.
    private func currentMetrics() -> BoardMetrics {
        metrics(splitting: sprungJoins, open: openForNow)
    }

    /// The same, with these joined columns split into theirs for the moment, and these columns open for it.
    private func metrics(splitting split: Set<ShownColumn>, open: Set<BoardColumn>) -> BoardMetrics {
        let layout = shownLayout
        let shown = layout.shown(board.columns, splitting: split)
        let hidden = layout.hiddenColumns(board.columns)
        let widths = BoardWidths(scale: textScale, available: width, endsWithHidden: !hidden.isEmpty)
        return BoardMetrics(
            widths: widths, columns: board.columns, shown: shown, hidden: hidden,
            folding: folding(shown, widths: widths, open: open, choices: order.boardFolds)
        )
    }

    /// - Parameter open: the columns open for the moment: the columns as they show that hold them are.
    private func folding(_ shown: [ShownColumn], widths: BoardWidths, open: Set<BoardColumn>, choices: BoardFolds) -> BoardFolding {
        BoardFolding.make(
            columns: shown, count: board.count(of:), yourMove: board.hasYourMove(in:), choices: choices,
            open: Set(shown.filter { $0.parts.contains(where: open.contains) }), widths: widths
        )
    }

    /// Whether BriefBar would fold a column by itself, without your choice for it or its own moment: the same as the board
    /// is now and once the other columns' moments end. Nil where those differ, as while one open for the moment takes the
    /// room this one would have: then a click on it is kept, rather than forgotten for a moment that ends.
    private func foldsByItself(_ column: ShownColumn, metrics: BoardMetrics) -> Bool? {
        var choices = order.boardFolds
        choices[column] = nil
        let now = folding(metrics.shown, widths: metrics.widths, open: openForNow.subtracting(column.parts), choices: choices)
            .isFolded(column)
        let later = folding(metrics.shown, widths: metrics.widths, open: [], choices: choices).isFolded(column)
        return now == later ? now : nil
    }

    /// No longer open for the moment.
    private func endMoment(_ column: ShownColumn) {
        sprung.subtract(column.parts)
        revealedOpen.subtract(column.parts)
        if let opened = keyOpened, column.contains(opened.column) { keyOpened = nil }
    }

    /// Folds a column, as a click on its title does: one open for the moment folds back, where it was folded; else
    /// remembered, unless BriefBar would fold it by itself now, when it forgets that you opened it.
    private func fold(_ column: ShownColumn, metrics: BoardMetrics) {
        withAnimation(.easeOut(duration: 0.15)) {
            let wasOpenForNow = column.parts.contains(where: openForNow.contains)
            endMoment(column)
            if wasOpenForNow, currentMetrics().isFolded(column) { return }
            let byItself = foldsByItself(column, metrics: metrics) ?? false
            order.setBoardFolds(order.boardFolds.choosing(.folded, for: column, byItself: byItself))
        }
    }

    /// Opens a column, as a click on its strip does: remembered, unless BriefBar would open it by itself now, when it
    /// forgets that you folded it.
    private func open(_ column: ShownColumn, metrics: BoardMetrics) {
        withAnimation(.easeOut(duration: 0.15)) {
            let byItself = foldsByItself(column, metrics: metrics) ?? true
            order.setBoardFolds(order.boardFolds.choosing(.open, for: column, byItself: byItself))
        }
    }

    /// Let BriefBar Decide: forgets what you chose for a column.
    private func letBriefBarDecide(_ column: ShownColumn) {
        withAnimation(.easeOut(duration: 0.15)) {
            endMoment(column)
            var choices = order.boardFolds
            choices[column] = nil
            order.setBoardFolds(choices)
        }
    }

    /// Return or Space on a lane's strip: its column opens for the moment, as a key move into it opens it, while a card in
    /// it has the keyboard, which goes to the first one there, owed it until it's drawn.
    private func openForKeyboard(_ column: ShownColumn, at spot: CardSpot) {
        let part = self.column(of: spot).flatMap { column.contains($0) ? $0 : nil } ?? column.first
        withAnimation(.easeOut(duration: 0.15)) { keyOpened = KeyOpened(column: part, spot: spot) }
        oweFocus(to: spot)
    }

    /// A lane's first card in a column, column by column, a pull request's, else a work item's: where the keyboard goes as
    /// its strip opens.
    private func firstSpot(in lane: BoardLane, column: ShownColumn) -> CardSpot? {
        let ref = column.parts.lazy.compactMap { part in
            lane.cards(in: part).first?.ref ?? lane.tasks.first { BoardColumn($0.column) == part }?.ref
        }.first
        return ref.map { CardSpot(lane: lane.kind, ref: $0) }
    }

    // MARK: Laying out the columns

    /// Two columns side by side joined into one, as →|← in the gap between their titles, or Join in a title's menu, does.
    private func join(_ left: ShownColumn, _ right: ShownColumn) {
        withAnimation(.easeOut(duration: 0.15)) {
            titleHover = nil
            order.setBoardLayout(order.boardLayout.joining(left, right))
        }
    }

    /// A joined column split into its columns, as ←|→ on its title, or Split in its menu, does.
    private func splitColumn(_ column: ShownColumn) {
        withAnimation(.easeOut(duration: 0.15)) {
            titleHover = nil
            order.setBoardLayout(order.boardLayout.splitting(column))
        }
    }

    /// Merged or Completed, or Done, hidden, as Hide in its menu does: into the tab at the titles' end; one Show Them showed
    /// for the moment too.
    private func hide(_ column: ShownColumn) {
        withAnimation(.easeOut(duration: 0.15)) {
            endMoment(column)
            unhiddenForNow.subtract(column.parts)
            order.setBoardLayout(order.boardLayout.hiding(column))
        }
    }

    /// Hidden columns shown again, from the tab at the titles' end.
    private func show(_ columns: [ShownColumn]) {
        withAnimation(.easeOut(duration: 0.15)) {
            order.setBoardLayout(columns.reduce(order.boardLayout) { $0.showing($1) })
        }
    }

    /// The columns beside a column that it can join, as its menu offers them.
    private func joinable(beside column: ShownColumn, in metrics: BoardMetrics) -> (left: ShownColumn?, right: ShownColumn?) {
        guard let index = metrics.shown.firstIndex(of: column) else { return (nil, nil) }
        let left = index > 0 ? metrics.shown[index - 1] : nil
        let right = index + 1 < metrics.shown.count ? metrics.shown[index + 1] : nil
        return (
            left.flatMap { BoardLayout.canJoin($0, column) ? $0 : nil },
            right.flatMap { BoardLayout.canJoin(column, $0) ? $0 : nil }
        )
    }

    /// A card you drag stayed over a lane's column: a strip springs open, and a joined column into its columns, those that
    /// take the card open, with the one it's in, which stays under it, until the drag ends.
    private func spring(_ cell: BoardCell, moves: BoardMoves) {
        guard cell.column.isJoined else {
            sprung.insert(cell.column.first)
            return
        }
        sprungJoins.insert(cell.column)
        guard let ref = drag?.ref, let lane = board.lanes.first(where: { $0.kind == cell.lane }) else { return }
        for part in cell.column.parts {
            guard let move = moving(ref, to: part, in: lane, moves: moves), move.isTaken || move == .stays else { continue }
            sprung.insert(part)
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
            .overlay(alignment: .topLeading) { laneAnchors(lanes, proxy: proxy) }
            .onAppear {
                takeReveal(order.revealed, with: proxy)
                takeCardReveal(order.revealedCard, lanes: lanes, with: proxy)
            }
            .onChange(of: order.revealed) { _, key in takeReveal(key, with: proxy) }
            .onChange(of: order.revealedCard) { _, ref in takeCardReveal(ref, lanes: lanes, with: proxy) }
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

    /// The column titles, joined as you joined them, then the tab of the columns you hid. Over a gap between two that can
    /// join, →|← shows, which joins them, and over a joined column's open title, ←|→, which splits it.
    private func columnTitles(_ metrics: BoardMetrics) -> some View {
        FollowsScroll(scroll: scroll, direction: -1, content: HStack(alignment: .bottom, spacing: 0) {
            ForEach(metrics.shown, id: \.self) { column in
                columnTitle(column, metrics: metrics)
                    .padding(.trailing, metrics.gap(after: column))
            }
            if !metrics.hidden.isEmpty {
                hiddenTab(metrics)
                    .padding(.leading, metrics.shown.isEmpty ? 0 : metrics.widths.stripGap)
            }
        }
        .overlay(alignment: .leading) { titleControl(metrics) }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let hover = isDragging ? nil : Self.titleHover(at: point.x, metrics: metrics, scale: textScale, current: titleHover)
                if hover != titleHover { titleHover = hover }
            case .ended:
                titleHover = nil
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

    /// What the pointer is over among the titles: a gap between two columns that can join, with a few points of a title
    /// beside it, where it has room, not of a strip, or, once →|← shows there, the control, wider than the gap between two
    /// strips; else a joined column's open title.
    private static func titleHover(at x: CGFloat, metrics: BoardMetrics, scale: CGFloat, current: TitleHover?) -> TitleHover? {
        if case .gap(let left, let right)? = current, metrics.shown.contains(left), metrics.shown.contains(right),
           abs(x - (metrics.end(of: left) + metrics.gap(after: left) / 2)) <= 9 * scale {
            return current
        }
        for (left, right) in zip(metrics.shown, metrics.shown.dropFirst()) where BoardLayout.canJoin(left, right) {
            let end = metrics.end(of: left)
            let before = (metrics.isFolded(left) ? 1 : 7) * scale, after = (metrics.isFolded(right) ? 1 : 7) * scale
            if x >= end - before, x <= end + metrics.gap(after: left) + after { return .gap(left, right) }
        }
        let joined = metrics.shown.first { column in
            column.isJoined && !metrics.isFolded(column) && x >= metrics.end(of: column) - metrics.width(column)
                && x <= metrics.end(of: column)
        }
        return joined.map(TitleHover.split)
    }

    /// →|← in the gap the pointer is over, or ←|→ over the marks of the joined title it's over.
    @ViewBuilder
    private func titleControl(_ metrics: BoardMetrics) -> some View {
        let size = 18 * textScale
        switch titleHover {
        case .gap(let left, let right)? where metrics.shown.contains(left) && metrics.shown.contains(right):
            TitleControl(symbol: "arrow.right.and.line.vertical.and.arrow.left", size: size) { join(left, right) }
                .help("Join \(left.title) and \(right.title) into one column")
                .accessibilityLabel("Join \(left.title) and \(right.title)")
                .offset(x: metrics.end(of: left) + metrics.gap(after: left) / 2 - size / 2)
        case .split(let column)? where metrics.shown.contains(column):
            TitleControl(symbol: "arrow.left.and.line.vertical.and.arrow.right", size: size) { splitColumn(column) }
                .help("Split \(column.title) into \(column.partTitles)")
                .accessibilityLabel("Split \(column.title)")
                .offset(x: metrics.end(of: column) - metrics.width(column) + 4 * textScale)
        default:
            EmptyView()
        }
    }

    /// A column's title, which folds it, or its strip's, which opens it; either's menu has both, and Let BriefBar Decide
    /// once you chose, then how to lay the columns out. A joined column's shows each of its columns' marks.
    @ViewBuilder
    private func columnTitle(_ column: ShownColumn, metrics: BoardMetrics) -> some View {
        let count = board.count(of: column)
        // A joined column's in the color of the one of its columns it shows.
        let flash = flashing.flatMap { column.contains($0) ? $0.color : nil }
        if let why = metrics.folding.folded[column] {
            let needing = board.needingYou(in: column)
            Button {
                open(column, metrics: metrics)
            } label: {
                VStack(spacing: 3 * textScale) {
                    ColumnMarks(column: column, fitting: metrics.widths.strip)
                    StripCount(count: count, color: column.color, textColor: column.textColor, needsYou: needing > 0)
                }
                .padding(.top, 4)
                .padding(.bottom, 7)
                .frame(width: metrics.width(column))
                .background(titleBackground(flash))
                .overlay(alignment: .bottom) { titleRule(column) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.stripHelp(title: column.title, count: count, needing: needing, why: why) + "\nClick to open it")
            .contextMenu { columnMenu(column, isFolded: true, metrics: metrics) }
            .accessibilityLabel(Self.stripWords(title: column.spokenTitle, count: count, needing: needing))
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Opens it")
            .accessibilityActions { columnActions(column, metrics: metrics) }
        } else {
            Button {
                fold(column, metrics: metrics)
            } label: {
                Group {
                    if column.isJoined {
                        // Its marks side by side, else, where the title would be cut short, one over the other.
                        ViewThatFits(in: .horizontal) {
                            titleLabel(column, count: count, stacked: false)
                            titleLabel(column, count: count, stacked: true)
                        }
                    } else {
                        titleLabel(column, count: count, stacked: false)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 7)
                .frame(width: metrics.width(column), alignment: .leading)
                .background(titleBackground(flash))
                .overlay(alignment: .bottom) { titleRule(column) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help(column) + (order.boardFolds[column] == .open ? "\nYou opened it. Click to fold it" : "\nClick to fold it")
                + (column.isJoined ? ", or ←|→ over its marks to split it" : "") + "\n→|← between two titles joins them")
            .contextMenu { columnMenu(column, isFolded: false, metrics: metrics) }
            .accessibilityLabel("\(column.spokenTitle), \(count)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Folds it")
            .accessibilityActions { columnActions(column, metrics: metrics) }
        }
    }

    /// An open column's title: its marks, its name and its count.
    /// - Parameter stacked: a joined column's marks one over the other, rather than side by side.
    private func titleLabel(_ column: ShownColumn, count: Int, stacked: Bool) -> some View {
        // Its name on the titles' line, however tall its marks one over the other.
        HStack(alignment: stacked ? .bottom : .center, spacing: 6 * textScale) {
            ColumnMarks(column: column, stacked: stacked)
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
    }

    /// Under a title, a flash in its color as Up Next's "2 more ›" shows it, or a card moves into it while it's folded.
    private func titleBackground(_ flash: Color?) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill((flash ?? .clear).opacity(0.22))
    }

    /// The rule in its color under a title: a joined column's in each of its columns', one after the other.
    private func titleRule(_ column: ShownColumn) -> some View {
        HStack(spacing: 1.5 * textScale) {
            ForEach(column.parts, id: \.self) { part in
                Capsule()
                    .fill(part.color)
            }
        }
        .frame(height: 3 * textScale)
    }

    /// The tab at the titles' end that holds the columns you hid, a strip's width, as theirs were: how many cards they hold
    /// under an eye struck through, and a click lists them, each to show again.
    private func hiddenTab(_ metrics: BoardMetrics) -> some View {
        let hidden = metrics.hidden
        return Menu {
            ForEach(hidden, id: \.self) { column in
                Button("Show \(column.menuTitle) (\(board.count(of: column)))") { show([column]) }
            }
            if hidden.count > 1 {
                Divider()
                Button("Show All") { show(hidden) }
            }
        } label: {
            VStack(spacing: 3 * textScale) {
                Image(systemName: "eye.slash")
                    .font(size: 8.5, weight: .semibold)
                    .frame(height: 8 * textScale)
                // How many cards they hold, as every number in the titles' row counts cards.
                Text(String(hidden.reduce(0) { $0 + board.count(of: $1) }))
                    .font(size: 10.5, weight: .medium)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.bottom, 7)
            .frame(width: metrics.widths.strip)
            .contentShape(Rectangle())
        }
        .labelMenuStyle()
        .fixedSize()
        // Its ring inside it, where the titles' row would cut one drawn outside, as a strip's.
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 7, style: .continuous).inset(by: 3))
        // Tab reaches it as it does a strip, whatever the Mac's keyboard navigation, as it's the only way to the cards it
        // hides: Return or Space shows them all, as SwiftUI can't open its menu from a key.
        .focusable(interactions: .edit)
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            show(hidden)
            return .handled
        }
        .help(BoardText.hiddenHelp(hidden, count: board.count(of:)))
        .accessibilityLabel(BoardText.hiddenWords(hidden, count: board.count(of:)))
        .accessibilityHint("Shows them again")
    }

    /// A column's menu, on its title or strip: Fold or Open, then Let BriefBar Decide once you chose, with why it's folded
    /// or open first; then joining it to a neighbor, splitting it, hiding it, Simple Columns and Reset Columns.
    @ViewBuilder
    private func columnMenu(_ column: ShownColumn, isFolded: Bool, metrics: BoardMetrics) -> some View {
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
        Divider()
        layoutItems(column, metrics: metrics)
    }

    /// Joining a column to a neighbor, splitting it, hiding it, Simple Columns and Reset Columns: in its menu, and as
    /// VoiceOver's actions, as the keyboard has no pointer to hover a gap with.
    @ViewBuilder
    private func layoutItems(_ column: ShownColumn, metrics: BoardMetrics) -> some View {
        let beside = joinable(beside: column, in: metrics)
        if let left = beside.left {
            Button("Join with \(left.menuTitle)") { join(left, column) }
        }
        if let right = beside.right {
            Button("Join with \(right.menuTitle)") { join(column, right) }
        }
        if column.isJoined {
            Button("Split \(column.menuTitle)") { splitColumn(column) }
        }
        if BoardLayout.canHide(column) {
            Button("Hide \(column.menuTitle)") { hide(column) }
        }
        Divider()
        Button("Simple Columns") {
            withAnimation(.easeOut(duration: 0.15)) { order.simpleColumns() }
        }
        .disabled(order.hasSimpleColumns)
        Button("Reset Columns") {
            withAnimation(.easeOut(duration: 0.15)) { order.resetColumns() }
        }
        .disabled(order.hasDefaultColumns)
    }

    /// VoiceOver's actions on a column's title or strip, besides opening or folding it.
    @ViewBuilder
    private func columnActions(_ column: ShownColumn, metrics: BoardMetrics) -> some View {
        if order.boardFolds[column] != nil {
            Button("Let BriefBar Decide") { letBriefBarDecide(column) }
        }
        layoutItems(column, metrics: metrics)
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

    /// What a column holds, for its title's tooltip: a joined column's, what it joins, and what each of them holds.
    private func help(_ column: ShownColumn) -> String {
        guard column.isJoined else { return help(column.first) }
        return (["\(column.title) joins \(column.partTitles)"] + column.parts.map { "\($0.title): " + help($0) })
            .joined(separator: "\n")
    }
    /// What a column holds, for its title's tooltip: In progress also your sprint work that has started, and Merged what
    /// isn't out yet, while the board shows it.
    private func help(_ column: BoardColumn) -> String {
        switch column {
        case .toStart: BoardText.toStartHelp
        case .stage(.inProgress) where board.showsWork:
            Self.help(.inProgress) + "; then your sprint work that has started, with no pull request on your board"
        case .stage(.merged) where board.showsWork: BoardText.mergedWithWorkHelp
        case .stage(let stage): Self.help(stage)
        case .completed: BoardText.completedHelp
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
                    // Where Up Next's "2 more ›" scrolls to.
                    HStack(spacing: 0) {
                        ForEach(metrics.shown, id: \.self) { column in
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
                                    laneTops[lane.kind] = top
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
            .onChange(of: order.revealedColumn) { _, stage in reveal(stage, with: proxy) }
            .onAppear { reveal(order.revealedColumn, with: proxy) }
        }
    }

    /// Where each lane starts, as By Mission shows a mission a row's capsule asks for, or Show Them a card: from the board's
    /// top, where its column titles start, so that with the anchor at the page's top, as far above the lane as they're tall,
    /// the titles that stay there are just over the lane, its first too. Outside the board's sideways scroll, so that it
    /// scrolls the page. The page scrolls to the one it shows once that anchor is laid out where its lane starts, and again
    /// as it moves while the board settles.
    private func laneAnchors(_ lanes: [BoardLane], proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(lanes.map { LaneAnchor(lane: $0.kind) }, id: \.self) { anchor in
                VStack(spacing: 0) {
                    Color.clear.frame(width: 1, height: max(0, laneTops[anchor.lane] ?? 0))
                    Color.clear.frame(width: 1, height: 1).id(LaneTop(lane: anchor.lane))
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                    if revealing == anchor.lane { revealLane(with: proxy) }
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
        showLane(.mission(key), with: proxy)
        DispatchQueue.main.async {
            if order.revealed == key { order.revealed = nil }
        }
    }

    /// Takes the card My Work's Show Them asks for, the first of your work outside the sprint, its own or a pull request's
    /// that names it, and shows it: its column opens for the moment where it would be folded, and its title flashes; the
    /// page scrolls to its lane, as to a mission's, which doesn't fold while it holds that work, still to do
    /// (`BoardLane.hasWorkToDo`); and the keyboard's focus goes to it, owed until it's drawn, for VoiceOver to read it too.
    private func takeCardReveal(_ ref: ItemRef?, lanes: [BoardLane], with proxy: ScrollViewProxy) {
        guard let ref else { return }
        DispatchQueue.main.async {
            if order.revealedCard == ref { order.revealedCard = nil }
        }
        let isIn = { (lane: BoardLane) in lane.tasks.contains { $0.ref == ref } || lane.columns.values.contains { $0.contains { $0.ref == ref } } }
        guard let lane = lanes.first(where: isIn) else { return }
        let spot = CardSpot(lane: lane.kind, ref: ref)
        if let column = column(of: spot) {
            openForTheMoment(column)
            flash(column)
        }
        oweFocus(to: spot)
        // An owed card takes the focus as it appears: one drawn already takes it now.
        DispatchQueue.main.async {
            if isEnabled, !keys.isEditingText { focused = spot }
        }
        showLane(lane.kind, with: proxy)
    }

    /// Shows a lane: within a few seconds, for one that isn't laid out yet.
    private func showLane(_ lane: BoardLane.Kind, with proxy: ScrollViewProxy) {
        revealing = lane
        endReveal(of: lane, after: .seconds(5))
        revealLane(with: proxy)
    }

    /// The page scrolls to the lane it shows, once the lane is laid out, and again as the board settles, until it has kept
    /// still for a second. Without animation, as the page has just changed from By Status to By Mission under it, or to + All
    /// My Tasks.
    private func revealLane(with proxy: ScrollViewProxy) {
        guard let lane = revealing, laneTops[lane] != nil else { return }
        endReveal(of: lane, after: .seconds(1))
        DispatchQueue.main.async { proxy.scrollTo(LaneTop(lane: lane), anchor: .top) }
    }

    /// Stops showing that lane after a while, unless the page shows it again meanwhile.
    private func endReveal(of lane: BoardLane.Kind, after delay: Duration) {
        revealCount += 1
        let count = revealCount
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if revealCount == count, revealing == lane { revealing = nil }
        }
    }

    private func laneView(_ lane: BoardLane, metrics: BoardMetrics, moves: BoardMoves) -> some View {
        let mission = lane.mission.flatMap { key in missions.first { $0.key == key } }
        // A finished mission's lane folds, but not while it holds your work that's still to do, which it would hide; so does
        // a story's whose work is all resolved or done.
        let canFold = mission.map { $0.isFinished && !lane.hasWorkToDo } ?? lane.isFinishedStory
        let isFolded = canFold && !unfolded.contains(lane.kind)
        let undoRefs = board.undoRefs(of: lane, missions: missions, changed: order.lastStageChange?.ref)
        return VStack(alignment: .leading, spacing: 8) {
            // The lane's header stays in view as the board scrolls sideways. Every card in one lane has none, but for the
            // Undo line or why a card couldn't move.
            if lane.kind != .all || hasLines(lane, undoRefs: undoRefs) {
                FollowsScroll(
                    scroll: scroll, direction: 1,
                    content: laneHeader(lane, mission: mission, isFolded: isFolded, canFold: canFold, undoRefs: undoRefs)
                )
                .frame(width: metrics.visible, alignment: .leading)
            }
            // A lane kept only for the Undo line of a pull request that left the board has no columns to show.
            if !isFolded, !(lane.isEmpty && lane.mission == nil) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(metrics.shown, id: \.self) { column in
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
    private func laneHeader(
        _ lane: BoardLane, mission: OrderMission?, isFolded: Bool, canFold: Bool, undoRefs: Set<ItemRef>
    ) -> some View {
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
                        foldedLine(lane.kind, saying: OrderText.folded(mission.steps), isFolded: isFolded, canFold: canFold)
                    }
                    MissionNextStepsLine(lane: lane, order: order, select: select)
                        .padding(.leading, 4)
                }
            case .story(let story):
                work?.story(story, lane.isFinishedStory)
                if lane.isFinishedStory {
                    foldedLine(lane.kind, saying: lane.finishedWork, isFolded: isFolded, canFold: canFold)
                }
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

    /// A finished mission's lane folds to its header, as List's merged line does, and so does a story's whose work is all
    /// resolved or done: its line says what the lane holds, and a click on it, Return or Space folds the lane or shows it.
    /// - Parameter canFold: false for a finished mission's lane with cards of your work that's still to do, which doesn't
    ///   fold: the line only says it's finished.
    @ViewBuilder
    private func foldedLine(_ lane: BoardLane.Kind, saying words: String, isFolded: Bool, canFold: Bool) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(words)
            if canFold {
                Image(systemName: "chevron.right")
                    .font(size: 9, weight: .bold)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
            }
        }
        .font(size: 11.5, weight: .medium)
        .foregroundStyle(.secondary)
        if canFold {
            let toggle = {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isFolded { unfolded.insert(lane) } else { unfolded.remove(lane) }
                }
            }
            label
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                // Tab reaches it as it does a card, whatever the Mac's keyboard navigation, as it's the only way to the
                // cards it hides.
                .focusable(interactions: .edit)
                .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                    toggle()
                    return .handled
                }
                .padding(.leading, 4)
                .help(isFolded ? "Show its lane" : "Fold its lane")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isFolded ? "Show \(words)" : "Hide \(words)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, toggle)
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
    /// A joined column, folded or not, springs open into its columns as the card stays over it a moment, each of them a place
    /// of its own, so that a drop sets one stage.
    private func cell(_ lane: BoardLane, column: ShownColumn, metrics: BoardMetrics, moves: BoardMoves) -> some View {
        let target = BoardCell(lane: lane.kind, column: column)
        let isFolded = metrics.isFolded(column)
        let springs = springs(column, isFolded: isFolded, in: lane, moves: moves)
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
                if springs { springing = target }
            } else {
                if hovered == target { hovered = nil }
                if springing == target { springing = nil }
            }
        }
        // The column a drag starts over can be hovered before the board knows which card it drags: it springs once it does.
        .onChange(of: springs) { _, springs in
            if springs, hovered == target { springing = target }
        }
    }

    /// Whether a lane's column springs open as the card you drag stays over it a moment: a strip, where the card would go
    /// there; a joined column, folded or not, into its columns, where one of them would take the card, though it's in
    /// another of them, so that it goes from one of a joined column's columns to another as between any two.
    private func springs(_ column: ShownColumn, isFolded: Bool, in lane: BoardLane, moves: BoardMoves) -> Bool {
        guard isDragging, let ref = drag?.ref else { return false }
        guard column.isJoined else { return isFolded && moving(ref, to: column.first, in: lane, moves: moves)?.isTaken == true }
        return column.parts.contains { moving(ref, to: $0, in: lane, moves: moves)?.isTaken == true }
    }

    /// What dropping the card you drag on a column of a lane would do, to the card as it is now: nil while you drag none.
    private func dropping(on column: ShownColumn, in lane: BoardLane, moves: BoardMoves) -> Dropping? {
        isDragging ? drag.flatMap { outcome(of: $0.ref, on: column, in: lane, moves: moves) } : nil
    }

    /// What dropping a card on a column of a lane does: on a joined column, what dropping it on the one of its columns that
    /// takes it does, or nothing where it's in one of them already; where more than one would take it, nothing until it
    /// springs open into them; and where none does, why the first doesn't. Nil for a card that left the board.
    private func outcome(of ref: ItemRef, on column: ShownColumn, in lane: BoardLane, moves: BoardMoves) -> Dropping? {
        var outcomes: [(move: BoardMove, part: BoardColumn)] = []
        for part in column.parts {
            guard let move = moving(ref, to: part, in: lane, moves: moves) else { return nil }
            outcomes.append((move, part))
        }
        if let stays = outcomes.first(where: { $0.move == .stays }) { return .move(.stays, to: stays.part) }
        let taken = outcomes.filter(\.move.isTaken)
        if taken.count > 1 { return .choose(BoardText.chooseOne(of: column)) }
        return (taken.first ?? outcomes.first).map { .move($0.move, to: $0.part) }
    }

    private func openCell(_ lane: BoardLane, column: ShownColumn, width: CGFloat, moves: BoardMoves) -> some View {
        let target = BoardCell(lane: lane.kind, column: column)
        let dropping = dropping(on: column, in: lane, moves: moves)
        let takes = dropping?.takes == true
        let isHovered = hovered == target
        return VStack(alignment: .leading, spacing: 8 * textScale) {
            // Column by column: each one's pull requests, then your sprint work's own cards.
            ForEach(column.parts, id: \.self) { part in
                ForEach(lane.cards(in: part)) { card in
                    cardView(card, in: lane, column: part, isJoined: column.isJoined, moves: moves)
                }
                ForEach(lane.tasks.filter { BoardColumn($0.column) == part }) { task in
                    taskView(task, in: lane)
                }
            }
        }
        // Those that don't take the card dim while you drag it.
        .opacity(isDragging && dropping?.isRefused == true ? 0.4 : 1)
        .padding(6 * textScale)
        .frame(width: width, alignment: .topLeading)
        .frame(minHeight: 70 * textScale, maxHeight: .infinity, alignment: .top)
        .background(cellBackground(column, takes: takes, isHovered: isHovered))
        .overlay(alignment: .top) {
            // Why it can't go there, or what to do first, as you hover.
            if isHovered, let words = dropping?.words {
                refusalBubble(words)
                    .padding(6)
            }
        }
    }

    /// A folded column's strip in a lane: how many cards it has there, in a pill where one needs you, and its name, cut
    /// short where the lane is shorter. A click opens the column. A card you drag drops on it as on the open column, and
    /// springs it open once it stays a moment, where it would go there. One with cards takes the keyboard's focus as a card
    /// does, on a click or with Tab, whatever the Mac's keyboard navigation, and hands it to its first card in the lane as
    /// its column opens: Return or Space opens it for the moment, until the keyboard leaves it.
    private func stripCell(_ lane: BoardLane, column: ShownColumn, metrics: BoardMetrics, moves: BoardMoves) -> some View {
        let count = lane.count(of: column)
        let needing = lane.needingYou(in: column).count
        let target = BoardCell(lane: lane.kind, column: column)
        let first = firstSpot(in: lane, column: column)
        let dropping = dropping(on: column, in: lane, moves: moves)
        let takes = dropping?.takes == true
        let isHovered = hovered == target
        let index = metrics.shown.firstIndex(of: column) ?? 0
        // Why it can't go there opens toward the board's middle.
        let toTheRight = index < metrics.shown.count / 2
        return VStack(spacing: 6 * textScale) {
            if count > 0 {
                StripCount(count: count, color: column.color, textColor: column.textColor, needsYou: needing > 0)
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
        .opacity(isDragging && dropping?.isRefused == true ? 0.4 : 1)
        .frame(width: metrics.width(column))
        .frame(minHeight: 70 * textScale, maxHeight: .infinity, alignment: .top)
        .background(cellBackground(column, takes: takes, isHovered: isHovered, cornerRadius: 7))
        .overlay(alignment: toTheRight ? .topLeading : .topTrailing) {
            if isHovered, let words = dropping?.words {
                refusalBubble(words)
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
        .accessibilityLabel(Self.stripWords(title: column.spokenTitle, count: count, needing: needing, here: true))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens it")
        .accessibilityAction {
            open(column, metrics: metrics)
            // VoiceOver follows the keyboard onto that card, rather than lose its place as the strip goes.
            if let first { oweFocus(to: first) }
        }
    }

    /// A lane's strip's tooltip: what's in it there, by number and title, and why it's folded.
    private func stripCellHelp(_ lane: BoardLane, column: ShownColumn, count: Int, needing: Int, why: BoardFolding.Why?) -> String {
        var lines = [Self.stripHelp(title: column.title, count: count, needing: needing, why: why ?? .yours)]
        for part in column.parts {
            lines += lane.cards(in: part).map { [$0.ref.shortOrderLabel, order.name(of: $0.ref)].compactMap { $0 }.joined(separator: " ") }
            lines += lane.tasks.filter { BoardColumn($0.column) == part }.compactMap { work?.card($0)?.label }
        }
        return (lines + ["Click to open it"]).joined(separator: "\n")
    }

    /// Why a column can't take the card you drag, or what to do first, as you hover it.
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

    private func cellBackground(_ column: ShownColumn, takes: Bool, isHovered: Bool, cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(column.color.opacity(takes ? (isHovered ? 0.24 : 0.14) : 0.06))
            .overlay(shape.strokeBorder(column.color.opacity(takes ? (isHovered ? 0.9 : 0.55) : 0), lineWidth: isHovered ? 2 : 1.5))
    }

    /// A pull request's card in its column, which is joined to others where `isJoined`: there Approved's cards wear its seal.
    @ViewBuilder
    private func cardView(_ card: BoardCard, in lane: BoardLane, column: BoardColumn, isJoined: Bool, moves: BoardMoves) -> some View {
        if let content = self.card(card) {
            let spot = CardSpot(lane: lane.kind, ref: card.ref)
            BoardCardView(
                card: card, content: content, column: column, marksApproved: isJoined && column == .stage(.approved),
                nexts: UpNextSlot.allCases.filter { board.next[$0] == card.ref },
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

    private func drop(_ items: [String], on column: ShownColumn, in lane: BoardLane, moves: BoardMoves) -> Bool {
        let started = drag
        isDragging = false
        hovered = nil
        // Only a card dragged from this board, as it is now: never text dragged in from another app.
        guard let payload = items.first, let ref = started?.ref(dropped: payload),
              let outcome = outcome(of: ref, on: column, in: lane, moves: moves) else {
            return false
        }
        drag = nil
        switch outcome {
        // A joined column more than one of whose columns would take it, before it sprang open into them.
        case .choose(let words):
            refuse(words, about: ref, in: lane.kind)
            return false
        // A work item's card, a pull request's on To start or Completed, or one in Completed, stays where it is.
        case .move(.refused(let why), _):
            refuse(why, about: ref, in: lane.kind)
            return false
        case .move(_, let part):
            guard let stage = part.stage, let (card, move) = moves.drop(payload, of: started, on: stage, in: lane.kind) else {
                return false
            }
            return apply(move, to: card, in: lane.kind, keepsFocus: focused?.ref == card.ref, opensColumn: false)
        }
    }

    /// What dropping a card on a column of a lane does, to the card as it is now: a work item's stays where its work puts it,
    /// To start and Completed take no pull request, and one in Completed goes nowhere. Nil for a card that left the board.
    private func moving(_ ref: ItemRef, to column: BoardColumn, in lane: BoardLane, moves: BoardMoves) -> BoardMove? {
        if let task = board.lanes.lazy.flatMap(\.tasks).first(where: { $0.ref == ref }) {
            let stays = BoardColumn(task.column) == column && lane.tasks.contains { $0.ref == ref }
            return stays ? .stays : .refused(BoardText.workStays)
        }
        guard let card = moves.card(ref, in: lane.kind) else { return nil }
        let isCompleted = board.completed.contains(ref)
        switch column {
        case .toStart: return .refused(BoardText.toStartTakesNoPullRequest)
        case .completed:
            if lane.completed.contains(ref) { return .stays }
            return .refused(isCompleted ? BoardText.hasMerged : BoardText.completedTakesNoPullRequest)
        case .stage(let stage):
            return isCompleted ? .refused(BoardText.hasMerged) : moves.move(card, to: stage, in: lane.kind)
        }
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
        // Into a column that stays folded once the drag's springs end, joined columns joined again: its title flashes, and
        // its strip counts the card.
        let after = metrics(splitting: [], open: openForNow.subtracting(sprung))
        let open = Set(after.shown.filter { $0.parts.contains(where: openForNow.subtracting(sprung).contains) })
        if board.foldsOnceMoved(
            to: column, stages: order.stages, shown: after.shown, choices: order.boardFolds, open: open, widths: after.widths
        ) {
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

    /// Up Next's "2 more ›": the page scrolls the board to that column, or the joined column that holds it, opened for the
    /// moment where it would be folded but for its own moment, or where the board doesn't know its width yet to tell, and its
    /// title flashes.
    private func reveal(_ stage: PullRequestStage?, with proxy: ScrollViewProxy) {
        guard let stage else { return }
        let column = BoardColumn.stage(stage)
        let shown = openForTheMoment(column)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(ColumnAnchor(column: shown), anchor: .leading) }
            order.revealedColumn = nil
            flash(column)
        }
    }

    /// A column opens for the moment where it would be folded but for its own moment, or where the board doesn't know its
    /// width yet to tell: the joined column that holds it, which it returns, as one; and where you hid it, it shows for the
    /// moment, as Done where you hid that.
    @discardableResult
    private func openForTheMoment(_ column: BoardColumn) -> ShownColumn {
        if let hidden = currentMetrics().hidden.first(where: { $0.contains(column) }) {
            unhiddenForNow.formUnion(hidden.parts)
        }
        let metrics = currentMetrics()
        let shown = metrics.shown(holding: column) ?? ShownColumn(column)
        let others = openForNow.subtracting(shown.parts)
        if width <= 0 || folding(metrics.shown, widths: metrics.widths, open: others, choices: order.boardFolds).isFolded(shown) {
            revealedOpen.insert(column)
        }
        return shown
    }

    /// A column's title flashes in its color, for a moment: the joined column's that holds it.
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

/// A column's mark, by its title and on its strip: To start's dashed ring, as the Sprint page's To Do has it, Approved's
/// seal, Completed's checkmark, as the Sprint page's Done has it, else a dot in its stage's color; a shape as well as a
/// color, for those who can't tell the colors apart.
private struct ColumnMarker: View {
    let column: BoardColumn
    /// How big it is: 8 points, grown with the text, unless it's to fit less room, as on a joined column's strip.
    var size: CGFloat? = nil
    @Environment(\.textScale) private var textScale

    var body: some View {
        let side = size ?? 8 * textScale
        // Its symbol as much smaller as it is.
        let ratio = side / (8 * textScale)
        Group {
            if column == .toStart {
                // Not started, as the Sprint page's To Do says it.
                Image(systemName: "circle.dashed")
                    .font(size: 9 * ratio, weight: .heavy)
                    .foregroundStyle(column.color)
            } else if column == .stage(.approved) {
                // Its seal, not a dot: as some see colors, its mint reads as Waits' grey or Can merge's green.
                Image(systemName: PullRequestStage.approved.symbol)
                    .font(size: 10 * ratio, weight: .bold)
                    .foregroundStyle(column.color)
            } else if column == .completed {
                // Done, as the Sprint page's Done says it: not Waits' grey dot.
                Image(systemName: BoardText.completedSymbol)
                    .font(size: 9.5 * ratio, weight: .bold)
                    .foregroundStyle(column.color)
            } else {
                Circle()
                    .fill(column.color)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// A column's marks as it shows: its own; a joined column's, each of its columns', side by side, smaller on its strip, so
/// that they fit it, or one over the other by a title that has no room for them side by side.
private struct ColumnMarks: View {
    let column: ShownColumn
    /// The room across them, on a strip; nil by a title.
    var fitting: CGFloat? = nil
    /// One over the other.
    var stacked = false
    @Environment(\.textScale) private var textScale

    var body: some View {
        let count = CGFloat(column.parts.count)
        let spacing = (fitting == nil ? 2 : 1) * textScale
        if stacked {
            // No taller than a strip's mark and count, over which the titles line up: smaller past three.
            VStack(spacing: 1 * textScale) {
                ForEach(column.parts, id: \.self) { part in
                    ColumnMarker(column: part, size: min(count > 2 ? 7 : 8, (24 - (count - 1)) / count) * textScale)
                }
            }
        } else {
            let size = fitting.map { min(8 * textScale, ($0 - 2 * textScale - (count - 1) * spacing) / count) }
            HStack(spacing: spacing) {
                ForEach(column.parts, id: \.self) { part in
                    ColumnMarker(column: part, size: size)
                }
            }
        }
    }
}

/// How many cards a folded column has, on its strip: in a pill in its color where one of them needs you, a shape as well
/// as a color.
private struct StripCount: View {
    let count: Int
    let color: Color
    let textColor: Color
    let needsYou: Bool
    @Environment(\.textScale) private var textScale

    var body: some View {
        Text(String(count))
            .font(size: 10.5, weight: needsYou ? .bold : .medium)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(needsYou ? textColor : .secondary)
            // Less room beside two digits, so that they fit a strip whole at 150% too.
            .padding(.horizontal, needsYou ? (count < 10 ? 3 : 1.5) * textScale : 0)
            .padding(.vertical, needsYou ? 1 * textScale : 0)
            .background {
                if needsYou {
                    Capsule()
                        .fill(color.opacity(0.2))
                        .overlay(Capsule().strokeBorder(color.opacity(0.85), lineWidth: 1))
                }
            }
    }
}

/// The ←|→ and →|← over the column titles, which split a joined column and join two: a small round button over the gap
/// or the marks the pointer is over.
private struct TitleControl: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(size: 8.5, weight: .bold)
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                )
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
    /// The column it's in: its stage's, or Completed, whose color is on its edge and which VoiceOver says before its stage.
    let column: BoardColumn
    /// It's in Approved, joined to another column, as Teammate's review: it wears Approved's seal in its corner, which tells
    /// it from the rest at a glance.
    let marksApproved: Bool
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

    private var color: Color {
        column.color
    }

    var body: some View {
        withBadgeLine
            .padding(.leading, 13 * textScale)
            .padding(.trailing, 9 * textScale)
            .padding(.vertical, 9 * textScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassCard(cornerRadius: 10, isHovered: isHovered, raised: true))
            .overlay {
                // Its column's color on its edge.
                shape
                    .fill(color)
                    .mask(alignment: .leading) { Rectangle().frame(width: 4 * textScale) }
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if nexts.count <= 1, marksApproved || !nexts.isEmpty {
                    HStack(spacing: 4) {
                        if marksApproved { approvedSeal }
                        if let slot = nexts.first { badge(slot) }
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

    /// Its content, under the line of its own that two badges take, Fix next and Next, with Approved's seal where it wears
    /// it: in the corner, where one stays, they would cover its number.
    private var withBadgeLine: some View {
        VStack(alignment: .leading, spacing: 4 * textScale) {
            if nexts.count > 1 {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if marksApproved { approvedSeal }
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

    /// Approved's seal, the ✓ that marks an approved card in a joined column, in its color. VoiceOver says its stage already.
    private var approvedSeal: some View {
        Image(systemName: PullRequestStage.approved.symbol)
            .font(size: 11, weight: .bold)
            .foregroundStyle(PullRequestStage.approved.color)
            .accessibilityHidden(true)
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
        // Its stage stays Merged there: the column says where it is.
        var parts = column == .completed ? [column.title] : []
        parts.append(StageWords.spoken(card.reading, order: order, now: now))
        parts += content.details
        for slot in nexts {
            let name = slot == .fix ? "Fix next" : "Up Next"
            parts.append(picked.contains(slot) ? "\(name), you chose it" : name)
        }
        return parts.joined(separator: ", ")
    }

    /// What follows the pointer as it's dragged: its number and title, in its column's color.
    private var preview: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
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
                        .strokeBorder(color, lineWidth: 1.5)
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
