import Foundation

// Fold, don't scroll: each of the Board's columns shows open, with its cards, or folded to a thin strip with its name, its
// count, and a mark where something in it needs you. A click on its title folds it, and on its strip opens it, which
// BriefBar remembers (`BoardFolds`); otherwise BriefBar decides (`BoardFolding`): a column with no cards folds, and opens
// by itself once a card arrives; and where the Board is too narrow for its open columns at their narrowest, the least
// needed fold first. Only how the Board shows: no stage, slot or count changes for it, and nothing is read for it.

// MARK: - Your choices

/// How you chose to show one of the Board's columns.
public enum ColumnChoice: String, Sendable {
    case open
    case folded
}

/// The Board's columns you opened or folded yourself, remembered (`order.boardColumns`): BriefBar decides the rest. A joined
/// column's is its own, kept while you keep it joined; each of its columns keeps yours for when you split it.
public struct BoardFolds: Equatable, Sendable {
    /// Where they're kept: each column's key (`ShownColumn.key`), with "open" or "folded".
    public static let defaultsKey = "order.boardColumns"

    private var choices: [ShownColumn: ColumnChoice]

    public init(_ choices: [BoardColumn: ColumnChoice] = [:]) {
        self.choices = Dictionary(uniqueKeysWithValues: choices.map { (ShownColumn($0.key), $0.value) })
    }

    public init(shown choices: [ShownColumn: ColumnChoice]) {
        self.choices = choices
    }

    public subscript(column: ShownColumn) -> ColumnChoice? {
        get { choices[column] }
        set { choices[column] = newValue }
    }

    public subscript(column: BoardColumn) -> ColumnChoice? {
        get { choices[ShownColumn(column)] }
        set { choices[ShownColumn(column)] = newValue }
    }

    public var isEmpty: Bool {
        choices.isEmpty
    }

    /// What you chose, as the preferences keep it; what they hold that this build doesn't know, it leaves out.
    public static func load(from defaults: some SettingsStorage) -> BoardFolds {
        guard let kept = defaults.object(forKey: defaultsKey) as? [String: String] else { return BoardFolds() }
        var choices: [ShownColumn: ColumnChoice] = [:]
        for (key, value) in kept {
            if let column = ShownColumn(key: key), let choice = ColumnChoice(rawValue: value) { choices[column] = choice }
        }
        return BoardFolds(shown: choices)
    }

    public func save(to defaults: some SettingsStorage) {
        if choices.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(Dictionary(uniqueKeysWithValues: choices.map { ($0.key.key, $0.value.rawValue) }), forKey: Self.defaultsKey)
        }
    }

    /// Your choices once you open or fold a column with a click: none for it where that's what BriefBar would do by itself
    /// then, so that a second click goes back to BriefBar's way, as Let BriefBar Decide does.
    /// - Parameter byItself: whether BriefBar would fold it by itself, as the Board is now.
    public func choosing(_ choice: ColumnChoice, for column: ShownColumn, byItself folds: Bool) -> BoardFolds {
        var chosen = self
        chosen[column] = (choice == .folded) == folds ? nil : choice
        return chosen
    }

    /// Your choices for the columns a layout can show: each column's own, and a joined column's only while it joins those
    /// columns, so that one you split, or joined to another, starts as BriefBar decides should you join it again.
    public func keeping(_ layout: BoardLayout) -> BoardFolds {
        let joined = Set(layout.joined)
        return BoardFolds(shown: choices.filter { !$0.key.isJoined || joined.contains($0.key) })
    }
}

extension BoardColumn {
    /// Its name in the preferences: "toStart", "completed", or its stage's, "teammateReview".
    public var key: String {
        switch self {
        case .toStart: "toStart"
        case .stage(let stage): stage.rawValue
        case .completed: "completed"
        }
    }

    public init?(key: String) {
        if key == "toStart" {
            self = .toStart
        } else if key == "completed" {
            self = .completed
        } else if let stage = PullRequestStage(rawValue: key) {
            self = .stage(stage)
        } else {
            return nil
        }
    }
}

// MARK: - What needs you

