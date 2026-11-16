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

    /// Pull Request Order, on, with an order of two drafts of yours, In progress, on the Board.
    private static func order() throws -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        var declared = DeclaredOrders()
        try declared.apply(
            OrderRequest(entries: [
                .init(link: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/4101", after: []),
                .init(link: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/4102", after: ["4101"]),
            ]),
            now: Date(timeIntervalSince1970: 1_791_900_000), newID: UUID()
        )
        declared.save(to: defaults)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        order.publish(
            .azureDevOps,
            pullRequests: [4101, 4102].map { number in
                OrderPullRequest(
                    ref: ref(number), repository: "contoso/7d3f9a12/shop-web", sourceBranch: "robin/work-\(number)", targetBranch: "main",
                    author: "robin", createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
                )
            },
            stages: [ref(4101): StageFacts(role: .author, state: .draft), ref(4102): StageFacts(role: .author, state: .draft)],
            account: "robin@contoso.com"
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
        let drawn = Drawn()
        _ = NSApplication.shared
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
        func settle(_ what: String, until shown: Set<ItemRef>) async throws {
            try await until(what) {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return drawn.shown == shown
            }
        }

        try await settle("the board", until: [Self.ref(4101), Self.ref(4102)])
        order.setBoardFolds(BoardFolds([.stage(.inProgress): .folded]))
        try await settle("In progress folded", until: [])
        searching.text = "4102"
        try await settle("the match in In progress, opened", until: [Self.ref(4102)])
        searching.text = ""
        try await settle("In progress folded again", until: [])
        #expect(order.boardFolds[.stage(.inProgress)] == .folded)
    }
}
