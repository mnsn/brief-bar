import AppKit
import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

/// By Mission shows the mission a row's capsule asks for on the Board too: the page scrolls to its lane, and with Lanes:
/// None, which has no lane for it, the Board shows a lane for each mission first. In a window off screen, the page's
/// height, under four missions' lanes.
@MainActor
@Suite(.keepsTheMainRunLoopRunning) struct BoardRevealTests {
    private static let height: CGFloat = 240

    /// Where each card's content is drawn, in the window's content view.
    @MainActor
    private final class Drawn {
        var frames: [ItemRef: CGRect] = [:]
    }

    /// The page By Mission, on the Board, as the page draws it anew as the order changes.
    private struct Page: View {
        @ObservedObject var order: PullRequestOrder
        let drawn: Drawn

        var body: some View {
            let kinds: Set<ItemRef.Kind> = [.pullRequest]
            let board = order.board(kinds: kinds)
            ScrollView {
                MissionsBody(
                    view: order.view(offering: OrderView.offered(for: kinds)), ordering: order, kinds: kinds, elsewhere: "GitHub",
                    openElsewhere: nil, listed: board.refs.sorted(), row: { _, _ in nil }, place: { _ in nil },
                    isSelected: { _ in false }, select: { _ in false }, rest: { _ in AnyView(EmptyView()) }, board: board,
                    card: { [drawn] card in
                        let label = "\(card.ref.shortOrderLabel) Totals"
                        let content = Text(label)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drawn.frames[card.ref] = $0 }
                        return BoardCardContent(view: AnyView(content), menu: AnyView(EmptyView()), label: label)
                    },
                    now: Date(timeIntervalSince1970: 1_792_000_000)
                )
                .padding()
            }
        }
    }

    private static func ref(_ number: Int) -> ItemRef {
        .pullRequest(organization: "contoso", number: number)
    }

    /// Pull Request Order, on, with four orders of two pull requests each, all of yours In progress, on the Board.
    private static func order(lanes: BoardLanes) throws -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let orders = [[4101, 4102], [4201, 4202], [4301, 4302], [4401, 4402]]
        var declared = DeclaredOrders()
        for (index, numbers) in orders.enumerated() {
            try declared.apply(
                OrderRequest(entries: numbers.enumerated().map { place, number in
                    .init(
                        link: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)",
                        after: place == 0 ? [] : ["\(numbers[place - 1])"]
                    )
                }),
                now: Date(timeIntervalSince1970: 1_791_900_000 + Double(index)), newID: UUID()
            )
        }
        declared.save(to: defaults)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        let numbers = orders.flatMap { $0 }
        order.publish(
            .azureDevOps,
            pullRequests: numbers.map { number in
                OrderPullRequest(
                    ref: ref(number), repository: "contoso/7d3f9a12/shop-web", sourceBranch: "robin/work-\(number)", targetBranch: "main",
                    author: "robin", createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
                )
            },
            stages: Dictionary(uniqueKeysWithValues: numbers.map { (ref($0), StageFacts(role: .author, failure: "Build failed")) }),
            account: "robin@contoso.com"
        )
        order.setView(.board)
        order.setLanes(lanes)
        return order
    }

    @Test(arguments: [BoardLanes.missions, .none])
    func showingAMissionScrollsTheBoardToItsLane(lanes: BoardLanes) async throws {
        _ = NSApplication.shared
        let order = try Self.order(lanes: lanes)
        let missions = MissionsBody.missions(order.missions, kinds: [.pullRequest])
        #expect(missions.count == 4)
        let last = try #require(missions.last)
        let card = try #require(last.steps.first?.ref)

        let drawn = Drawn()
        let host = NSHostingView(rootView: Page(order: order, drawn: drawn).environmentObject(AppServices(defaults: MemoryDefaults(), isDemo: true)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1_200, height: Self.height), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await until("the board") { drawn.frames.count == 8 }
        // With a lane for each mission, its card is below the window, where the other missions' lanes push it; with Lanes:
        // None, it's there once the Board shows a lane for each mission.
        if lanes == .missions {
            #expect((drawn.frames[card]?.minY ?? 0) > Self.height)
        }

        order.reveal(last.key, kinds: [.pullRequest])
        #expect(order.lanes == .missions)
        try await until("its lane to show") {
            guard let frame = drawn.frames[card] else { return false }
            return frame.minY >= 0 && frame.maxY <= Self.height
        }
    }
}
