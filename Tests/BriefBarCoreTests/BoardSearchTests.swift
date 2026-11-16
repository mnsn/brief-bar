import Foundation
import Testing
@testable import BriefBarCore

/// My Work's search: which cards a search matches, and the Board it leaves, with your order and what folds as they'd be for
/// the cards it shows.
@Suite struct BoardSearchTests {
    private typealias Steps = NextStepsTests

    private static func card(_ names: String..., refs: [ItemRef] = []) -> BoardSearch.Card {
        BoardSearch.Card(refs: refs, names: names)
    }

    /// Every word has to be in one of a card's names, wherever in it, in any order, in any case and with any accents; the !
    /// or # before a pull request's number doesn't count. Nothing but spaces is no search.
    @Test func eachWordIsInOneOfItsNamesInAnyCaseOrAccent() throws {
        let card = Self.card("PR !4102", "Retry backoff at the Café", "Task 5112")
        for text in ["4102", "!4102", "#4102", "410", "retry", "RETRY Backoff", "backoff retry", "cafe", "retry 4102", "task 5112"] {
            #expect(try #require(BoardSearch(text)).matches(card), "\(text)")
        }
        for text in ["retry 5113", "bug", "!5112 4103"] {
            #expect(try #require(BoardSearch(text)).matches(card) == false, "\(text)")
        }
        #expect(BoardSearch("   ") == nil)
        #expect(BoardSearch("! #") == nil)
        #expect(BoardSearch("  cart ")?.text == "cart")
    }

    /// A link to a pull request or a work item matches only the card that is, or names, what it points to: not one whose
    /// names have its number.
    @Test func aLinkMatchesOnlyWhatItPointsTo() throws {
        let pullRequest = try #require(BoardSearch("https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4102"))
        #expect(pullRequest.matches(Self.card("PR !4102", refs: [Steps.pr(4102)])))
        #expect(!pullRequest.matches(Self.card("PR !14102", "Follow-up to !4102", refs: [Steps.pr(14102)])))
        let workItem = try #require(BoardSearch(" https://dev.azure.com/contoso/Storefront/_workitems/edit/5112 "))
        #expect(workItem.matches(Self.card("PR !4102", refs: [Steps.pr(4102), Steps.task(5112)])))
        #expect(!workItem.matches(Self.card("Task 5112", refs: [Steps.task(5113)])))
    }