extension BoardCard {
    /// It's your move, which keeps its column open where the Board is narrow (`BoardFolding`): a review that waits on you;
    /// one you complete yourself, not one set to complete by itself; or one only you are working on, with no session at
    /// it: your draft, or one you set in progress yourself, while no session writes it or asks you about it. Those stay
    /// a draft, or as you set them, with the session in their flags.
    public var isYourMove: Bool {
        switch stage {
        case .yourReview: true
        case .canMerge: reading.why == .ready(autoComplete: false)
        case .inProgress:
            (reading.why == .draft || reading.why == .set && reading.isSetByYou) && !reading.flags.contains(where: \.isSession)
        default: false
        }
    }

    /// It needs you, as BriefBar counts it: a review that waits on you, one you can complete, or one Fix next offers, as a
    /// session asks you something, a build failed or someone wants changes; never one that merged. A folded column's strip
    /// marks it.
    public var needsYou: Bool {
        guard stage != .merged else { return false }
        return stage == .yourReview || stage == .canMerge && reading.why == .ready(autoComplete: false) || reading.fixRank != nil
    }
}

private extension StageFlag {
    /// Whether it's a session at work on the pull request: one that writes it, or waits for your answer.
    var isSession: Bool {
        switch self {
        case .asksYou, .working: true
        case .failing, .changesWanted: false
        }
    }
}

extension BoardTask {
    /// It's your move: work of yours that started, which only you are working on, with no pull request yet and no task you
    /// sent to Copilot on it.
    public var isYourMove: Bool {
        if case .started = why { true } else { false }
    }
}

extension BoardLane {
    /// How many cards it has in a column: its pull requests', and its work items' own.
    public func count(of column: BoardColumn) -> Int {
        cards(in: column).count + tasks.filter { BoardColumn($0.column) == column }.count
    }

    /// How many it has in a column as it shows, each of its columns'.
    public func count(of column: ShownColumn) -> Int {
        column.parts.reduce(0) { $0 + count(of: $1) }
    }

    /// Its cards in a column that need you.
    public func needingYou(in column: BoardColumn) -> [BoardCard] {
        column.stage.map { cards(in: $0).filter(\.needsYou) } ?? []
    }

    /// Its cards in a column as it shows that need you, column by column.
    public func needingYou(in column: ShownColumn) -> [BoardCard] {
        column.parts.flatMap(needingYou(in:))
    }
}

extension PullRequestBoard {
    /// How many cards in a column need you, each once, whatever lanes show it.
    public func needingYou(in column: BoardColumn) -> Int {
        Set(lanes.flatMap { $0.needingYou(in: column) }.map(\.ref)).count
    }

    /// How many in a column as it shows need you: in each of its columns.
    public func needingYou(in column: ShownColumn) -> Int {
        column.parts.reduce(0) { $0 + needingYou(in: $1) }
    }

    /// How many cards a column as it shows has: each of its columns'.
    public func count(of column: ShownColumn) -> Int {
        column.parts.reduce(0) { $0 + count(of: $1) }
    }

    /// Whether it's your move on a card in a column as it shows: in any of its columns, which keeps a joined column open.
    public func hasYourMove(in column: ShownColumn) -> Bool {
        column.parts.contains(where: hasYourMove(in:))
    }

    /// Whether it's your move on a card in a column, a pull request's or a work item's, in any lane.
    public func hasYourMove(in column: BoardColumn) -> Bool {
        lanes.contains { lane in
            switch column {
            case .toStart: lane.tasks(in: .toStart).contains(where: \.isYourMove)
            case .stage(let stage):
                lane.cards(in: stage).contains(where: \.isYourMove)
                    || stage == .inProgress && lane.tasks(in: .inProgress).contains(where: \.isYourMove)
            case .completed: false
            }
        }
    }

