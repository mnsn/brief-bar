import Foundation

// The Board's columns as you lay them out from their titles, on either page, without Settings: neighbors joined into one
// column, as Your review and Teammate's review into In review, and Merged and Completed hidden, as they hold only history.
// BriefBar remembers it (`BoardLayout`). It only maps the Board's columns (`BoardColumn`) to those it shows
// (`ShownColumn`), so it can't disagree with the stages: a joined column's cards keep their own stages and colors, a drop
// or a key still sets one stage, and Up Next, counts, notifications and what agents are told stay as they are. The flow's
// order is fixed: a column joins only its neighbors, and none moves.

// MARK: - The Board's columns

extension BoardColumn {
    /// Every column the Board can have, from left to right: To start and Completed only while it shows your sprint work.
    public static let all: [BoardColumn] = [.toStart] + PullRequestStage.columns.map(BoardColumn.stage) + [.completed]

    /// The one after it in the Board's order; nil for the last.
    public var next: BoardColumn? {
        guard let index = Self.all.firstIndex(of: self), index + 1 < Self.all.count else { return nil }
        return Self.all[index + 1]
    }

    /// Its title on the Board: "Waits", short for Waits for another PR.
    public var title: String {
        switch self {
        case .toStart: BoardText.toStart
        case .stage(let stage): stage.columnTitle
        case .completed: BoardText.completed
        }
    }

    /// As VoiceOver says it: "Waits for another PR".
    public var spokenTitle: String {
        stage?.title ?? title
    }

    /// As a menu names it: "Teammate's Review".
    public var menuTitle: String {
        switch self {
        case .toStart: "To Start"
        case .stage(let stage): stage == .waits ? "Waits" : stage.menuTitle
        case .completed: BoardText.completed
        }
    }
}

// MARK: - A column as it shows

/// A column as the Board shows it: one of its columns, or neighbors you joined into one (`BoardLayout`), whose cards keep
/// their own column's stage and color. One that's joined folds, opens, counts and is your move as one column.
public struct ShownColumn: Hashable, Sendable {
    /// Its columns, neighbors in the Board's order, from left to right: one, unless joined.
    public let parts: [BoardColumn]

    public init(_ column: BoardColumn) {
        parts = [column]
    }

    /// Neighbors in the Board's order, as `BoardLayout` makes them.
    init(run: [BoardColumn]) {
        parts = run
    }

    /// Columns that are neighbors in the Board's order, from left to right; nil for none, or for any that aren't.
    public init?(parts: [BoardColumn]) {
        guard !parts.isEmpty, zip(parts, parts.dropFirst()).allSatisfy({ $0.next == $1 }) else { return nil }
        self.parts = parts
    }

    public var isJoined: Bool { parts.count > 1 }
    public var first: BoardColumn { parts[0] }
    public var last: BoardColumn { parts[parts.count - 1] }

    public func contains(_ column: BoardColumn) -> Bool {
        parts.contains(column)
    }

    /// Its name in the preferences: its columns', "canMerge+waits".
    public var key: String {
        parts.map(\.key).joined(separator: "+")
    }

    public init?(key: String) {
        let parts = key.split(separator: "+", omittingEmptySubsequences: false).map { BoardColumn(key: String($0)) }
        guard !parts.contains(nil) else { return nil }
        self.init(parts: parts.compactMap { $0 })
    }

    /// Its title on the Board: its column's; for neighbors joined, what they hold together, as Simple Columns names them:
    /// In review for Your review and Teammate's review, with Approved or not; Ready for Can merge and Waits; Done for
    /// Merged and Completed; Teammate's review where Approved joins it, as before Approved was a column; else their
    /// titles, "Approved + Can merge".
    public var title: String {
        Self.names[parts]?.title ?? parts.map(\.title).joined(separator: " + ")
    }