    /// The board keeps only the cards that match, in the lanes that hold them, each column counting them, Completed too,
    /// whatever lanes show one; a pull request in two missions matches by each one's name in its lane only. What's on the
    /// board, Up Next and Start next stay as they were.
    @Test func theBoardKeepsOnlyWhatMatchesInTheLanesThatHoldIt() throws {
        var checkout = Steps.mission([Steps.step(4101, .next), Steps.step(4102, .waiting(open: [Steps.pr(4101)], unknown: []))])
        checkout.story = MissionStory(ref: Steps.task(5001))
        let cart = Steps.mission([Steps.step(4103, .merged, status: .merged), Steps.step(4102)])
        let stages: [Int: StageReading] = [
            4101: Steps.reading(.inProgress, .draft, at: 1), 4102: Steps.reading(.yourReview, .asked("Priya asked you"), at: 2),
            4103: Steps.reading(.merged, .merged, at: 3), 4200: Steps.reading(.teammateReview, .findReviewer, at: 4),
        ]
        let work = [
            Steps.work(5103, .inProgress, story: 5001, linked: [Steps.linked(4101)]), Steps.work(5104, .toDo, story: 5001),
            Steps.work(5201, .inProgress, story: 5002), Steps.work(5401, .toDo),
        ]
        let board = Steps.board(stages, missions: [checkout, cart])
            .withWork(work, missions: [checkout, cart], stories: [Steps.task(5001), Steps.task(5002)])
        #expect(board.lanes.map(\.kind) == [.mission(checkout.key), .mission(cart.key), .story(Steps.task(5002)), .notInAMission])
        #expect(board.completed == [Steps.pr(4103)])

        let titles: [ItemRef: String] = [
            Steps.pr(4101): "Round cart totals", Steps.pr(4102): "Retry backoff", Steps.pr(4103): "Cart badge",
            Steps.pr(4200): "Café menu", Steps.task(5104): "Totals tests", Steps.task(5201): "Profile page",
            Steps.task(5401): "Update docs",
        ]
        let missions = [checkout.key: "Checkout", cart.key: "Cart"]
        func matching(_ text: String) throws -> PullRequestBoard {
            try board.matching(#require(BoardSearch(text))) { item in
                switch item {
                case .pullRequest(let card):
                    BoardSearch.Card(
                        refs: [card.ref],
                        names: ["PR \(card.ref.shortOrderLabel)", titles[card.ref] ?? "", card.mission.flatMap { missions[$0] } ?? ""]
                    )
                case .work(let task):
                    BoardSearch.Card(refs: [task.ref], names: ["Task \(task.ref.id)", titles[task.ref] ?? ""])
                }
            }
        }
        func labels(_ board: PullRequestBoard) -> [[String]] {
            board.lanes.map { lane in board.columns.flatMap { lane.items(in: $0) }.map(\.ref.shortOrderLabel) }
        }

        // !4102's title: in both of its missions' lanes, counted once.
        let retry = try matching("retry")
        #expect(retry.search?.text == "retry")
        #expect(labels(retry) == [["!4102"], ["!4102"]])
        #expect(retry.counts == [.yourReview: 1])
        #expect(retry.taskCounts.isEmpty)
        #expect(retry.cardCount == 1)
        #expect(retry.upNext == board.upNext)
        #expect(retry.startNext == board.startNext)
        #expect(retry.refs == board.refs)
        #expect(retry.workOfPullRequests == board.workOfPullRequests)

        // Cart's mission's name matches its every card there, !4102 too, but not in Checkout's lane; !4101 by its title.
        // !4103, out, stays in Completed.
        let cartSearch = try matching("cart")
        #expect(cartSearch.lanes.map(\.kind) == [.mission(checkout.key), .mission(cart.key)])
        #expect(labels(cartSearch) == [["!4101"], ["!4102", "!4103"]])
        #expect(cartSearch.completed == [Steps.pr(4103)])
        #expect(cartSearch.lanes[1].completed == [Steps.pr(4103)])
        #expect(cartSearch.count(of: .completed) == 1)
        #expect(cartSearch.count(of: .stage(.merged)) == 0)
        #expect(cartSearch.count(of: .stage(.inProgress)) == 1)
        #expect(cartSearch.cardCount == 3)
        #expect(cartSearch.firstCard == Steps.pr(4101))

        // A work item's own card, in any case and accent; and a lane of what's in no mission.
        let tests = try matching("TOTALS TESTS")
        #expect(labels(tests) == [["5104"]])
        #expect(tests.counts.isEmpty)
        #expect(tests.taskCounts == [.toStart: 1])
        #expect(tests.count(of: .toStart) == 1)
        #expect(tests.firstCard == Steps.task(5104))
        #expect(try labels(matching("cafe")) == [["!4200"]])
        #expect(try matching("cafe").lanes.map(\.kind) == [.notInAMission])

        let none = try matching("nothing like it")
        #expect(none.lanes.isEmpty)
        #expect(none.cardCount == 0)
        #expect(none.firstCard == nil)
        #expect(BoardText.noMatch(try #require(BoardSearch(" nothing like it"))) == "No card matches “nothing like it”.")
    }

