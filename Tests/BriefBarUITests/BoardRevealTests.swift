import AppKit
import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

/// By Mission shows the mission a row's capsule asks for on the Board too: the page scrolls to its lane, just under the
/// column titles, which stay at its top, and with Lanes: None, which has no lane for it, the Board shows a lane for each
/// mission first. The lane keeps its place as the page narrows, as when the details open beside it. In a window off screen,
/// the page's height, under four missions' lanes.
@MainActor
@Suite(.keepsTheMainRunLoopRunning) struct BoardRevealTests {
    private static let height: CGFloat = 320

    /// Where each card's content is drawn, in the window's content view, and how wide the page is.
    @MainActor
    private final class Drawn {
        var frames: [ItemRef: CGRect] = [:]
        var width: CGFloat = 0
    }

    /// The room the details take beside the page, which narrows it.
    @MainActor
    private final class Room: ObservableObject {
        @Published var details: CGFloat = 0
    }

    /// The page By Mission, on the Board, as the page draws it anew as the order changes.
    private struct Page: View {
        @ObservedObject var order: PullRequestOrder
        let drawn: Drawn
        @ObservedObject var room: Room

        var body: some View {
            let kinds: Set<ItemRef.Kind> = [.pullRequest]
            let board = order.board(kinds: kinds)
            ScrollView {
                VStack(spacing: 0) {
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
                    // Room under the last lane, as a longer page has, so that the page can scroll any lane to its top.
                    Color.clear.frame(height: BoardRevealTests.height)
                }
            }
            // A scroller that shows as the page first scrolls would narrow it: in a window off screen, one does.
            .scrollIndicators(.never)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [drawn] in drawn.width = $0 }
            // As DetailsSplit narrows the page while the details show beside it.
            .padding(.trailing, room.details)
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
            stages: Dictionary(uniqueKeysWithValues: numbers.map { (ref($0), StageFacts(role: .author, state: .draft)) }),
            account: "robin@contoso.com"
        )
        order.setView(.board)
        order.setLanes(lanes)
        return order
    }

    @Test(arguments: [BoardLanes.missions, .none])
    func showingAMissionScrollsTheBoardToItsLane(lanes: BoardLanes) async throws {
        let order = try Self.order(lanes: lanes)
        let missions = MissionsBody.missions(order.missions, kinds: [.pullRequest])
        #expect(missions.count == 4)
        let last = try #require(missions.last)
        let card = try #require(last.steps.first?.ref)

        try await Self.showing(order) { window, host, drawn, _ in
            // With a lane for each mission, its card is below the window, where the other missions' lanes push it. With
            // Lanes: None, it's in view in the one lane; once the Board shows a lane for each mission, its own is below the
            // others too.
            let before = drawn.frames[card]
            if lanes == .missions {
                #expect((before?.minY ?? 0) > Self.height)
            }

            order.reveal(last.key, kinds: [.pullRequest])
            #expect(order.lanes == .missions)
            try await until("its lane to show") {
                // A window off screen draws only when it's asked to, as the screen asks one that shows.
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let frame = drawn.frames[card], frame != before else { return false }
                return frame.minY >= 0 && frame.maxY <= Self.height
            }
        }
    }

    /// Whichever lane it shows, the first too, the page scrolls it just under the column titles, which stay at its top over
    /// it: its first card comes to rest at the same height each time, under its lane's title, and the titles at the page's
    /// top, over the lane.
    @Test func everyLaneShownStartsJustUnderTheColumnTitlesTheFirstToo() async throws {
        let order = try Self.order(lanes: .missions)
        let missions = MissionsBody.missions(order.missions, kinds: [.pullRequest])
        #expect(missions.count == 4)

        try await Self.showing(order) { window, host, drawn, _ in
            var tops: [CGFloat] = []
            // From the last, down the page, up to the first, then down again.
            for mission in [missions[3], missions[0], missions[1], missions[2]] {
                let card = try #require(mission.steps.first?.ref)
                order.reveal(mission.key, kinds: [.pullRequest])
                let top = try await Self.resting(card, drawn: drawn, host: host, window: window)
                tops.append(top)
                try Self.expectTitlesAtTheTop(over: top, in: host, window: window)
            }
            #expect(tops.allSatisfy { abs($0 - tops[0]) < 0.5 }, "Each lane's first card, shown: \(tops)")
        }
    }

    /// The details open beside the page, which narrows, while it shows the last mission's lane: the lane keeps its place, just
    /// under the column titles, rather than the page losing it under room that opens above the lanes.
    @Test func aLaneShownKeepsItsPlaceAsTheDetailsOpenBesideThePage() async throws {
        let order = try Self.order(lanes: .missions)
        let missions = MissionsBody.missions(order.missions, kinds: [.pullRequest])
        let last = try #require(missions.last)
        let card = try #require(last.steps.first?.ref)

        try await Self.showing(order) { window, host, drawn, room in
            order.reveal(last.key, kinds: [.pullRequest])
            let top = try await Self.resting(card, drawn: drawn, host: host, window: window)
            let wide = drawn.width

            // The details at their narrowest, as DetailsSplit puts them beside it.
            room.details = 330 + 14
            try await until("the page to narrow") {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return drawn.width < wide - 300
            }
            let narrowed = try await Self.resting(card, drawn: drawn, host: host, window: window)
            #expect(abs(narrowed - top) < 0.5, "Its first card, \(top) points down the page, then \(narrowed)")
            try Self.expectTitlesAtTheTop(over: narrowed, in: host, window: window)
        }
    }

    /// Shows the page in a window as tall as `height` while `body` runs, once its eight cards are drawn.
    private static func showing(
        _ order: PullRequestOrder,
        _ body: @MainActor (_ window: NSWindow, _ host: NSView, _ drawn: Drawn, _ room: Room) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let drawn = Drawn()
        let room = Room()
        let host = NSHostingView(
            rootView: Page(order: order, drawn: drawn, room: room).environmentObject(AppServices(defaults: MemoryDefaults(), isDemo: true))
        )
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
        try await body(window, host, drawn, room)
    }

    /// Where a card's top comes to rest, in view, once the page scrolls to its lane and the board settles: once it has kept
    /// still for longer than the page goes on scrolling to it.
    private static func resting(_ card: ItemRef, drawn: Drawn, host: NSView, window: NSWindow) async throws -> CGFloat {
        var last: CGRect?
        var since = ContinuousClock.now
        try await until("its lane to show and keep still") {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let frame = drawn.frames[card], frame.minY >= 0, frame.maxY <= height else {
                last = nil
                return false
            }
            if frame != last {
                last = frame
                since = .now
                return false
            }
            return ContinuousClock.now - since > .milliseconds(1_200)
        }
        return last?.minY ?? -1
    }

    /// The column titles stay at the page's top, over the lane it shows, whose first card is this far down the page: In
    /// progress's title, whose line is the stage's pink, as wide as its column, is drawn just under the page's top. Nothing
    /// else there is pink: between two lanes, the page shows nothing but them.
    private static func expectTitlesAtTheTop(over card: CGFloat, in host: NSView, window: NSWindow) throws {
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / host.bounds.width
        var pink: NSColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance { pink = NSColor.systemPink.usingColorSpace(.sRGB) }
        let stage = try #require(pink)
        func isPink(_ x: Int, _ y: Int) -> Bool {
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { return false }
            return abs(color.redComponent - stage.redComponent) < 0.12 && abs(color.greenComponent - stage.greenComponent) < 0.12
                && abs(color.blueComponent - stage.blueComponent) < 0.12
        }
        // Across In progress's column, under its title's words, down from the page's top.
        let columns = Int(30 * scale)..<Int(150 * scale)
        let line = (0..<Int(60 * scale)).last { y in columns.filter { isPink($0, y) }.count > columns.count * 3 / 4 }
        let bottom = try #require(line.map { CGFloat($0 + 1) / scale }, "In progress's title, at the page's top")
        #expect(bottom > 20 && bottom < 45, "In progress's title ends \(bottom) points down the page")
        #expect(bottom <= card, "In progress's title ends \(bottom) points down the page, over the card at \(card)")
    }
}
