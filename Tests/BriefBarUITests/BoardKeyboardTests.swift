import AppKit
import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

/// The Board's keyboard, with the Mac's keyboard navigation off, as it comes: a click on a card gives it the keyboard's
/// focus, as a field takes it, then ⌘→ and ⌘← move it, again once it's drawn in its new column, and Return shows its
/// details; Tab reaches a card too, a folded column's strip, whose Return opens it, and the line a finished mission's
/// or story's lane folds to, whose Return shows it. Where its details cover the Board, the keys move the card whose own
/// details show, which has the focus back once they close, and they say why one can't move. AppKit gets the clicks and
/// the keys as it would from the window server, in a window off screen that takes the keyboard, as the app's do, though
/// the tests' process can't be the active app. One test at a time: the app gives a key to the window that was made key
/// last, whichever test's it is.
@MainActor
@Suite(.serialized, .keepsTheMainRunLoopRunning) struct BoardKeyboardTests {
    private final class KeyWindow: TestWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// Where the card's content is drawn, in the window's content view, in which column, and how often it was asked to show
    /// its details.
    @MainActor
    private final class Drawn {
        /// The last card's drawn, which is the card's where there's one.
        var frame: CGRect?
        var frames: [ItemRef: CGRect] = [:]
        var columns: [ItemRef: PullRequestStage] = [:]
        /// How many of each card's are drawn: two for a moment as it moves.
        var views: [ItemRef: Int] = [:]
        var shown = 0

        func draw(_ ref: ItemRef, in column: PullRequestStage, at frame: CGRect) {
            self.frame = frame
            frames[ref] = frame
            columns[ref] = column
        }

        func isDrawn(_ ref: ItemRef) -> Bool {
            views[ref, default: 0] > 0
        }
    }

    /// The column the Board doesn't draw cards in until the test lets it: as a busy Mac draws a moved card in its new column
    /// late.
    @MainActor
    private final class Late: ObservableObject {
        @Published var column: PullRequestStage?

        /// The Board draws its cards at last, as it does anew when the order it watches changes.
        func release(redrawing order: PullRequestOrder) {
            column = nil
            order.objectWillChange.send()
        }
    }

    /// How long a card a key moved is owed the keyboard's focus, as the test has it: each move's wait lasts until the test
    /// ends it, rather than the app's ten seconds.
    @MainActor
    private final class FocusWaits {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        /// How many ended: each counts as the move's wait goes on, and before the Board stops owing its card the focus.
        private(set) var ended = 0

        /// How many moves wait now.
        var count: Int { waiting.count }

        func wait() async {
            await withCheckedContinuation { waiting.append($0) }
            ended += 1
        }

        /// Ends every move's wait.
        func end() {
            let waits = waiting
            waiting = []
            for wait in waits { wait.resume() }
        }
    }

    /// The details a click shows: on a narrow page, or at a bigger text size, over the Board, which they disable then, as
    /// `DetailsSplit` does, with a field to type in.
    @MainActor
    private final class Details: ObservableObject {
        @Published var shown: ItemRef?
        /// A page is over them, such as a linked pull request's or a file's.
        @Published var hasPageOver = false
        /// They go over the Board, rather than beside it.
        let covers: Bool
        /// Beside the Board, they have a field to type in too.
        let hasField: Bool

        init(covers: Bool = false, hasField: Bool = false) {
            self.covers = covers
            self.hasField = hasField
        }
    }

    /// Your sprint work, on My Work's Board with + Sprint Tasks: the sprint's stories, in its order, which have lanes.
    private struct Sprint {
        var work: [SprintWork]
        var stories: [ItemRef]
    }

    /// The Board of a page that lists Azure DevOps' pull requests, drawn anew as the order changes, as the page draws it;
    /// with your sprint work on it too, as My Work's, if given.
    private struct Board: View {
        @ObservedObject var order: PullRequestOrder
        @ObservedObject var details: Details
        @ObservedObject var late: Late
        let drawn: Drawn
        let waits: FocusWaits?
        let sprint: Sprint?

        var body: some View {
            let kinds: Set<ItemRef.Kind> = [.pullRequest]
            let covered = details.covers && details.shown != nil
            let missions = MissionsBody.missions(order.missions, kinds: kinds)
            let board = order.board(kinds: kinds)
            OrderBoardView(
                board: sprint.map { board.withWork($0.work, missions: missions, stories: $0.stories) } ?? board, missions: missions,
                order: order, elsewhere: "GitHub", openElsewhere: nil, place: { _ in nil },
                card: { [drawn, late] card in
                    guard card.stage != late.column else { return nil }
                    let label = "\(card.ref.shortOrderLabel) Totals"
                    let content = Text(label)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            drawn.draw(card.ref, in: card.stage, at: $0)
                        }
                        .onAppear { drawn.views[card.ref, default: 0] += 1 }
                        .onDisappear { drawn.views[card.ref, default: 0] -= 1 }
                    return BoardCardContent(view: AnyView(content), menu: AnyView(EmptyView()), label: label)
                },
                isSelected: { [details] in details.shown == $0 },
                select: { [drawn, details] ref in
                    drawn.shown += 1
                    details.shown = ref
                },
                shownOnTop: details.hasPageOver ? nil : details.shown,
                setAsNext: nil, work: sprint.map { _ in work }, notOnBoard: 0, showByStatus: nil,
                now: Date(timeIntervalSince1970: 1_792_000_000), focusWait: waits.map { waits in { @MainActor in await waits.wait() } },
                // On CI the main actor's turns can come seconds late, so a card can take the keyboard after the app's half
                // second: a column a key opened folds back here only once a card in another column has the keyboard.
                keyMomentWait: .seconds(3_600)
            )
            .disabled(covered)
            .overlay(alignment: .topTrailing) {
                if covered || details.hasField && details.shown != nil {
                    TextField("Reply", text: .constant(""))
                        .frame(width: 200)
                }
            }
        }