    /// While the search hides some of a lane's cards, a move within a column swaps places only with the cards that show, at
    /// either end of those too, and those it hides keep theirs once it's cleared.
    @Test func aMoveSwapsPlacesOnlyWithTheCardsThatShow() throws {
        var checkout = Steps.mission([Steps.step(4101, .next)])
        checkout.story = MissionStory(ref: Steps.task(5001))
        let work = [
            Steps.work(5103, .inProgress, story: 5001), Steps.work(5104, .toDo, story: 5001), Steps.work(5105, .toDo, story: 5001),
            Steps.work(5108, .toDo, story: 5001),
        ]
        func board(_ orders: LaneOrders = LaneOrders()) -> PullRequestBoard {
            Steps.board([4101: Steps.reading(.inProgress, .draft, at: 1)], missions: [checkout])
                .withWork(work, missions: [checkout], stories: [Steps.task(5001)], yourOrder: orders)
        }
        let titles: [ItemRef: String] = [
            Steps.pr(4101): "Round cart totals", Steps.task(5103): "Cart tests", Steps.task(5104): "Totals tests",
            Steps.task(5105): "Release notes", Steps.task(5108): "Rounding tests",
        ]
        let search = try #require(BoardSearch("tests"))
        let lane = try #require(board().matching(search) { item in
            BoardSearch.Card(refs: [item.ref], names: [titles[item.ref] ?? ""])
        }.lanes.first)
        #expect(lane.items(in: .stage(.inProgress)).map(\.ref.shortOrderLabel) == ["5103"])
        #expect(lane.items(in: .toStart).map(\.ref.shortOrderLabel) == ["5104", "5108"])
        #expect(lane.wholeOrder?.map(\.shortOrderLabel) == ["!4101", "5103", "5104", "5105", "5108"])

        let moved = try #require(lane.moving(Steps.task(5108), .up))
        #expect(moved.order.map(\.shortOrderLabel) == ["!4101", "5103", "5108", "5105", "5104"])
        #expect(moved.place == LanePlace(position: 1, count: 2))
        // 5103 is the first In progress shows, though !4101, hidden, is above it.
        #expect(lane.moving(Steps.task(5103), .up) == nil)

        let cleared = try #require(board(LaneOrders([(.story(Steps.task(5001)), moved.order)])).lanes.first)
        #expect(cleared.items(in: .toStart).map(\.ref.shortOrderLabel) == ["5108", "5105", "5104"])
        #expect(cleared.wholeOrder == nil)
    }

    /// A story's lane reads finished only where all its work is resolved or done, not where only the work the search shows
    /// is: there it doesn't say it holds only what's finished.
    @Test func aStorysLaneReadsFinishedOnlyWhereItIs() throws {
        let work = [
            Steps.work(5201, .completed, story: 5002), Steps.work(5202, .toDo, story: 5002), Steps.work(5301, .completed, story: 5003),
            Steps.work(5302, .resolved, story: 5003),
        ]
        let board = Steps.board([:]).withWork(work, missions: [], stories: [Steps.task(5002), Steps.task(5003)])
        let titles = [5201: "Done first", 5202: "Still to do", 5301: "Done too", 5302: "Resolved"]
        let shown = try board.matching(#require(BoardSearch("done"))) { item in
            BoardSearch.Card(refs: [item.ref], names: [item.ref.number.flatMap { titles[$0] } ?? ""])
        }
        #expect(shown.lanes.map { $0.tasks.map(\.ref.shortOrderLabel) } == [["5201"], ["5301"]])
        #expect(!shown.lanes[0].isFinishedStory)
        #expect(shown.lanes[1].isFinishedStory)
    }

    /// Where a drop's column folds once the card moved, only the cards the search shows count: here it has the room it
    /// wouldn't have beside Approved's card, which the search hides.
    @Test func aDropsColumnFoldsByTheCardsTheSearchShows() throws {
        let board = Steps.board([
            4101: Steps.reading(.approved, .approvedBy("Maria"), at: 1), 4102: Steps.reading(.approved, .approvedBy("Maria"), at: 2),
        ])
        let moved = Steps.refs([
            4101: Steps.reading(.teammateReview, .waitingFor("Waiting for Sam"), at: 1),
            4102: Steps.reading(.approved, .approvedBy("Maria"), at: 2),
        ])
        let shown = board.columns.map { ShownColumn($0) }
        // Room for one open column and the rest as strips, not two.
        let widths = BoardWidths(scale: 1, available: 300)
        func folds(_ board: PullRequestBoard) -> Bool {
            board.foldsOnceMoved(
                to: .stage(.teammateReview), stages: moved, shown: shown, choices: BoardFolds(), open: [], widths: widths
            )
        }
        #expect(folds(board))
        let search = try #require(BoardSearch("4101"))
        #expect(!folds(board.matching(search) { BoardSearch.Card(refs: [$0.ref], names: [$0.ref.shortOrderLabel]) }))
    }
}