    /// Whether the column a card moved to shows folded once it moved, as BriefBar folds it (`BoardFolding`): this Board, from
    /// before the move, with each of its pull requests in the column its stage takes it to now, and none that left the
    /// board. So the column a card left counts it no more, and what a move did to the others counts too, as Set as Next to
    /// Merge has the rest of its mission wait for the one you set. Its work items' cards stay as they are.
    /// - Parameters:
    ///   - column: the column it moved to, which shows in the column of `shown` that holds it.
    ///   - stages: each pull request's stage once moved, with the sessions at work on it in its flags.
    ///   - shown: the columns the Board shows, as you laid them out.
    public func foldsOnceMoved(
        to column: BoardColumn, stages: [ItemRef: StageReading], shown: [ShownColumn], choices: BoardFolds,
        open: Set<ShownColumn>, widths: BoardWidths
    ) -> Bool {
        let cards = refs.compactMap { ref in stages[ref].flatMap { $0.isOnBoard ? BoardCard(ref: ref, reading: $0) : nil } }
        let byStage = Dictionary(grouping: cards, by: \.stage)
        var moved = self
        moved.lanes = [BoardLane(kind: .all, columns: byStage, tasks: lanes.flatMap(\.tasks))]
        moved.counts = byStage.mapValues(\.count)
        let target = shown.first { $0.contains(column) } ?? ShownColumn(column)
        return BoardFolding.make(
            columns: shown, count: moved.count(of:), yourMove: moved.hasYourMove(in:), choices: choices, open: open,
            widths: widths
        ).isFolded(target)
    }
}

// MARK: - Widths

/// How wide the Board's columns are, in points: an open one as wide as the page lets the open ones share, never narrower
/// than its cards need, and a folded one a thin strip, with less room beside it; all of it growing with the text. A joined
/// column is one column, open or folded.
public struct BoardWidths: Equatable, Sendable {
    /// The text's scale on windows' pages: 1 at 100%.
    public var scale: Double
    /// The page's width: 0 until it's known.
    public var available: Double
    /// The column titles end with the tab of the columns you hid, a strip's width beside the last column.
    public var endsWithHidden: Bool

    public init(scale: Double, available: Double, endsWithHidden: Bool = false) {
        self.scale = scale
        self.available = available
        self.endsWithHidden = endsWithHidden
    }

    /// An open column's narrowest.
    public var minimum: Double { 172 * scale }
    /// A folded column's: 18 points, a little more for bigger text, as only its count and its name across need it; thin
    /// enough, with the room beside it, for three open columns in the 664 points a 946-point window leaves the Board, with
    /// My Work's nine columns.
    public var strip: Double { 10 + 8 * scale }
    /// Between two open columns.
    public var gap: Double { 10 * scale }
    /// Beside a folded one.
    public var stripGap: Double { 3 * scale }
    /// The room the hidden columns' tab takes, with its gap: no more than the strip of one of them would.
    public var reserved: Double { endsWithHidden ? strip + stripGap : 0 }

    /// The room between a column and the next.
    public func gap<Column: Hashable>(after column: Column, in columns: [Column], folded: Set<Column>) -> Double {
        guard let index = columns.firstIndex(of: column), index + 1 < columns.count else { return 0 }
        return folded.contains(column) || folded.contains(columns[index + 1]) ? stripGap : gap
    }

    /// The room all the gaps take.
    public func gaps<Column: Hashable>(_ columns: [Column], folded: Set<Column>) -> Double {
        columns.dropLast().reduce(0) { $0 + gap(after: $1, in: columns, folded: folded) }
    }

    /// How wide the Board is with these of its columns folded, the open ones at their narrowest.
    public func narrowest<Column: Hashable>(_ columns: [Column], folded: Set<Column>) -> Double {
        let strips = columns.filter(folded.contains).count
        return Double(columns.count - strips) * minimum + Double(strips) * strip + gaps(columns, folded: folded) + reserved
    }

    /// Whether the page has room for them: always, until its width is known.
    public func fits<Column: Hashable>(_ columns: [Column], folded: Set<Column>) -> Bool {
        available <= 0 || narrowest(columns, folded: folded) <= available + 0.5
    }

    /// An open column's width: the room the strips, the gaps and the hidden columns' tab leave, shared, never under the
    /// minimum.
    public func open<Column: Hashable>(_ columns: [Column], folded: Set<Column>) -> Double {
        let strips = columns.filter(folded.contains).count
        let open = columns.count - strips
        guard available > 0, open > 0 else { return minimum }
        let room = available - Double(strips) * strip - gaps(columns, folded: folded) - reserved
        return max(minimum, room / Double(open))
    }
}

// MARK: - Which fold