        /// A work item's card, its number, and its story's lane's header, its story's.
        private var work: BoardWorkContent {
            BoardWorkContent(
                card: { [drawn] task in
                    let label = task.ref.shortOrderLabel
                    let content = Text(label)
                        .onAppear { drawn.views[task.ref, default: 0] += 1 }
                        .onDisappear { drawn.views[task.ref, default: 0] -= 1 }
                    return BoardCardContent(view: AnyView(content), menu: AnyView(EmptyView()), label: label)
                },
                story: { ref, _ in AnyView(Text(ref.shortOrderLabel)) },
                isSelected: { [details] in details.shown == $0 },
                select: { [details] in details.shown = $0 }
            )
        }
    }

    private static let ref = ItemRef.pullRequest(organization: "contoso", number: 4093)
    /// Why a card can't go to Approved from Teammate's review, as the Board says it.
    private static let azureDevOpsDecides = "Azure DevOps decides when it's approved: once the reviewers it requires approve"

    /// Pull Request Order, on, told of one pull request of yours, a draft: In progress.
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
            stages: [ref: StageFacts(role: .author, state: .draft)], account: "robin@contoso.com"
        )
        return order
    }

    /// A review Sam asks you for.
    private static let review = ItemRef.pullRequest(organization: "contoso", number: 4088)

    /// Pull Request Order, on, told of one pull request of yours, a draft, In progress, and of a review Sam asks you for, in
    /// Your review.
    private static func withAReview() -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        order.publish(
            .azureDevOps,
            pullRequests: [(ref, "robin/totals", "robin"), (review, "sam/coupons", "sam")].map { ref, branch, author in
                OrderPullRequest(
                    ref: ref, repository: "contoso/7d3f9a12/shop-web", sourceBranch: branch, targetBranch: "main", author: author,
                    createdAt: Date(timeIntervalSince1970: 1_791_000_000)
                )
            },
            stages: [ref: StageFacts(role: .author, state: .draft), review: StageFacts(role: .reviewer, asksYou: "Sam asked you")],
            account: "robin@contoso.com"
        )
        return order
    }

    /// A pull request of yours that merged: on My Work with your sprint work, in Completed once it's out, its stage Merged.
    private static let merged = ItemRef.pullRequest(organization: "contoso", number: 4085)

    /// Pull Request Order, on, told of one pull request of yours, a draft, In progress, and of one of yours that merged.
    private static func withAMergedPullRequest() -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        order.publish(
            .azureDevOps,
            pullRequests: [
                OrderPullRequest(
                    ref: ref, repository: "contoso/7d3f9a12/shop-web", sourceBranch: "robin/totals", targetBranch: "main",
                    author: "robin", createdAt: Date(timeIntervalSince1970: 1_791_000_000)
                ),
                OrderPullRequest(
                    ref: merged, repository: "contoso/7d3f9a12/shop-web", sourceBranch: "robin/badges", targetBranch: "main",
                    author: "robin", state: .merged, createdAt: Date(timeIntervalSince1970: 1_790_000_000)
                ),
            ],
            stages: [ref: StageFacts(role: .author, state: .draft), merged: StageFacts(role: .author, state: .merged)],
            account: "robin@contoso.com"
        )
        return order
    }

    /// Pull Request Order, on, with a session's order of !4101, then !4102 after it, which can complete: it waits.
    /// - Parameter firstIsADraft: !4101 is a draft: it's In progress, which ⌘→ moves to Your review.
    private static func ordered(firstIsADraft: Bool = false) throws -> PullRequestOrder {
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
                .pullRequest(organization: "contoso", number: 4101):
                    firstIsADraft ? StageFacts(role: .author, state: .draft) : StageFacts(role: .author),
                .pullRequest(organization: "contoso", number: 4102): StageFacts(role: .author, isReady: true),
            ],
            account: "robin@contoso.com"
        )
        return order
    }

    /// Pull Request Order, on, with a session's order of !4101, then !4102 after it, both merged: a finished mission, whose
    /// lane folds; and a draft of yours in no mission.
    private static func finishedMission() throws -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        BoardLanes.missions.save(to: defaults)
        var orders = DeclaredOrders()
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        try orders.apply(OrderRequest(entries: [.init(link: link(4101)), .init(link: link(4102), after: ["4101"])]))
        orders.save(to: defaults)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        let merged = [4101, 4102].map { ItemRef.pullRequest(organization: "contoso", number: $0) }
        var stages = Dictionary(uniqueKeysWithValues: merged.map { ($0, StageFacts(role: .author, state: .merged)) })
        stages[ref] = StageFacts(role: .author, state: .draft)
        order.publish(
            .azureDevOps,
            pullRequests: merged.map { merged in
                OrderPullRequest(
                    ref: merged, repository: "contoso/7d3f9a12/shop-web", sourceBranch: "robin/\(merged.shortOrderLabel)",
                    targetBranch: "main", author: "robin", state: .merged, createdAt: Date(timeIntervalSince1970: 1_790_000_000)
                )
            } + [OrderPullRequest(
                ref: ref, repository: "contoso/7d3f9a12/shop-web", sourceBranch: "robin/totals", targetBranch: "main", author: "robin",
                createdAt: Date(timeIntervalSince1970: 1_791_000_000)
            )],
            stages: stages, account: "robin@contoso.com"
        )
        return order
    }

    /// Shows the Board in a window while `body` runs, once its card is drawn.
    /// - Parameters:
    ///   - waits: how long a card a key moved is owed the keyboard's focus, as the test ends it; nil for as long as in the
    ///     app.
    ///   - sprint: your sprint work, on the Board as on My Work; nil for only the pull requests.
    private static func showing(
        _ order: PullRequestOrder, details: Details = Details(), late: Late = Late(), waits: FocusWaits? = nil,
        sprint: Sprint? = nil, _ body: @MainActor (_ window: NSWindow, _ host: NSView, _ drawn: Drawn) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let drawn = Drawn()
        let host = NSHostingView(
            rootView: Board(order: order, details: details, late: late, drawn: drawn, waits: waits, sprint: sprint)
        )
        // Wide enough for every column, so that the Board doesn't scroll sideways: its scroller, which shows only while the
        // details don't cover the Board, would change its height as they close.
        let window = KeyWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1_400, height: 500), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // In, though off screen, without making the tests' process the active app: SwiftUI takes clicks only in a window
        // that's in.
        window.orderFrontRegardless()
        window.makeKey()
        defer {
            // No move waits on once the test's done.
            waits?.end()
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

            @MainActor func move(_ arrow: KeyEquivalent, to stage: PullRequestStage, _ what: String) async throws {
                try await Self.move(arrow, to: stage, what, order: order, drawn: drawn, in: window)
            }
            try await move(.rightArrow, to: .yourReview, "⌘→ to move the card")
            // Drawn anew in Your review, it has the keyboard again.
            try await move(.rightArrow, to: .teammateReview, "⌘→ to move it on from its new column")
            try await move(.leftArrow, to: .yourReview, "⌘← to move it back")
            try await Self.pressUntil("Return to show its details") {
                Self.press(.return, in: window)
                return drawn.shown == 2
            }
        }
    }

    /// In a joined column, ⌘→ and ⌘← still move a card stage by stage: drawn anew among the next stage's cards there, in
    /// the same column, it keeps the keyboard, so that the next key moves it on.
    @Test func theKeysMoveACardStageByStageInAJoinedColumnWhereItKeepsTheKeyboard() async throws {
        let order = Self.order()
        order.setBoardLayout(.simple)
        try await Self.showing(order) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details") { drawn.shown == 1 }
            try await Self.move(.rightArrow, to: .yourReview, "⌘→ to move the card into In review", order: order, drawn: drawn, in: window)
            for (arrow, stage) in [(KeyEquivalent.rightArrow, PullRequestStage.teammateReview), (.leftArrow, .yourReview)] {
                try await Self.pressUntil("⌘ and an arrow to move it to \(stage.title) in In review") {
                    Self.press(arrow, command: true, in: window)
                    return order.stage(of: Self.ref)?.stage == stage
                }
                try await until("the Board to draw it among \(stage.title)'s cards") { drawn.columns[Self.ref] == stage }
            }
        }
    }

    /// However long the Board takes to draw a card a key moved in its new column, as on a busy Mac, the card takes the
    /// keyboard back once it's drawn there, so that the next key moves it on.
    @Test func aMovedCardTakesTheKeyboardBackHoweverLongTheBoardTakesToDrawIt() async throws {
        let order = Self.order()
        let late = Late()
        try await Self.showing(order, late: late) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details") { drawn.shown == 1 }
            late.column = .yourReview
            try await Self.pressUntil("⌘→ to move it") {
                Self.press(.rightArrow, command: true, in: window)
                return order.stage(of: Self.ref)?.stage == .yourReview
            }
            // Longer than the Board once waited for it.
            try await Task.sleep(for: .milliseconds(1_500))
            late.release(redrawing: order)
            try await until("the card drawn in Your review at last") { drawn.columns[Self.ref] == .yourReview }
            try await Self.pressUntil("⌘→ to move it on, as it has the keyboard again") {
                Self.press(.rightArrow, command: true, in: window)
                return order.stage(of: Self.ref)?.stage == .teammateReview
            }
        }
    }

    /// One the Board draws in its new column only once the move's wait ended, as in a lane you fold and unfold later, is
    /// owed the keyboard no more: it doesn't take it. The test ends the wait itself, and lets the Board draw the card once
    /// it has ended.
    @Test func aMovedCardTheBoardDrawsOnlyAfterItsWaitDoesntTakeTheKeyboard() async throws {
        let order = Self.order()
        let late = Late()
        let waits = FocusWaits()
        try await Self.showing(order, late: late, waits: waits) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details") { drawn.shown == 1 }
            late.column = .yourReview
            try await Self.pressUntil("⌘→ to move it") {
                Self.press(.rightArrow, command: true, in: window)
                return order.stage(of: Self.ref)?.stage == .yourReview
            }
            try await until("the move to wait for the card to be drawn in its new column") { waits.count == 1 }
            waits.end()
            try await until("the move's wait to end") { waits.ended == 1 }
            late.release(redrawing: order)
            try await until("the card drawn in Your review") { drawn.columns[Self.ref] == .yourReview }
            // A card that took the keyboard would take it as it appears, a moment after it's drawn.
            try await Task.sleep(for: .milliseconds(300))
            Self.press(.rightArrow, command: true, in: window)
            try await Task.sleep(for: .milliseconds(300))
            #expect(order.stage(of: Self.ref)?.stage == .yourReview, "The card took the keyboard once its wait had ended")
        }
    }

    /// Once a moved card has the keyboard back, it's owed it no more: hidden and drawn anew within the move's wait, as when
    /// you fold its lane and unfold it, it doesn't take it again.
    @Test func aMovedCardThatTookTheKeyboardBackIsntOwedItAgain() async throws {
        let order = Self.order()
        let late = Late()
        try await Self.showing(order, late: late) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details") { drawn.shown == 1 }
            try await Self.move(.rightArrow, to: .yourReview, "⌘→ to move it", order: order, drawn: drawn, in: window)
            try await Self.pressUntil("Return on the card, which has the keyboard back") {
                Self.press(.return, in: window)
                return drawn.shown == 2
            }
            late.column = .yourReview
            order.objectWillChange.send()
            try await until("the card hidden") { !drawn.isDrawn(Self.ref) }
            late.release(redrawing: order)
            try await until("the card drawn again") { drawn.isDrawn(Self.ref) }
            try await Task.sleep(for: .milliseconds(300))
            Self.press(.return, in: window)
            try await Task.sleep(for: .milliseconds(300))
            #expect(drawn.shown == 2, "The card took the keyboard again")
        }
    }

    /// A card a key moved doesn't take the keyboard back from a field you went to while the Board drew it in its new column.
    @Test func aMovedCardDrawnLateLeavesTheKeyboardToAFieldYouWentTo() async throws {
        let order = Self.order()
        let details = Details(hasField: true)
        let late = Late()
        try await Self.showing(order, details: details, late: late) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details, and a field beside them") {
                Self.first(NSTextField.self, in: host) != nil
            }
            late.column = .yourReview
            try await Self.pressUntil("⌘→ to move it") {
                Self.press(.rightArrow, command: true, in: window)
                return order.stage(of: Self.ref)?.stage == .yourReview
            }
            let field = try #require(Self.first(NSTextField.self, in: host))
            #expect(window.makeFirstResponder(field))
            late.release(redrawing: order)
            try await until("the card drawn in Your review") { drawn.columns[Self.ref] == .yourReview }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.firstResponder is NSText, "The card took the keyboard from the field")
        }
    }

    /// Nor from another card you went to meanwhile, which Return shows the details of still.
    @Test func aMovedCardDrawnLateLeavesTheKeyboardToAnotherCardYouWentTo() async throws {
        let order = try Self.ordered(firstIsADraft: true)
        let moved = ItemRef.pullRequest(organization: "contoso", number: 4101)
        let waits = ItemRef.pullRequest(organization: "contoso", number: 4102)
        #expect(order.stage(of: moved)?.stage == .inProgress && order.stage(of: waits)?.stage == .waits)
        let details = Details()
        let late = Late()
        try await Self.showing(order, details: details, late: late) { window, host, drawn in
            try await until("both cards") { drawn.frames[moved] != nil && drawn.frames[waits] != nil }
            Self.click(at: try #require(drawn.frames[moved]), in: host)
            try await until("the click to show its details") { details.shown == moved }
            late.column = .yourReview
            try await Self.pressUntil("⌘→ to move it") {
                Self.press(.rightArrow, command: true, in: window)
                return order.stage(of: moved)?.stage == .yourReview
            }
            Self.click(at: try #require(drawn.frames[waits]), in: host)
            try await until("the click on the other card to show its details") { details.shown == waits }
            // Return shows the details of the card that has the keyboard: the other one, which the click gave it.
            details.shown = nil
            try await Self.pressUntil("Return on the other card") {
                Self.press(.return, in: window)
                return details.shown == waits
            }
            late.release(redrawing: order)
            try await until("the moved card drawn in Your review") { drawn.columns[moved] == .yourReview }
            try await Task.sleep(for: .milliseconds(300))
            details.shown = nil
            Self.press(.return, in: window)
            try await until("Return to show the details of the card that has the keyboard") { details.shown != nil }
            #expect(details.shown == waits, "The moved card took the keyboard from the one you went to")
        }
    }

    /// ⌘→ moves a card into a column you folded, stage by stage as ever: the column opens while the card keeps the keyboard,
    /// so that it's drawn there and the next key moves it on, and what you chose stays.
    @Test func aKeyMovesACardIntoAColumnYouFoldedWhichOpensWhileTheCardKeepsTheKeyboard() async throws {
        let order = Self.order()
        order.setBoardFolds(BoardFolds([.stage(.yourReview): .folded]))
        try await Self.showing(order) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details") { drawn.shown == 1 }
            try await Self.move(.rightArrow, to: .yourReview, "⌘→ into Your review, folded", order: order, drawn: drawn, in: window)
            #expect(drawn.columns[Self.ref] == .yourReview)
            try await Self.move(.rightArrow, to: .teammateReview, "⌘→ to move it on from there", order: order, drawn: drawn, in: window)
            #expect(order.boardFolds == BoardFolds([.stage(.yourReview): .folded]))
        }
    }

    /// My Work's Show Them asks the Board for a work item's card in a column you folded: the column opens for the moment, and
    /// the card takes the keyboard, for Return to show its details and VoiceOver to read it. What you chose stays.
    @Test func aCardShowThemAsksForTakesTheKeyboardWithItsFoldedColumnOpenForTheMoment() async throws {
        let order = Self.order()
        order.setBoardFolds(BoardFolds([.toStart: .folded]))
        let task = ItemRef.workItem(organization: "contoso", id: 5052)
        let work = [SprintWork(ref: task, story: nil, progress: .toDo, pullRequests: [], copilotWorks: false)]
        let details = Details()
        try await Self.showing(order, details: details, sprint: Sprint(work: work, stories: [])) { window, _, drawn in
            #expect(!drawn.isDrawn(task))
            order.revealedCard = task
            try await until("To start to open for it") { drawn.isDrawn(task) }
            try await Self.pressUntil("Return to show its details") {
                Self.press(.return, in: window)
                return details.shown == task
            }
            #expect(drawn.shown == 0)
            #expect(order.revealedCard == nil)
            #expect(order.boardFolds == BoardFolds([.toStart: .folded]))
        }
    }

    /// Show Them asks for a merged pull request's card that names your work outside the sprint, in a finished mission's
    /// lane, which folds but while it holds work still to do: the lane stays open for it, so that the card is drawn and takes
    /// the keyboard.
    @Test func aCardShowThemAsksForInAFinishedMissionsLaneIsDrawnThereAndTakesTheKeyboard() async throws {
        let order = try Self.finishedMission()
        let merged = ItemRef.pullRequest(organization: "contoso", number: 4102)
        #expect(order.missions.first { $0.contains(merged) }?.isFinished == true)
        let task = ItemRef.workItem(organization: "contoso", id: 5181)
        let work = [SprintWork(
            ref: task, story: nil, progress: .inProgress, pullRequests: [LinkedPullRequest(ref: merged, state: .merged)],
            copilotWorks: false
        )]
        let details = Details()
        try await Self.showing(order, details: details, sprint: Sprint(work: work, stories: [])) { window, _, drawn in
            try await until("its card, in the lane its work keeps open") { drawn.isDrawn(merged) }
            order.revealedCard = merged
            try await Self.pressUntil("Return to show its details") {
                Self.press(.return, in: window)
                return details.shown == merged
            }
            #expect(order.revealedCard == nil)
        }
    }

    /// The column a key moved a card to stays open while a card in it has the keyboard: click another card there, and it
    /// stays open for that one, rather than fold under it.
    @Test func aColumnAKeyOpenedStaysOpenForAnotherCardInItYouGoTo() async throws {
        let order = Self.withAReview()
        order.setBoardFolds(BoardFolds([.stage(.yourReview): .folded]))
        let details = Details()
        try await Self.showing(order, details: details) { window, host, drawn in
            #expect(!drawn.isDrawn(Self.review))
            Self.click(at: try #require(drawn.frames[Self.ref]), in: host)
            try await until("the click to show its details") { details.shown == Self.ref }
            let before = drawn.frames[Self.ref]?.minX
            try await Self.pressUntil("⌘→ into Your review, folded") {
                Self.press(.rightArrow, command: true, in: window)
                return order.stage(of: Self.ref)?.stage == .yourReview
            }
            try await until("both cards drawn in Your review") {
                drawn.frames[Self.ref]?.minX != before && drawn.isDrawn(Self.review)
            }
            // Your review opens with an animation, until which the review takes no click: clicked again until it does.
            let review = try #require(drawn.frames[Self.review])
            try await Self.pressUntil("a click on the review to show its details") {
                Self.click(at: drawn.frames[Self.review] ?? review, in: host)
                return details.shown == Self.review
            }
            try await Task.sleep(for: .milliseconds(800))
            #expect(drawn.isDrawn(Self.review), "Your review folded under the card you went to")
            details.shown = nil
            try await Self.pressUntil("Return on the review, which has the keyboard") {
                Self.press(.return, in: window)
                return details.shown == Self.review
            }
            #expect(order.boardFolds == BoardFolds([.stage(.yourReview): .folded]))
        }
    }

    /// While its details cover the Board, ⌘→ moves the card they show into a column you folded too, which opens for it: once
    /// they close, the card has the keyboard back there, and its own keys move it on.
    @Test func aCardTheKeysMoveIntoAFoldedColumnWhileItsDetailsCoverTheBoardHasTheKeyboardBackThere() async throws {
        let order = Self.order()
        order.setBoardFolds(BoardFolds([.stage(.yourReview): .folded]))
        let details = Details(covers: true)
        try await Self.showing(order, details: details) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details over the Board") { details.shown == Self.ref }
            #expect(window.makeFirstResponder(nil))
            try await Task.sleep(for: .milliseconds(200))
            let before = drawn.frame?.minX
            Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
            try await until("⌘→ to move the card the details show, drawn in Your review") {
                order.stage(of: Self.ref)?.stage == .yourReview && drawn.frame?.minX != before
            }
            try await Task.sleep(for: .milliseconds(200))
            details.shown = nil
            try await Self.move(
                .rightArrow, to: .teammateReview, "⌘→ to move the card that has the focus back", order: order, drawn: drawn,
                in: window
            )
        }
    }

    /// Tab, as the window takes it, goes to the next view in its key view loop: with the Mac's keyboard navigation off, only
    /// what a click focuses, as a field, which a card is. With it on, every control is, so the card may not come first.
    @Test(.enabled(if: UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 == 0))
    func tabReachesACardWithTheMacsKeyboardNavigationOff() async throws {
        let order = Self.order()
        try await Self.showing(order) { window, _, drawn in
            window.selectNextKeyView(nil)
            try await Self.move(
                .rightArrow, to: .yourReview, "⌘→ to move the card Tab reached", order: order, drawn: drawn, in: window
            )
        }
    }

    /// A finished mission's lane folds to its line, which Tab reaches as it does a card, with the Mac's keyboard navigation
    /// off too: Return there shows the lane, and Tab goes on to what it held, a merged card.
    @Test(.enabled(if: UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 == 0))
    func tabReachesWhatAFinishedMissionsLaneFolds() async throws {
        let order = try Self.finishedMission()
        #expect(order.missions.first?.isFinished == true)
        let merged = Set([4101, 4102].map { ItemRef.pullRequest(organization: "contoso", number: $0) })
        let details = Details()
        try await Self.showing(order, details: details) { window, _, drawn in
            #expect(!merged.contains(where: drawn.isDrawn), "The finished mission's lane showed its cards")
            // Tab goes to the finished mission's line first, above the draft's lane, and Return there shows its lane...
            window.selectNextKeyView(nil)
            try await Self.pressUntil("Return on the finished mission's line, which Tab reached") {
                if merged.contains(where: drawn.isDrawn) { return true }
                Self.press(.return, in: window)
                return merged.contains(where: drawn.isDrawn)
            }
            #expect(details.shown == nil, "Tab went to the draft's card")
            // ...then to a merged card in it, whose Return shows its details.
            window.selectNextKeyView(nil)
            try await Self.pressUntil("Return on a merged card, which Tab reached next") {
                Self.press(.return, in: window)
                return details.shown.map(merged.contains) == true
            }
        }
    }

    /// On My Work, with your sprint work on the Board, a story's lane whose work is all resolved or done folds to its line,
    /// as a finished mission's does, which Tab reaches as it does a card, with the Mac's keyboard navigation off too: Return
    /// there shows the lane, and Tab goes on to its first card, in Merged.
    @Test(.enabled(if: UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 == 0))
    func tabReachesWhatAFinishedStorysLaneFolds() async throws {
        let story = ItemRef.workItem(organization: "contoso", id: 5101)
        let resolved = ItemRef.workItem(organization: "contoso", id: 5102)
        let done = ItemRef.workItem(organization: "contoso", id: 5103)
        let sprint = Sprint(
            work: [(done, .completed), (resolved, .resolved)].map { ref, progress in
                SprintWork(ref: ref, story: story, progress: progress, pullRequests: [], copilotWorks: false)
            },
            stories: [story]
        )
        let details = Details()
        try await Self.showing(Self.order(), details: details, sprint: sprint) { window, _, drawn in
            #expect(!drawn.isDrawn(resolved) && !drawn.isDrawn(done), "The finished story's lane showed its cards")
            // Tab goes to the story's line first, above the draft's lane, and Return there shows its lane...
            window.selectNextKeyView(nil)
            try await Self.pressUntil("Return on the finished story's line, which Tab reached") {
                if drawn.isDrawn(resolved) { return true }
                Self.press(.return, in: window)
                return drawn.isDrawn(resolved)
            }
            try await until("the done work's card in Completed") { drawn.isDrawn(done) }
            #expect(details.shown == nil, "Tab went to the draft's card")
            // ...then to its first card, the resolved work's in Merged, whose Return shows its details.
            window.selectNextKeyView(nil)
            try await Self.pressUntil("Return on the resolved work's card, which Tab reached next") {
                Self.press(.return, in: window)
                return details.shown == resolved
            }
        }
    }

    /// With the Mac's keyboard navigation off too, Tab goes on from a card to a folded column's strip in its lane, as to a
    /// card: Return there opens the column for the moment, with the keyboard on its first card in the lane, which keeps it
    /// open until the keyboard leaves it. What you chose stays.
    @Test(.enabled(if: UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 == 0))
    func tabReachesAFoldedColumnsStripWhereReturnOpensItOnItsFirstCard() async throws {
        let order = Self.withAReview()
        order.setBoardFolds(BoardFolds([.stage(.yourReview): .folded]))
        let details = Details()
        try await Self.showing(order, details: details) { window, host, drawn in
            #expect(!drawn.isDrawn(Self.review))
            // Tab to the card, then on.
            window.selectNextKeyView(nil)
            window.selectNextKeyView(nil)
            // Nothing else opens Your review, which you folded.
            try await Self.pressUntil("Return on Your review's strip, which Tab went to, to open it") {
                Self.press(.return, in: window)
                return drawn.isDrawn(Self.review)
            }
            details.shown = nil
            try await Self.pressUntil("Return on the review, which has the keyboard") {
                Self.press(.return, in: window)
                return details.shown == Self.review
            }
            try await Task.sleep(for: .milliseconds(800))
            #expect(drawn.isDrawn(Self.review), "Your review folded under the review that has the keyboard")
            #expect(order.boardFolds == BoardFolds([.stage(.yourReview): .folded]))
            let card = try #require(drawn.frames[Self.ref])
            try await Self.pressUntil("a click on the card to take the keyboard from Your review") {
                Self.click(at: drawn.frames[Self.ref] ?? card, in: host)
                return details.shown == Self.ref
            }
            try await until("Your review to fold back once the keyboard left it") { !drawn.isDrawn(Self.review) }
        }
    }

    /// On My Work, with your sprint work on the Board, a pull request that's out is in Completed, its stage still Merged:
    /// Return on Completed's strip, which Tab reaches as it does a card, opens the column for the moment on that pull
    /// request, which has the keyboard and keeps it open.
    @Test(.enabled(if: UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2 == 0))
    func returnOnAFoldedCompletedStripOpensItOnItsPullRequest() async throws {
        let order = Self.withAMergedPullRequest()
        #expect(order.stage(of: Self.merged)?.stage == .merged)
        order.setBoardFolds(BoardFolds([.completed: .folded]))
        let details = Details()
        try await Self.showing(order, details: details, sprint: Sprint(work: [], stories: [])) { window, _, drawn in
            #expect(!drawn.isDrawn(Self.merged))
            // Tab to the draft's card, then on to Completed's strip in its lane, the only other with a card.
            window.selectNextKeyView(nil)
            window.selectNextKeyView(nil)
            try await Self.pressUntil("Return on Completed's strip, which Tab went to, to open it") {
                Self.press(.return, in: window)
                return drawn.isDrawn(Self.merged)
            }
            details.shown = nil
            try await Self.pressUntil("Return on the merged pull request, which has the keyboard") {
                Self.press(.return, in: window)
                return details.shown == Self.merged
            }
            try await Task.sleep(for: .milliseconds(800))
            #expect(drawn.isDrawn(Self.merged), "Completed folded under the pull request that has the keyboard")
            #expect(order.boardFolds == BoardFolds([.completed: .folded]))
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

            // Each key once the card is drawn in its new column, a moment later: the keys move it from where the Board
            // last drew it.
            @MainActor func move(_ arrow: KeyEquivalent, to stage: PullRequestStage, _ what: String) async throws {
                let before = drawn.frame?.minX
                Self.press(arrow, command: true, in: window, throughTheApp: true)
                try await until(what) { order.stage(of: Self.ref)?.stage == stage && drawn.frame?.minX != before }
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
            // The app gives it the key, as it would to the window you're in.
            other.makeKey()
            defer { other.close() }
            Self.press(.rightArrow, command: true, in: other, throughTheApp: true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(order.stage(of: Self.ref)?.stage == .inProgress)
            window.makeKey()

            // Once they close, the card has the keyboard's focus back, as its own keys show.
            details.shown = nil
            try await Self.move(
                .rightArrow, to: .yourReview, "⌘→ to move the card that has the focus back", order: order, drawn: drawn,
                in: window
            )
        }
    }

    /// A page over the details, such as a linked pull request's, which has a stage of its own, or a file's, which shows none:
    /// the keys are the page's, and move no card, not even the one whose details are under it. Back on its details, they move
    /// it again.
    @Test func whileAPageIsOverItsDetailsTheKeysMoveNoCard() async throws {
        let order = Self.order()
        let details = Details(covers: true)
        try await Self.showing(order, details: details) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details over the Board") { details.shown == Self.ref }
            #expect(window.makeFirstResponder(nil))
            try await Task.sleep(for: .milliseconds(200))
            Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
            try await until("⌘→ on its details to move it") { order.stage(of: Self.ref)?.stage == .yourReview }

            details.hasPageOver = true
            try await Task.sleep(for: .milliseconds(200))
            Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
            Self.press(.leftArrow, command: true, in: window, throughTheApp: true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(order.stage(of: Self.ref)?.stage == .yourReview, "A key moved the card under a page over its details")

            details.hasPageOver = false
            try await Task.sleep(for: .milliseconds(200))
            Self.press(.leftArrow, command: true, in: window, throughTheApp: true)
            try await until("⌘← back on its details to move it") { order.stage(of: Self.ref)?.stage == .inProgress }
        }
    }

    /// Details shown without a click on its card, as Up Next shows them: while they cover the Board, the keys move its card
    /// all the same.
    @Test func whileTheyCoverTheBoardTheKeysMoveTheCardOfDetailsShownFromElsewhere() async throws {
        let order = Self.order()
        let details = Details(covers: true)
        try await Self.showing(order, details: details) { window, _, _ in
            details.shown = Self.ref
            try await Task.sleep(for: .milliseconds(300))
            Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
            try await until("⌘→ while they cover the Board") { order.stage(of: Self.ref)?.stage == .yourReview }
        }
    }

    /// Beside the Board, the details leave it the keys, which only a card that has the focus takes: shown from elsewhere,
    /// without a click on its card, ⌘→ moves nothing.
    @Test func whileTheDetailsAreBesideTheBoardOnlyAFocusedCardTakesTheKeys() async throws {
        let order = Self.order()
        let details = Details(covers: false)
        try await Self.showing(order, details: details) { window, _, _ in
            details.shown = Self.ref
            try await Task.sleep(for: .milliseconds(300))
            Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(order.stage(of: Self.ref)?.stage == .inProgress, "The Board took a key that no card had")
        }
    }

    /// The card you clicked has the focus back once its details close, though no key moved it while they covered the Board.
    @Test func aClickedCardHasTheFocusBackOnceItsDetailsCloseThoughNoKeyMovedIt() async throws {
        let order = Self.order()
        let details = Details(covers: true)
        try await Self.showing(order, details: details) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details over the Board") { details.shown == Self.ref }
            #expect(window.makeFirstResponder(nil))
            try await Task.sleep(for: .milliseconds(200))
            details.shown = nil
            try await Self.move(
                .rightArrow, to: .yourReview, "⌘→ to move the card that has the focus back", order: order, drawn: drawn,
                in: window
            )
        }
    }

    /// While the details cover the Board, its keys take ⌘ alone, whatever else an arrow carries, Caps Lock too: ⇧⌘→, ⌥⌘→ and
    /// ⌃⌘→ are other shortcuts. A key held down moves the card once: its repeats aren't more presses.
    @Test func whileTheyCoverTheBoardOnlyCommandAloneMovesTheCardAndAHeldKeyMovesItOnce() async throws {
        let order = Self.order()
        let details = Details(covers: true)
        try await Self.showing(order, details: details) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details over the Board") { details.shown == Self.ref }
            #expect(window.makeFirstResponder(nil))
            try await Task.sleep(for: .milliseconds(200))
            for other: NSEvent.ModifierFlags in [.shift, .option, .control] {
                Self.press(.rightArrow, command: true, also: other, in: window, throughTheApp: true)
            }
            Self.press(.rightArrow, command: true, isRepeat: true, in: window, throughTheApp: true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(order.stage(of: Self.ref)?.stage == .inProgress, "Another shortcut, or a repeat, moved the card")
            Self.press(.rightArrow, command: true, also: .capsLock, in: window, throughTheApp: true)
            try await until("⌘→ with Caps Lock on") { order.stage(of: Self.ref)?.stage == .yourReview }
            try await Task.sleep(for: .milliseconds(300))
            #expect(order.stage(of: Self.ref)?.stage == .yourReview, "One press moved it more than once")
        }
    }

    /// A card that has the keyboard's focus takes ⌘ alone, as the Board does while the details cover it: ⇧⌘→, ⌥⌘→ and ⌃⌘→ are
    /// other shortcuts, but Caps Lock doesn't matter.
    @Test func aFocusedCardTakesCommandAloneAsTheBoardDoesWhileTheDetailsCoverIt() async throws {
        let order = Self.order()
        try await Self.showing(order) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details") { drawn.shown == 1 }
            // ⇧⌘→, ⌥⌘→ and ⌃⌘→, then ⌘→ with Caps Lock on, with nothing between them: once that moves it, the card had
            // the keys for the others too.
            var movedByAnother = false
            try await Self.pressUntil("⌘→ with Caps Lock on") {
                for other: NSEvent.ModifierFlags in [.shift, .option, .control] {
                    Self.press(.rightArrow, command: true, also: other, in: window)
                }
                movedByAnother = order.stage(of: Self.ref)?.stage != .inProgress
                Self.press(.rightArrow, command: true, also: .capsLock, in: window)
                return order.stage(of: Self.ref)?.stage != .inProgress
            }
            #expect(!movedByAnother, "Another shortcut moved the card")
            #expect(order.stage(of: Self.ref)?.stage == .yourReview)
        }
    }

    /// A move the keys can't make while the details cover the Board: they beep, and say why, under its stage, as the
    /// Board does under the card's lane, which can't be seen then. No more once it's in another stage, or the Board
    /// shows again.
    @Test func aMoveRefusedWhileTheDetailsCoverTheBoardSaysWhyInThem() async throws {
        let order = Self.order()
        let details = Details(covers: true)
        try await Self.showing(order, details: details) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details over the Board") { details.shown == Self.ref }
            #expect(window.makeFirstResponder(nil))
            try await Task.sleep(for: .milliseconds(200))

            // Each key as the app takes it, once the card is drawn in its new column, a moment later, as you'd press
            // the next: the keys move it from where the Board last drew it.
            @MainActor func move(_ arrow: KeyEquivalent, to stage: PullRequestStage, _ what: String) async throws {
                let before = drawn.frame?.minX
                Self.press(arrow, command: true, in: window, throughTheApp: true)
                try await until(what) { order.stage(of: Self.ref)?.stage == stage && drawn.frame?.minX != before }
                try await Task.sleep(for: .milliseconds(200))
            }
            try await move(.rightArrow, to: .yourReview, "⌘→ to Your review")
            try await move(.rightArrow, to: .teammateReview, "⌘→ to Teammate's review")
            // Only Azure DevOps decides that it's approved. The key beeps, through ThisMac, which refuses it in tests.
            let notes = ThisMac.Notes()
            ThisMac.$noting.withValue(notes) {
                Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
            }
            #expect(notes.refused == ["beep"])
            try await until("the details to say why it can't move on") {
                order.stageRefusal(of: Self.ref) == Self.azureDevOpsDecides
            }
            #expect(order.stage(of: Self.ref)?.stage == .teammateReview)

            // Moved since, it's said no more.
            try await move(.leftArrow, to: .yourReview, "⌘← back to Your review")
            #expect(order.stageRefusal(of: Self.ref) == nil)
            #expect(order.stageRefusal == nil)
            try await move(.rightArrow, to: .teammateReview, "⌘→ to Teammate's review again")
            Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
            try await until("the details to say why again") { order.stageRefusal(of: Self.ref) == Self.azureDevOpsDecides }
            // Moved elsewhere, as from its stage's menu in the details, it's said no more there, even once it's back.
            #expect(order.setStage(.yourReview, of: Self.ref) == .done)
            #expect(order.stageRefusal(of: Self.ref) == nil)
            #expect(order.stageRefusal == nil, "The Board kept the details' line of one moved elsewhere")
            #expect(order.setStage(.teammateReview, of: Self.ref) == .done)
            #expect(order.stageRefusal(of: Self.ref) == nil, "Back in the stage it couldn't leave, it said so again")
            Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
            try await until("the details to say why once more") { order.stageRefusal(of: Self.ref) == Self.azureDevOpsDecides }

            // Once they close, the Board says it under the card's lane.
            details.shown = nil
            try await until("the details' line to go as the Board shows again") { order.stageRefusal == nil }
        }
    }

    /// While the Board shows, beside the details, a card that can't move says why itself, under its lane: the details
    /// aren't told.
    @Test func whileTheBoardShowsTheDetailsArentToldWhyACardCantMove() async throws {
        let order = Self.order()
        #expect(order.setStage(.teammateReview, of: Self.ref) == .done)
        let details = Details(covers: false)
        try await Self.showing(order, details: details) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details beside the Board") { details.shown == Self.ref }
            // ⌘→, which it can't take, as only Azure DevOps decides that it's approved, then ⌘←, which moves it, with
            // nothing between them: once ⌘← moves it, the card had the keys for ⌘→ too.
            var toldTheDetails = false
            try await Self.pressUntil("⌘← to move the card after ⌘→, which it couldn't take") {
                Self.press(.rightArrow, command: true, in: window)
                toldTheDetails = order.stageRefusal != nil
                Self.press(.leftArrow, command: true, in: window)
                return order.stage(of: Self.ref)?.stage == .yourReview
            }
            #expect(!toldTheDetails, "The details were told why, though the Board showed")
        }
    }

    /// Why a move was refused, under the card's lane, goes once its stage changes, from anywhere, as from its stage's menu in
    /// the details: the Board, back, doesn't say it.
    @Test func aLanesLineOfWhyACardCouldntMoveGoesOnceItsStageChangesElsewhere() async throws {
        let order = Self.order()
        let details = Details(covers: true)
        try await Self.showing(order, details: details) { window, host, drawn in
            Self.click(at: try #require(drawn.frame), in: host)
            try await until("the click to show its details over the Board") { details.shown == Self.ref }
            #expect(window.makeFirstResponder(nil))
            // Each key as the app takes it, again until it moves the card, then once the Board draws it in its new column.
            for stage in [PullRequestStage.yourReview, .teammateReview] {
                let before = drawn.frame?.minX
                try await Self.pressUntil("⌘→ to \(stage.title)") {
                    Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
                    return order.stage(of: Self.ref)?.stage == stage
                }
                try await until("the Board to draw it in \(stage.title)") { drawn.frame?.minX != before }
            }
            let withoutIt = host.fittingSize.height
            try await Self.pressUntil("the details to say why") {
                Self.press(.rightArrow, command: true, in: window, throughTheApp: true)
                return order.stageRefusal(of: Self.ref) == Self.azureDevOpsDecides
            }
            try await until("the lane to say why under it") { host.fittingSize.height > withoutIt + 8 }
            let withIt = host.fittingSize.height

            #expect(order.setStage(.yourReview, of: Self.ref) == .done)
            details.shown = nil
            try await until("the lane's line to go, though it showed when the Board did again") {
                host.fittingSize.height < withIt - 8
            }
        }
    }

    /// While the details cover the Board, ⌘← sets a pull request in two missions as next to merge where it waits: in the lane
    /// of the mission whose order holds it, though its details were shown from elsewhere, as from Up Next, and saying its
    /// Undo is beside it, in the details. Clicked in the other mission's lane, it says where it waits instead. Once they
    /// close, ⌘← on the card says its Undo is in its mission's lane.
    @Test func whileTheyCoverTheBoardCommandLeftSetsItAsNextWhereItWaits() async throws {
        let order = try Self.twoOrders([4100, 4101], [4101, 4105], ready: [4101])
        let ref = ItemRef.pullRequest(organization: "contoso", number: 4101)
        let holder = MissionKey.plan(Self.planID), other = MissionKey.plan(Self.otherID)
        #expect(order.stage(of: ref)?.stage == .waits)
        #expect(StageOrder.holders(of: ref, in: order.missions) == [holder])
        // The first lane that has it is the other mission's, which doesn't hold it.
        #expect(order.board(kinds: [.pullRequest]).lanes.first { $0.cards.contains { $0.ref == ref } }?.mission == other)
        let details = Details(covers: true)
        try await Self.showingWired(order, details: details) { window, host, wired in
            let waits = try #require(wired.frames[Self.key(ref, other)]?.minX)
            // Each key again until what it does is done: the Board's keys take it once it's drawn with the details over it.
            details.shown = ref
            try await Self.pressUntil("⌘← to set it as next where it waits") {
                Self.press(.leftArrow, command: true, in: window, throughTheApp: true)
                return order.stage(of: ref)?.stage == .canMerge
            }
            #expect(order.lastOrderChange?.mission == holder)
            #expect(wired.places == [.details])
            try await until("the Board to draw it in Can merge") { wired.frames[Self.key(ref, other)]?.minX != waits }
            _ = order.undo()
            #expect(order.stage(of: ref)?.stage == .waits)
            details.shown = nil
            try await until("the Board to draw it in Waits again") { wired.frames[Self.key(ref, other)]?.minX == waits }

            // A click, again until it shows its details: it takes it once the Board, which the details covered, is back.
            try await Self.pressUntil("the click in the other mission's lane") {
                Self.click(at: wired.frames[Self.key(ref, other)] ?? .zero, in: host)
                return details.shown == ref
            }
            #expect(window.makeFirstResponder(nil))
            try await Self.pressUntil("the details to say where it waits") {
                Self.press(.leftArrow, command: true, in: window, throughTheApp: true)
                return order.stageRefusal(of: ref) != nil
            }
            let mission = try #require(order.missions.first { $0.key == holder })
            let title = order.names.title(holder) ?? OrderText.title(of: mission, name: order.names.name)
            #expect(order.stageRefusal(of: ref) == "It waits in ‘\(title)’: set it as next there")
            #expect(order.lastOrderChange == nil && order.stage(of: ref)?.stage == .waits)
            details.shown = nil
            try await until("the Board back") { order.stageRefusal == nil }

            try await Self.pressUntil("the click in its mission's lane") {
                Self.click(at: wired.frames[Self.key(ref, holder)] ?? .zero, in: host)
                return details.shown == ref
            }
            #expect(window.makeFirstResponder(nil))
            try await Self.pressUntil("⌘← to set it as next there") {
                Self.press(.leftArrow, command: true, in: window, throughTheApp: true)
                return order.stage(of: ref)?.stage == .canMerge
            }
            #expect(order.lastOrderChange?.mission == holder)
            #expect(wired.places == [.details, .details])
            // The click's focus came after the card lost it, as the window isn't truly key: it loses it again, as the
            // disabled Board's card does in the app, and has it back once the details close.
            #expect(window.makeFirstResponder(nil))
            _ = order.undo()
            details.shown = nil

            // The card you clicked has the keys back: ⌘← on it, once it has them.
            try await Self.pressUntil("⌘← on the card to set it as next") {
                Self.press(.leftArrow, command: true, in: window)
                return order.stage(of: ref)?.stage == .canMerge
            }
            #expect(wired.places == [.details, .details, .byMission])
        }
    }

    /// With a lane for every card, a pull request in two missions has one card, that of the mission whose order holds it:
    /// while the details cover the Board, ⌘← sets it as next to merge there, with its Undo beside it, in the details.
    @Test func withALaneForEveryCardCommandLeftSetsItAsNextWhereItWaits() async throws {
        let order = try Self.twoOrders([4100, 4101], [4101, 4105], ready: [4101], lanes: BoardLanes.none)
        let ref = ItemRef.pullRequest(organization: "contoso", number: 4101)
        #expect(order.board(kinds: [.pullRequest]).mode == BoardLanes.none)
        let details = Details(covers: true)
        try await Self.showingWired(order, details: details) { window, _, wired in
            details.shown = ref
            try await Self.pressUntil("⌘← to set it as next where it waits") {
                Self.press(.leftArrow, command: true, in: window, throughTheApp: true)
                return order.stage(of: ref)?.stage == .canMerge
            }
            #expect(order.lastOrderChange?.mission == .plan(Self.planID))
            #expect(wired.places == [.details])
        }
    }

    /// Set as next to merge where each of two missions' orders holds it, a pull request still waits in the other: while the
    /// details cover the Board, they say where, as its lane does.
    @Test func setAsNextWhereBothOrdersHoldItTheDetailsSayWhereItStillWaits() async throws {
        let order = try Self.twoOrders([4100, 4101], [4102, 4101], ready: [4101])
        let ref = ItemRef.pullRequest(organization: "contoso", number: 4101)
        let holders = StageOrder.holders(of: ref, in: order.missions)
        #expect(Set(holders) == [.plan(Self.planID), .plan(Self.otherID)])
        let details = Details(covers: true)
        try await Self.showingWired(order, details: details) { window, _, _ in
            details.shown = ref
            try await Self.pressUntil("⌘← to set it as next where it waits first") {
                Self.press(.leftArrow, command: true, in: window, throughTheApp: true)
                return order.lastOrderChange?.mission == holders.first
            }
            #expect(order.stage(of: ref)?.stage == .waits)
            let still = try #require(BoardText.stillWaits(ref, besides: holders[0], in: order.missions, names: order.names))
            #expect(still.hasPrefix("It still waits for !") && still.hasSuffix(": its Mission ▸ Merge After there takes that away"))
            try await until("the details to say where it still waits") { order.stageRefusal(of: ref) == still }
            #expect(order.stageRefusal?.isRefusal == false)
            // ⌘← again doesn't set it as next in the other, where it would only wait in the first again: it says why.
            try await Self.pressUntil("⌘← again to say why it isn't set as next in the other") {
                Self.press(.leftArrow, command: true, in: window, throughTheApp: true)
                return order.stageRefusal(of: ref)?.hasPrefix("It's next to merge in ‘") == true
            }
            #expect(order.stageRefusal?.isRefusal == true && order.changes[ref]?.first == holders[0])
        }
    }

    /// Where two orders go round, the details say why ⌘← in the lane of the order its stage names didn't set it as next,
    /// as they cover the Board; and they still do as you rename that order, whose new name its stage's words say: its
    /// stage didn't change.
    @Test func whileTheyCoverTheBoardWhyItDidntMoveStaysAsTheOrderItsStageNamesIsRenamed() async throws {
        let order = try Self.twoOrders([4102, 4101], [4101, 4102], ready: [4101, 4102])
        let ref = ItemRef.pullRequest(organization: "contoso", number: 4101)
        let other = MissionKey.plan(Self.otherID)
        #expect(StageOrder.holders(of: ref, in: order.missions) == [.plan(Self.planID)])
        let details = Details(covers: true)
        try await Self.showingWired(order, details: details) { window, host, wired in
            try await Self.pressUntil("the click in the other mission's lane") {
                Self.click(at: wired.frames[Self.key(ref, other)] ?? .zero, in: host)
                return details.shown == ref
            }
            #expect(window.makeFirstResponder(nil))
            try await Self.pressUntil("the details to say where it waits") {
                Self.press(.leftArrow, command: true, in: window, throughTheApp: true)
                return order.stageRefusal(of: ref) != nil
            }
            let why = try #require(order.stageRefusal(of: ref))
            #expect(why.hasPrefix("It waits in ‘"))

            let mission = try #require(order.missions.first { $0.key == other })
            #expect(order.rename(mission, to: "Payments") == .named)
            #expect(order.stageRefusal(of: ref) == why)
            let words = StageWhy.orderHolds("‘Payments’ puts !4102 after it: check the order")
            try await until("the Board to draw its stage's new words") { wired.whys[Self.key(ref, other)] == words }
            #expect(order.stageRefusal(of: ref) == why)
        }
    }

    /// Where two orders go round, ⌘← in the lane of the order its stage names says why it didn't set it as next, under that
    /// lane's header, which moves its cards down; and it still does as you rename that order, whose new name its stage's
    /// words say: its stage didn't change.
    @Test func whyItDidntMoveStaysUnderItsLaneAsTheOrderItsStageNamesIsRenamed() async throws {
        let order = try Self.twoOrders([4102, 4101], [4101, 4102], ready: [4101, 4102])
        let ref = ItemRef.pullRequest(organization: "contoso", number: 4101)
        let other = MissionKey.plan(Self.otherID)
        let details = Details()
        try await Self.showingWired(order, details: details) { window, host, wired in
            let top = { () -> CGFloat? in
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return wired.tops[Self.key(ref, other)]
            }
            let before = try #require(top())
            try await Self.pressUntil("the click in the other mission's lane") {
                Self.click(at: wired.frames[Self.key(ref, other)] ?? .zero, in: host)
                return details.shown == ref
            }
            try await Self.pressUntil("⌘← to say under its lane where it waits") {
                Self.press(.leftArrow, command: true, in: window)
                return (top() ?? before) > before
            }
            let below = try #require(top())
            #expect(order.stage(of: ref)?.stage == .waits && order.lastOrderChange == nil)

            let mission = try #require(order.missions.first { $0.key == other })
            #expect(order.rename(mission, to: "Payments") == .named)
            let words = StageWhy.orderHolds("‘Payments’ puts !4102 after it: check the order")
            try await until("the Board to draw its stage's new words") { wired.whys[Self.key(ref, other)] == words }
            // Laid out again, a few times over: the line is still there.
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(50))
                #expect(top() == below)
            }
        }
    }

    // MARK: Two missions, with Set as Next to Merge

    private static let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private static let otherID = UUID(uuidString: "22222222-3333-4444-8555-666666666666")!

    /// What a Board wired as the page wires it drew and was told: each card's frame, by its lane's mission, and where each
    /// Set as Next to Merge said its Undo is.
    @MainActor
    private final class Wired {
        var frames: [String: CGRect] = [:]
        var places: [MissionMenuContext.UndoPlace] = []
        /// Why each card is in its stage, as the Board last drew it.
        var whys: [String: StageWhy] = [:]
        /// How far down the Board each card is: the window centers the Board, and sizes it anew as it changes.
        var tops: [String: CGFloat] = [:]
    }

    private static func key(_ ref: ItemRef, _ mission: MissionKey?) -> String {
        "\(ref.shortOrderLabel) in \(String(describing: mission))"
    }

    /// The Board as `Board` draws it, with Set as Next to Merge as the page wires it.
    private struct WiredBoard: View {
        @ObservedObject var order: PullRequestOrder
        @ObservedObject var details: Details
        let wired: Wired

        var body: some View {
            let kinds: Set<ItemRef.Kind> = [.pullRequest]
            let covered = details.covers && details.shown != nil
            OrderBoardView(
                board: order.board(kinds: kinds), missions: MissionsBody.missions(order.missions, kinds: kinds), order: order,
                elsewhere: "GitHub", openElsewhere: nil, place: { _ in nil },
                card: { [wired] card in
                    let label = "\(card.ref.shortOrderLabel) Totals"
                    let key = BoardKeyboardTests.key(card.ref, card.mission)
                    let content = Text(label)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { wired.frames[key] = $0 }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { wired.tops[key] = $0 }
                        .onChange(of: card.reading.why, initial: true) { _, why in wired.whys[key] = why }
                    return BoardCardContent(view: AnyView(content), menu: AnyView(EmptyView()), label: label)
                },
                isSelected: { [details] in details.shown == $0 },
                select: { [details] ref in details.shown = ref },
                shownOnTop: details.hasPageOver ? nil : details.shown,
                setAsNext: { [order, wired] ref, mission, undo in
                    wired.places.append(undo)
                    MissionMenuContext.setAsNext(ref, in: mission, order: order, undo: undo)
                },
                notOnBoard: 0, showByStatus: nil, now: Date(timeIntervalSince1970: 1_792_000_000)
            )
            .disabled(covered)
            .coordinateSpace(.named(Self.space))
        }

        /// The Board's own, for how far down it each card is.
        static let space = "WiredBoard"
    }

    /// Pull Request Order, on, with two sessions' orders of pull requests you opened, each one's in turn, these ready to
    /// complete.
    private static func twoOrders(_ first: [Int], _ other: [Int], ready: Set<Int>, lanes: BoardLanes = .missions) throws
        -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        lanes.save(to: defaults)
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders()
        for (index, (numbers, id)) in [(first, planID), (other, otherID)].enumerated() {
            let entries = numbers.enumerated().map { place, number in
                OrderRequest.Entry(link: link(number), after: place == 0 ? [] : ["\(numbers[place - 1])"])
            }
            try orders.apply(OrderRequest(entries: entries), now: Date(timeIntervalSince1970: 1_791_900_000 + Double(index)), newID: id)
        }
        orders.save(to: defaults)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        let numbers = Array(Set(first + other)).sorted()
        order.publish(
            .azureDevOps,
            pullRequests: numbers.map { number in
                OrderPullRequest(
                    ref: .pullRequest(organization: "contoso", number: number), repository: "contoso/7d3f9a12/shop-web",
                    sourceBranch: "robin/\(number)", targetBranch: "main", author: "robin",
                    createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
                )
            },
            stages: Dictionary(uniqueKeysWithValues: numbers.map { number in
                (ItemRef.pullRequest(organization: "contoso", number: number),
                 StageFacts(role: .author, isReady: ready.contains(number), votes: "0", commit: "c\(number)"))
            }),
            account: "robin@contoso.com"
        )
        return order
    }

    /// Shows the wired Board in a window while `body` runs, once its cards are drawn.
    private static func showingWired(
        _ order: PullRequestOrder, details: Details,
        _ body: @MainActor (_ window: NSWindow, _ host: NSView, _ wired: Wired) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let wired = Wired()
        let host = NSHostingView(rootView: WiredBoard(order: order, details: details, wired: wired))
        let window = KeyWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1_400, height: 700), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await until("the cards") { wired.frames.count >= 3 }
        try await body(window, host, wired)
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

    /// Keys on the card that has the keyboard's focus, pressed again until what they do is done: the card takes the
    /// focus a moment after a click, Tab, its move or its details closing, later on a busy machine, and a key before
    /// that goes to no card. A key that reaches the card does what it does as it's pressed, so none does it twice. Only for
    /// a short while from when the card can have the keys, as once it's drawn anew or its details close: a card that has
    /// them back late fails, as a key you press right away would go nowhere. That while is counted in presses, 50 ms
    /// apart and each in a turn of its own on the main actor, rather than on a clock: about two seconds on a Mac that isn't
    /// busy. Where every test shares the main actor, as on CI, a turn can come seconds after the last, and the card waits
    /// for its own turns as the presses do: on 2026-11-11, with the Mac 26 times slower than alone, every card had the
    /// keys by the third press, up to nine seconds on, while two seconds on a clock ran out on CI.
    private static func pressUntil(_ what: String, within limit: Int = 40, _ pressed: () -> Bool) async throws {
        var count = 1
        while !pressed() {
            guard count < limit else { throw TestError("Timed out waiting for \(what), after \(count) presses") }
            count += 1
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// ⌘ and an arrow on the card that has the keyboard's focus, until it moves the card to `stage`, then until the
    /// Board draws it there: the next key moves it from there. Until then, the card the Board drew before has the keys,
    /// and moves it from where it was.
    private static func move(
        _ arrow: KeyEquivalent, to stage: PullRequestStage, _ what: String, order: PullRequestOrder, drawn: Drawn,
        in window: NSWindow
    ) async throws {
        let before = drawn.frame?.minX
        try await pressUntil(what) {
            press(arrow, command: true, in: window)
            return order.stage(of: ref)?.stage == stage
        }
        try await until("the Board to draw the card where \(what) moved it") { drawn.frame?.minX != before }
    }

    /// A key, pressed and let go: an arrow or Return, with ⌘ and other modifiers, or held down, as its repeats come. To the
    /// window, as it gives them to its views; or through the app's own handling, as the window server's keys come, which has
    /// the app's key monitors look first.
    private static func press(
        _ key: KeyEquivalent, command: Bool = false, also others: NSEvent.ModifierFlags = [], isRepeat: Bool = false,
        in window: NSWindow, throughTheApp: Bool = false
    ) {
        let (code, character): (UInt16, Character) = switch key {
        case .rightArrow: (124, Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
        case .leftArrow: (123, Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))
        default: (36, "\r")
        }
        var flags: NSEvent.ModifierFlags = command ? [.command] : []
        flags.formUnion(others)
        if key == .rightArrow || key == .leftArrow { flags.formUnion([.numericPad, .function]) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character), isARepeat: type == .keyDown && isRepeat, keyCode: code
            ) else { continue }
            if throughTheApp {
                NSApp.sendEvent(event)
            } else {
                window.sendEvent(event)
            }
        }
    }
}
