import AppKit
import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

/// The Board's keyboard, with the Mac's keyboard navigation off, as it comes: a click on a card gives it the keyboard's
/// focus, as a field takes it, then ⌘→ and ⌘← move it, again once it's drawn in its new column, and Return shows its
/// details; Tab reaches a card too. Where its details cover the Board, the keys move the card they show, which has the focus
/// back once they close. AppKit gets the clicks and the keys as it would from the window server, in a window off screen that
/// takes the keyboard, as the app's do, though the tests' process can't be the active app.
@MainActor
@Suite(.keepsTheMainRunLoopRunning) struct BoardKeyboardTests {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// Where the card's content is drawn, in the window's content view, and how often it was asked to show its details.
    @MainActor
    private final class Drawn {
        var frame: CGRect?
        var shown = 0
    }

    /// The details a click shows: on a narrow page, or at a bigger text size, over the Board, which they disable then, as
    /// `DetailsSplit` does, with a field to type in.
    @MainActor
    private final class Details: ObservableObject {
        @Published var shown: ItemRef?
        /// They go over the Board, rather than beside it.
        let covers: Bool

        init(covers: Bool = false) {
            self.covers = covers
        }
    }

    /// The Board of a page that lists Azure DevOps' pull requests, drawn anew as the order changes, as the page draws it.
    private struct Board: View {
        @ObservedObject var order: PullRequestOrder
        @ObservedObject var details: Details
        let drawn: Drawn