    /// As a menu names it: "In Review", "Approved + Can Merge".
    public var menuTitle: String {
        Self.names[parts]?.menu ?? parts.map(\.menuTitle).joined(separator: " + ")
    }

    /// As VoiceOver says it: its title, and for one joined, what it joins, "In review: Your review and Teammate's review".
    public var spokenTitle: String {
        guard isJoined else { return first.spokenTitle }
        return title + ": " + OrderText.join(parts.map(\.spokenTitle))
    }

    /// Its columns' titles, as words: "Your review and Teammate's review".
    public var partTitles: String {
        OrderText.join(parts.map(\.title))
    }

    private static let names: [[BoardColumn]: (title: String, menu: String)] = [
        [.stage(.yourReview), .stage(.teammateReview)]: ("In review", "In Review"),
        [.stage(.yourReview), .stage(.teammateReview), .stage(.approved)]: ("In review", "In Review"),
        [.stage(.teammateReview), .stage(.approved)]: (PullRequestStage.teammateReview.title, PullRequestStage.teammateReview.menuTitle),
        [.stage(.canMerge), .stage(.waits)]: ("Ready", "Ready"),
        [.stage(.merged), .completed]: ("Done", "Done"),
    ]
}

// MARK: - How you laid them out

/// How you laid out the Board's columns from their titles, on either page, remembered: the neighbors you joined into one
/// column, and Merged and Completed, where you hid them. A column joins its neighbors only, and only those that hold
/// nothing that needs you hide, so nothing that needs you leaves the Board.
public struct BoardLayout: Equatable, Sendable {
    /// Where the joins are kept: each, "yourReview+teammateReview", a column and the next.
    public static let joinsKey = "order.boardJoins"
    /// Where the hidden columns are kept, by their keys: "merged", "completed".
    public static let hiddenKey = "order.boardHidden"

    /// Those that can hide: what merged and what you finished, history only.
    public static let hideable: Set<BoardColumn> = [.stage(.merged), .completed]

    /// Simple Columns: To start, In progress, In review (Your review, Teammate's review and Approved), Ready (Can merge and
    /// Waits) and Done (Merged and Completed); on Pull Requests, without To start and Completed, four.
    public static let simple = BoardLayout(joins: [.stage(.yourReview), .stage(.teammateReview), .stage(.canMerge), .stage(.merged)])

    /// The columns joined to the next one in the Board's order (`BoardColumn.next`).
    public private(set) var joins: Set<BoardColumn>
    /// The columns you hid: Merged, Completed.
    public private(set) var hidden: Set<BoardColumn>

    public init(joins: Set<BoardColumn> = [], hidden: Set<BoardColumn> = []) {
        self.joins = joins.filter { $0.next != nil }
        self.hidden = hidden.intersection(Self.hideable)
    }

    /// As the Board comes: no column joined, none hidden.
    public var isDefault: Bool {
        joins.isEmpty && hidden.isEmpty
    }

    /// The columns it shows of a Board's, from left to right: each that isn't hidden, neighbors joined into one; but each of
    /// those split for the moment a column of its own, as a card you drag springs a joined column open.
    public func shown(_ columns: [BoardColumn], splitting split: Set<ShownColumn> = []) -> [ShownColumn] {
        runs(columns.filter { !hidden.contains($0) }).flatMap { run in
            split.contains(run) ? run.parts.map(ShownColumn.init) : [run]
        }
    }

    /// The columns it hides of a Board's, as they'd show: Done, for Merged and Completed hidden while joined.
    public func hiddenColumns(_ columns: [BoardColumn]) -> [ShownColumn] {
        runs(columns.filter(hidden.contains))
    }

    /// The joined columns it makes of every column the Board can have, on either page: those your folds of joined columns
    /// still apply to.
    public var joined: [ShownColumn] {
        runs(BoardColumn.all).filter(\.isJoined)
    }