/// Which of the Board's columns show folded, and why: worked out each time it's drawn, from your choices (`BoardFolds`),
/// what's in each column and the page's width. A column you chose shows as you chose it, one open for a moment open, and
/// BriefBar decides the rest: one with no cards folds; and where the Board is too narrow for its open columns at their
/// narrowest, the least needed of those it opened fold: first Completed, Merged, Waits and To start, whatever's in them;
/// then those where you wait, where it isn't your move (`BoardCard.isYourMove`), the one that needs least from you first,
/// as what needs you otherwise only marks a strip. Whatever's still too wide scrolls sideways. A joined column folds as one,
/// as late as the latest of its columns in that order, whatever's in it only where all its columns would, and never where
/// it's your move in any of them.
public struct BoardFolding: Equatable, Sendable {
    /// Why a column shows folded.
    public enum Why: Equatable, Sendable {
        /// You folded it.
        case yours
        /// It has no cards.
        case empty
        /// The Board is too narrow to show it open with the rest.
        case narrow
    }

    /// The columns that show folded, and why.
    public var folded: [ShownColumn: Why]

    public init(folded: [ShownColumn: Why] = [:]) {
        self.folded = folded
    }

    public func isFolded(_ column: ShownColumn) -> Bool {
        folded[column] != nil
    }

    /// - Parameters:
    ///   - columns: the columns the Board shows, from left to right.
    ///   - count: how many cards a column has.
    ///   - yourMove: whether it's your move on a card in a column (`BoardCard.isYourMove`), which keeps it open.
    ///   - choices: what you chose.
    ///   - open: the columns open for a moment, whatever else says: one a card you drag springs open, the one a card you
    ///     moved with a key is in while it has the keyboard's focus, one Up Next's "2 more ›" shows.
    ///   - widths: the page's room.
    public static func make(
        columns: [ShownColumn], count: (ShownColumn) -> Int, yourMove: (ShownColumn) -> Bool, choices: BoardFolds,
        open: Set<ShownColumn> = [], widths: BoardWidths
    ) -> BoardFolding {
        var folded: [ShownColumn: Why] = [:]
        for column in columns where !open.contains(column) {
            switch choices[column] {
            case .folded: folded[column] = .yours
            case .open: break
            case nil: if count(column) == 0 { folded[column] = .empty }
            }
        }
        for column in foldOrder(columns) where folded[column] == nil {
            if widths.fits(columns, folded: Set(folded.keys)) { break }
            guard !open.contains(column), choices[column] == nil, foldsFirst(column) || !yourMove(column) else { continue }
            folded[column] = .narrow
        }
        return BoardFolding(folded: folded)
    }

    /// Those BriefBar folds first where the Board is too narrow, whatever's in them: what you finished, what merged, what
    /// waits for another pull request, then the sprint work nobody started.
    static let foldsFirst: [BoardColumn] = [.completed, .stage(.merged), .stage(.waits), .toStart]

    /// Then, where it isn't your move, the columns where you wait, the one that needs least from you first: Can merge,
    /// where what's there completes by itself; In progress, where none of it is yours alone; Teammate's review; Approved,
    /// one step from done, last.
    static let thenWhereYouWait: [BoardColumn] = [
        .stage(.canMerge), .stage(.inProgress), .stage(.teammateReview), .stage(.approved),
    ]

    /// Whether a column folds first, whatever's in it: each of its columns does.
    static func foldsFirst(_ column: ShownColumn) -> Bool {
        column.parts.allSatisfy(foldsFirst.contains)
    }

    /// The order BriefBar folds columns in where the Board is too narrow: those it folds first, then those where you wait,
    /// then any other, from the left; a joined column where the latest of its columns comes. Your review, whose every card
    /// is your move, never folds for room.
    static func foldOrder(_ columns: [ShownColumn]) -> [ShownColumn] {
        let listed = foldsFirst + thenWhereYouWait
        let unlisted = BoardColumn.all.filter { !listed.contains($0) }
        let rank = { (column: BoardColumn) in listed.firstIndex(of: column) ?? listed.count + (unlisted.firstIndex(of: column) ?? 0) }
        return columns.enumerated().sorted { lhs, rhs in
            let left = lhs.element.parts.map(rank).max() ?? 0, right = rhs.element.parts.map(rank).max() ?? 0
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }
}

extension BoardText {
    /// Why a column shows folded, in its menu and its strip's tooltip.
    public static func folded(_ why: BoardFolding.Why) -> String {
        switch why {
        case .yours: "You folded it"
        case .empty: "Folded: no cards in it"
        case .narrow: "Folded to make room: the window is too narrow for every column"
        }
    }

    /// In an open column's menu, once you opened it.
    public static let openedByYou = "You opened it"
}
