import AppKit
import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

/// My Work's search on the Board: a column you folded opens while it holds a match, and folds again once the search is
/// cleared, your fold kept. In a window off screen.
@MainActor
@Suite(.keepsTheMainRunLoopRunning) struct BoardSearchViewTests {
    /// The cards drawn now.
    @MainActor
    private final class Drawn {
        var shown: Set<ItemRef> = []
    }

    /// What the search looks for.
    @MainActor
    private final class Searching: ObservableObject {
        @Published var text = ""
    }

    /// The page By Mission, on the Board, as a search shows it: each card found by its number.
    private struct Page: View {
        @ObservedObject var order: PullRequestOrder
        @ObservedObject var searching: Searching
        let drawn: Drawn

        var body: some View {
            let kinds: Set<ItemRef.Kind> = [.pullRequest]
            let whole = order.board(kinds: kinds)
            let board = BoardSearch(searching.text).map { search in
                whole.matching(search) { BoardSearch.Card(refs: [$0.ref], names: [$0.ref.shortOrderLabel]) }
            } ?? whole
            MissionsBody(
                view: .board, ordering: order, kinds: kinds, elsewhere: "GitHub", openElsewhere: nil, listed: whole.refs.sorted(),
                row: { _, _ in nil }, place: { _ in nil }, isSelected: { _ in false }, select: { _ in false },
                rest: { _ in AnyView(EmptyView()) }, board: board,
                card: { [drawn] card in
                    let label = "\(card.ref.shortOrderLabel) Totals"
                    let content = Text(label)
                        .onAppear { drawn.shown.insert(card.ref) }
                        .onDisappear { drawn.shown.remove(card.ref) }
                    return BoardCardContent(view: AnyView(content), menu: AnyView(EmptyView()), label: label)
                },
                now: Date(timeIntervalSince1970: 1_792_000_000)
            )
            .padding()
        }
    }

    private static func ref(_ number: Int) -> ItemRef {
        .pullRequest(organization: "contoso", number: number)
    }

    /// Pull Request Order, on, with an order of pull requests of yours, each after the one before, on the Board: by default two
    /// drafts, In progress.
    private static func order(
        _ stages: [Int: StageFacts] = [4101: StageFacts(role: .author, state: .draft), 4102: StageFacts(role: .author, state: .draft)]
    ) throws -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let numbers = stages.keys.sorted()
        var declared = DeclaredOrders()
        try declared.apply(
            OrderRequest(entries: numbers.enumerated().map { place, number in
                .init(
                    link: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)",
                    after: place == 0 ? [] : ["\(numbers[place - 1])"]
                )
            }),
            now: Date(timeIntervalSince1970: 1_791_900_000), newID: UUID()
        )
        declared.save(to: defaults)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        order.publish(
            .azureDevOps,
            pullRequests: numbers.map { number in
                OrderPullRequest(
                    ref: ref(number), repository: "contoso/7d3f9a12/shop-web", sourceBranch: "robin/work-\(number)", targetBranch: "main",
                    author: "robin", createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
                )
            },
            stages: Dictionary(uniqueKeysWithValues: stages.map { (ref($0.key), $0.value) }), account: "robin@contoso.com"
        )
        order.setView(.board)
        order.setLanes(.missions)
        return order
    }

    /// In progress, once you fold it, opens while the search matches a card in it, with that card alone, and folds again
    /// once it's cleared: your fold is kept as it was.
    @Test func aColumnYouFoldedOpensWhileItHoldsAMatch() async throws {
        let order = try Self.order()
        let searching = Searching()
        try await Self.showing(order, searching) { settle in
            try await settle("the board", [Self.ref(4101), Self.ref(4102)])
            order.setBoardFolds(BoardFolds([.stage(.inProgress): .folded]))
            try await settle("In progress folded", [])
            searching.text = "4102"
            try await settle("the match in In progress, opened", [Self.ref(4102)])
            searching.text = ""
            try await settle("In progress folded again", [])
        }
        #expect(order.boardFolds[.stage(.inProgress)] == .folded)
    }

    /// A column Up Next's "2 more ›" opens for the moment while the search shows only what matches is open for as long as
    /// the search: once it's cleared, In progress, which you folded, is folded again, rather than open for a moment that
    /// began in the search.
    @Test func whatTheSearchOpensForTheMomentFoldsAgainOnceItsCleared() async throws {
        let waiting = StageFacts(role: .author, waitingFor: "Waiting on Priya")
        let order = try Self.order([4101: StageFacts(role: .author, state: .draft), 4102: waiting, 4103: waiting])
        let searching = Searching()
        try await Self.showing(order, searching) { settle in
            try await settle("the board", [Self.ref(4101), Self.ref(4102), Self.ref(4103)])
            order.setBoardFolds(BoardFolds([.stage(.inProgress): .folded]))
            try await settle("In progress folded", [Self.ref(4102), Self.ref(4103)])
            // In progress has no match: it folds, and "2 more ›" opens it for the moment.
            searching.text = "4102"
            try await settle("the match in Teammate's review", [Self.ref(4102)])
            order.revealedColumn = .inProgress
            try await settle("In progress opened for the moment", [Self.ref(4102)]) { order.revealedColumn == nil }
            searching.text = ""
            try await settle("In progress folded again", [Self.ref(4102), Self.ref(4103)])
        }
        #expect(order.boardFolds[.stage(.inProgress)] == .folded)
    }

    /// Shows the page in a window off screen while `body` runs, which waits with `settle` until the cards drawn are those it
    /// names, and anything else it waits for holds.
    private static func showing(
        _ order: PullRequestOrder, _ searching: Searching, _ body: @MainActor (_ settle: Settle) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let drawn = Drawn()
        let host = NSHostingView(
            rootView: Page(order: order, searching: searching, drawn: drawn)
                .environmentObject(AppServices(defaults: MemoryDefaults(), isDemo: true))
        )
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 1_200, height: 600), styleMask: .borderless, backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try await body(Settle(host: host, window: window, drawn: drawn))
    }

    /// Waits until the cards drawn are those it names, and anything else it's given holds: drawing the window off screen
    /// each time, as the screen would.
    @MainActor
    private struct Settle {
        let host: NSView
        let window: NSWindow
        let drawn: Drawn

        func callAsFunction(_ what: String, _ shown: Set<ItemRef>, also: () -> Bool = { true }) async throws {
            try await until(what) {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return drawn.shown == shown && also()
            }
        }
    }
}