    /// Neighbors in a row, each joined to the one before it where you joined them.
    private func runs(_ columns: [BoardColumn]) -> [ShownColumn] {
        var runs: [[BoardColumn]] = []
        for column in columns {
            if let last = runs.last?.last, joins.contains(last), last.next == column {
                runs[runs.count - 1].append(column)
            } else {
                runs.append([column])
            }
        }
        return runs.map(ShownColumn.init(run:))
    }

    /// Whether two columns side by side can join: they're neighbors in the Board's order, not two a hidden one is between.
    public static func canJoin(_ left: ShownColumn, _ right: ShownColumn) -> Bool {
        left.last.next == right.first
    }

    /// Two columns side by side joined into one, where they can join.
    public func joining(_ left: ShownColumn, _ right: ShownColumn) -> BoardLayout {
        guard Self.canJoin(left, right) else { return self }
        var layout = self
        layout.joins.insert(left.last)
        return layout
    }

    /// A joined column split into all its columns again.
    public func splitting(_ column: ShownColumn) -> BoardLayout {
        var layout = self
        layout.joins.subtract(column.parts.dropLast())
        return layout
    }

    /// Whether a column can hide: one whose columns hold only history, Merged, Completed, or Done.
    public static func canHide(_ column: ShownColumn) -> Bool {
        column.parts.allSatisfy(hideable.contains)
    }

    /// A column hidden, with each of its columns, where it can hide.
    public func hiding(_ column: ShownColumn) -> BoardLayout {
        guard Self.canHide(column) else { return self }
        var layout = self
        layout.hidden.formUnion(column.parts)
        return layout
    }

    /// A hidden column shown again.
    public func showing(_ column: ShownColumn) -> BoardLayout {
        var layout = self
        layout.hidden.subtract(column.parts)
        return layout
    }

    /// As the preferences keep it; what they hold that this build doesn't know, or that can't be, it leaves out.
    public static func load(from defaults: some SettingsStorage) -> BoardLayout {
        let joins = (defaults.object(forKey: joinsKey) as? [String] ?? []).compactMap { key -> BoardColumn? in
            guard let joined = ShownColumn(key: key), joined.parts.count == 2 else { return nil }
            return joined.first
        }
        let hidden = (defaults.object(forKey: hiddenKey) as? [String] ?? []).compactMap(BoardColumn.init(key:))
        return BoardLayout(joins: Set(joins), hidden: Set(hidden))
    }

    public func save(to defaults: some SettingsStorage) {
        let joins = BoardColumn.all.compactMap { column in
            column.next.flatMap { self.joins.contains(column) ? ShownColumn(run: [column, $0]).key : nil }
        }
        let hidden = BoardColumn.all.filter(self.hidden.contains).map(\.key)
        for (key, value) in [(Self.joinsKey, joins), (Self.hiddenKey, hidden)] {
            if value.isEmpty {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
    }
}

extension BoardText {
    /// Why a joined column doesn't take the card you drag yet, where more than one of its columns would: until it springs
    /// open into them, as it does once the card stays over it a moment. "In review joins Your review and Teammate's review:
    /// hold the card over it until it opens into them, then drop it on one".
    public static func chooseOne(of column: ShownColumn) -> String {
        "\(column.title) joins \(column.partTitles): hold the card over it until it opens into them, then drop it on one"
    }

    /// The tooltip of the tab that holds the columns you hid: "Hidden: Merged (3) and Completed (12)".
    public static func hiddenHelp(_ columns: [ShownColumn], count: (ShownColumn) -> Int) -> String {
        "Hidden: " + OrderText.join(columns.map { "\($0.title) (\(count($0)))" }) + "\nClick to show them"
    }

    /// What that tab says to VoiceOver: "2 hidden columns: Merged and Completed".
    public static func hiddenWords(_ columns: [ShownColumn]) -> String {
        (columns.count == 1 ? "1 hidden column: " : "\(columns.count) hidden columns: ") + OrderText.join(columns.map(\.spokenTitle))
    }
}