        var body: some View {
            let kinds: Set<ItemRef.Kind> = [.pullRequest]
            let covered = details.covers && details.shown != nil
            OrderBoardView(
                board: order.board(kinds: kinds), missions: MissionsBody.missions(order.missions, kinds: kinds), order: order,
                elsewhere: "GitHub", openElsewhere: nil, place: { _ in nil },
                card: { [drawn] card in
                    let label = "\(card.ref.shortOrderLabel) Totals"
                    let content = Text(label)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drawn.frame = $0 }
                    return BoardCardContent(view: AnyView(content), menu: AnyView(EmptyView()), label: label)
                },
                isSelected: { [details] in details.shown == $0 },
                select: { [drawn, details] ref in
                    drawn.shown += 1
                    details.shown = ref
                },
                setAsNext: nil, notOnBoard: 0, showByStatus: nil, now: Date(timeIntervalSince1970: 1_792_000_000)
            )
            .disabled(covered)
            .overlay(alignment: .topTrailing) {
                if covered {
                    TextField("Reply", text: .constant(""))
                        .frame(width: 200)
                }
            }
        }
    }

    private static let ref = ItemRef.pullRequest(organization: "contoso", number: 4093)

    /// Pull Request Order, on, told of one pull request of yours whose build failed: In progress.
    private static func order() -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        order.publish(
            .azureDevOps,
            pullRequests: [OrderPullRequest(
                ref: ref, repository: "contoso/7d3f9a12/shop-web", sourceBranch: "robin/totals", targetBranch: "main", author: "robin",
                createdAt: Date(timeIntervalSince1970: 1_791_000_000)
            )],
            stages: [ref: StageFacts(role: .author, failure: "Build failed")], account: "robin@contoso.com"
        )
        return order
    }

    /// Pull Request Order, on, with a session's order of !4101, then !4102 after it, which can complete: it waits.
    private static func ordered() throws -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        var orders = DeclaredOrders()
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        try orders.apply(OrderRequest(entries: [.init(link: link(4101)), .init(link: link(4102), after: ["4101"])]))
        orders.save(to: defaults)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        order.publish(
            .azureDevOps,
            pullRequests: [4101, 4102].map { number in
                OrderPullRequest(
                    ref: .pullRequest(organization: "contoso", number: number), repository: "contoso/7d3f9a12/shop-web",
                    sourceBranch: "robin/\(number)", targetBranch: "main", author: "robin",
                    createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
                )
            },
            stages: [
                .pullRequest(organization: "contoso", number: 4101): StageFacts(role: .author),
                .pullRequest(organization: "contoso", number: 4102): StageFacts(role: .author, isReady: true),
            ],
            account: "robin@contoso.com"
        )
        return order
    }

    /// Shows the Board in a window while `body` runs, once its card is drawn.
    private static func showing(
        _ order: PullRequestOrder, details: Details = Details(),
        _ body: @MainActor (_ window: NSWindow, _ host: NSView, _ drawn: Drawn) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let drawn = Drawn()
        let host = NSHostingView(rootView: Board(order: order, details: details, drawn: drawn))
        let window = KeyWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1_200, height: 500), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // In, though off screen, without making the tests' process the active app: SwiftUI takes clicks only in a window
        // that's in.
        window.orderFrontRegardless()
        window.makeKey()
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await until("the card") { drawn.frame != nil }
        try await body(window, host, drawn)
    }

    /// A mission's lane shows the Undo line of your last change to that mission, as List's card does, where nothing else on
    /// the Board would: Set as Next to Merge, by a drop in its lane or from a menu, says so there, with Undo.
    @Test func aMissionsLaneShowsTheUndoOfYourChangeToIt() async throws {
        let order = try Self.ordered()
        let waits = ItemRef.pullRequest(organization: "contoso", number: 4102)
        #expect(order.stage(of: waits)?.stage == .waits)
        let mission = try #require(order.missions.first { $0.contains(waits) }?.key)
        try await Self.showing(order) { _, host, _ in
            let before = host.fittingSize.height
            MissionMenuContext.setAsNext(waits, in: mission, order: order)
            #expect(order.lastOrderChange?.mission == mission && order.stage(of: waits)?.stage == .canMerge)
            try await until("the lane's Undo line") { host.fittingSize.height > before + 10 }
        }
    }

    @Test func aClickedCardMovesWithTheCommandArrowsAndKeepsTheKeyboard() async throws {
        let order = Self.order()
        #expect(order.stage(of: Self.ref)?.stage == .inProgress)
        try await Self.showing(order) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details") { drawn.shown == 1 }

            // Each key once the card is drawn in its column, a moment later, as you'd press the next.
            @MainActor func move(_ arrow: KeyEquivalent, to stage: PullRequestStage, _ what: String) async throws {
                let before = drawn.frame?.minX
                Self.press(arrow, command: true, in: window)
                try await until(what) { order.stage(of: Self.ref)?.stage == stage && drawn.frame?.minX != before }
                try await Task.sleep(for: .milliseconds(200))
            }
            try await move(.rightArrow, to: .yourReview, "⌘→ to move the card")
            // Drawn anew in Your review, it has the keyboard again.
            try await move(.rightArrow, to: .teammateReview, "⌘→ to move it on from its new column")
            try await move(.leftArrow, to: .yourReview, "⌘← to move it back")
            Self.press(.return, in: window)
            try await until("Return to show its details") { drawn.shown == 2 }
        }
    }

    /// Tab, as the window takes it, goes to the next view in its key view loop: with the Mac's keyboard navigation off, only
    /// what a click focuses, as a field, which a card is. With it on, every control is, so the card may not come first.
    @Test(.enabled(if: UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 == 0))
    func tabReachesACardWithTheMacsKeyboardNavigationOff() async throws {
        let order = Self.order()
        try await Self.showing(order) { window, _, _ in
            window.selectNextKeyView(nil)
            Self.press(.rightArrow, command: true, in: window)
            try await until("⌘→ to move the card Tab reached") { order.stage(of: Self.ref)?.stage == .yourReview }
        }
    }

    /// On a narrow page, or at a bigger text size, a card's details cover the Board, which they disable: the card a click
    /// focused loses the keyboard's focus. ⌘→ and ⌘← move the card of the pull request they show then, as the app takes
    /// the keys, in the Board's window and while no field has them; once they close, the card has the focus back, and its
    /// own keys move it again.
    @Test func whileItsDetailsCoverTheBoardTheKeysMoveTheCardTheyShowWhichHasTheFocusBackOnceTheyClose() async throws {
        let order = Self.order()
        let details = Details(covers: true)
        try await Self.showing(order, details: details) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details over the Board") { details.shown == Self.ref }
            // The card loses the keys, as the disabled Board does in the app: in a window that isn't truly key, as the tests'
            // are, SwiftUI's focus doesn't follow that.
            #expect(window.makeFirstResponder(nil))
            try await Task.sleep(for: .milliseconds(200))
            Self.press(.rightArrow, command: true, in: window)
            try await Task.sleep(for: .milliseconds(200))
            #expect(order.stage(of: Self.ref)?.stage == .inProgress)

            @MainActor func move(_ arrow: KeyEquivalent, to stage: PullRequestStage, _ what: String) async throws {
                Self.press(arrow, command: true, in: window, throughTheApp: true)
                try await until(what) { order.stage(of: Self.ref)?.stage == stage }
                try await Task.sleep(for: .milliseconds(200))
            }
            try await move(.rightArrow, to: .yourReview, "⌘→ to move the card the details show")
            try await move(.leftArrow, to: .inProgress, "⌘← to move it back")

            // A field has them, for its insertion point; another window's aren't the Board's.
            let field = try #require(Self.first(NSTextField.self, in: host))
            #expect(window.makeFirstResponder(field))
            #expect(window.firstResponder is NSText)
            Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
            #expect(window.makeFirstResponder(nil))
            let other = KeyWindow(contentRect: CGRect(x: -21_000, y: -20_000, width: 200, height: 200), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.orderFrontRegardless()
            defer { other.close() }
            Self.press(.rightArrow, command: true, in: other, throughTheApp: true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(order.stage(of: Self.ref)?.stage == .inProgress)

            // Once they close, the card has the keyboard's focus back, as its own keys show.
            details.shown = nil
            try await Task.sleep(for: .milliseconds(300))
            Self.press(.rightArrow, command: true, in: window)
            try await until("⌘→ to move the card that has the focus back") { order.stage(of: Self.ref)?.stage == .yourReview }
        }
    }

    /// The first AppKit view of this type in a view, or under it.
    private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { first(type, in: $0) }.first
    }

    /// A click in the middle of this rectangle of the window's content view.
    private static func click(at frame: CGRect, in host: NSView) {
        guard let window = host.window else { return }
        let point = host.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            window.sendEvent(event)
        }
    }

    /// A key, pressed and let go: an arrow or Return. To the window, as it gives them to its views; or through the app's own
    /// handling, as the window server's keys come, which has the app's key monitors look first.
    private static func press(_ key: KeyEquivalent, command: Bool = false, in window: NSWindow, throughTheApp: Bool = false) {
        let (code, character): (UInt16, Character) = switch key {
        case .rightArrow: (124, Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
        case .leftArrow: (123, Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))
        default: (36, "\r")
        }
        var flags: NSEvent.ModifierFlags = command ? [.command] : []
        if key == .rightArrow || key == .leftArrow { flags.formUnion([.numericPad, .function]) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: code
            ) else { continue }
            if throughTheApp {
                NSApp.sendEvent(event)
            } else {
                window.sendEvent(event)
            }
        }
    }
}
