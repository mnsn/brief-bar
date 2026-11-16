import Foundation

// My Work's search: the Board keeps only the cards that match what you type, by ID or by name, and the lanes that hold them
// (`PullRequestBoard.matching`), with the pull requests' cards related to those that match, faded. Only how it shows: no
// stage, Up Next slot, count elsewhere or agent's answer changes for it, and nothing is read for it. Up Next keeps every
// card.

/// What you search My Work's Board for: the words you type, each of which a card has to have in one of its names
/// (`Card.names`), in any case and with any accents; or a link to a pull request, a work item or a Copilot session, which
/// matches its card, or the card that names it, or that the session works on.
public struct BoardSearch: Equatable, Sendable {
    /// What a search knows of a card, as the page that shows it names it.
    public struct Card: Equatable, Sendable {
        /// Its pull request or work item, then those it names: a pull request's work items, a work item's pull requests; and
        /// the Copilot sessions that work on it; for a link you paste. A pull request's card is related to another's that
        /// names one of the same work items (`PullRequestBoard.related`).
        public var refs: [ItemRef]
        /// Its names: its number as it shows, with its kind, "PR !4102" or "Task 5112", its title, those of what it names,
        /// its repository, branch and sessions, and its mission's and its story's.
        public var names: [String]

        public init(refs: [ItemRef], names: [String]) {
            self.refs = refs
            self.names = names
        }
    }

    /// What you typed, without the spaces around it.
    public let text: String
    /// Its words, without the ! or # before a pull request's number, so that "#4102" finds !4102 too.
    let words: [String]
    /// The pull request, work item or session a link you pasted points to: a session's by its `ghapp://sessions/` link or
    /// its ID too.
    let link: ItemRef?

    /// Nil for nothing to look for, as only spaces.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = ItemRef.from(link: trimmed)
        let words = trimmed.split { $0.isWhitespace || $0 == "," }
            .map { String($0.drop(while: { $0 == "!" || $0 == "#" })) }
            .filter { !$0.isEmpty }
        guard link != nil || !words.isEmpty else { return nil }
        self.text = trimmed
        self.words = words
        self.link = link
    }

    /// Whether it matches a card: for a link, where the card is what it points to, names it, or a session it points to works
    /// on it; else where each word is in one of the card's names, wherever in it, as "410" is in "!4102".
    public func matches(_ card: Card) -> Bool {
        if let link { return card.refs.contains(link) }
        return words.allSatisfy { word in
            card.names.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

extension PullRequestBoard {
    /// The board as My Work's search shows it: in each lane only the cards it matches, pull requests' and work items', and
    /// the pull requests' cards related to those (`related`), and only the lanes that hold one; each column counting what it
    /// shows, Completed too. A pull request's card in two missions' lanes is named in each for that lane's mission, so it can
    /// match in one of them only. Up Next, Start next, which card wears Next and which pull requests are on the board stay as
    /// they are; so does each lane's order, which a move keeps for the cards the search hides (`BoardLane.wholeOrder`), and
    /// whether a lane has work of yours still to do, so that it reads finished only where it is (`BoardLane.hidesWorkToDo`).
    /// - Parameter card: what the search knows of a card, in the lane it's in.
    public func matching(_ search: BoardSearch, card: (BoardItem) -> BoardSearch.Card) -> PullRequestBoard {
        var board = self
        board.search = search
        // The pull requests' cards that match in each lane, and the work items each card names, in any lane.
        var matched: [[ItemRef]] = []
        var work: [ItemRef: Set<ItemRef>] = [:]
        for lane in lanes {
            var matching: [ItemRef] = []
            for found in lane.cards {
                let known = card(.pullRequest(found))
                work[found.ref, default: []].formUnion(known.refs.filter { $0.kind == .workItem })
                if search.matches(known) { matching.append(found.ref) }
            }
            matched.append(matching)
        }
        let matches = Set(matched.joined())
        let theirWork = Set(matches.flatMap { work[$0] ?? [] })
        let related = Set(work.filter { !matches.contains($0.key) && !$0.value.isDisjoint(with: theirWork) }.keys)
        board.related = related
        board.lanes = zip(lanes, matched).compactMap { lane, matching in
            let shows = related.union(matching)
            var kept = lane
            kept.columns = lane.columns.compactMapValues { cards in
                let shown = cards.filter { shows.contains($0.ref) }
                return shown.isEmpty ? nil : shown
            }
            kept.tasks = lane.tasks.filter { search.matches(card(.work($0))) }
            guard !kept.isEmpty else { return nil }
            kept.completed = lane.completed.intersection(kept.cards.map(\.ref))
            kept.hidesWorkToDo = lane.hasWorkToDo
            kept.wholeOrder = lane.items(in: .stage(.inProgress)).map(\.ref) + lane.items(in: .toStart).map(\.ref)
            return kept
        }
        var shown: Set<ItemRef> = []
        let cards = board.lanes.flatMap(\.cards).filter { shown.insert($0.ref).inserted }
        board.counts = Dictionary(grouping: cards, by: \.stage).mapValues(\.count)
        board.completed = completed.intersection(shown)
        var shownTasks: Set<ItemRef> = []
        let tasks = board.lanes.flatMap(\.tasks).filter { shownTasks.insert($0.ref).inserted }
        board.taskCounts = Dictionary(grouping: tasks, by: \.column).mapValues(\.count)
        return board
    }

    /// How many cards match My Work's search, each once, however many lanes show it: its pull requests' and its work items',
    /// but those it shows as related (`related`).
    public var cardCount: Int {
        Set(lanes.flatMap { $0.cards.map(\.ref) + $0.tasks.map(\.ref) }).subtracting(related).count
    }

    /// Its first card that matches My Work's search, lanes from the top, columns from the left, each in its order, past those
    /// related to one (`related`): where Return in the search takes the keyboard. Nil with none.
    public var firstCard: ItemRef? {
        for lane in lanes {
            for column in columns {
                if let first = lane.items(in: column).first(where: { !related.contains($0.ref) }) { return first.ref }
            }
        }
        return nil
    }
}

extension BoardText {
    /// What the Board says where nothing matches My Work's search: "No card matches “cart”."
    public static func noMatch(_ search: BoardSearch) -> String {
        "No card matches “\(search.text)”."
    }

    /// How many cards match My Work's search, in its field, and how many it shows as related to them: "No cards", "1 card",
    /// "3 cards", "1 card · 2 related".
    public static func matchCount(_ count: Int, related: Int = 0) -> String {
        let cards = switch count {
        case 0: "No cards"
        case 1: "1 card"
        default: "\(count) cards"
        }
        return related > 0 ? "\(cards) · \(related) related" : cards
    }

    /// What a pull request's card My Work's search shows as related says first to VoiceOver, and on its tooltip: it doesn't
    /// match, but it's for the same work item as a card that does.
    public static let related = "Related: for the same work item as a card that matches"
}
