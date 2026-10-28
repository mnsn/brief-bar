import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation
import Testing
@testable import AzureDevOpsUI

/// The work item whose details show beside the sprint: which one, going back and forth, and when it's read again. With the
/// made-up sprint, whose details are read at once.
@MainActor
@Suite struct WorkItemDetailsStoreTests {
    private struct NoTokens: AccessTokenProvider {
        struct Unused: Error {}
        func token() async throws -> AccessToken { throw Unused() }
        func invalidate() async {}
    }

    /// A clock the tests move.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_792_317_600)
    }

    private let clock = Clock()
    private let board: SprintBoard

    init() {
        board = DemoData.sprintBoard(now: clock.now)
    }

    private func makeStore() -> WorkItemDetailsStore {
        let clock = self.clock
        let store = WorkItemDetailsStore(
            mode: .demo, client: ADOClient(tokens: NoTokens()), board: Empty().eraseToAnyPublisher(), now: { clock.now }
        )
        store.boardChanged(board)
        store.setVisible(true, for: "window.test")
        return store
    }

    private func item(_ id: Int, in board: SprintBoard? = nil) throws -> WorkItem {
        try #require((board ?? self.board).item(WorkItemKey(DemoData.organization, id)))
    }

    @Test func showsWhatTheSprintKnowsThenItsDetails() throws {
        let store = makeStore()
        let task = try item(5103)
        store.show(task)
        #expect(store.selected == task)
        #expect(store.details?.item.id == 5103)
        #expect(store.details?.parent?.workItemId == 5101)
        #expect(store.details?.readAt == clock.now)
        #expect(!store.isLoading)
        #expect(store.failure == nil)
        #expect(store.history.isEmpty)
        // The team's own states, which the sprint knows, rather than ones guessed from their names.
        #expect(store.selected?.category == task.category)
    }

    @Test func followsLinksAndComesBack() throws {
        let store = makeStore()
        let story = try item(5101)
        let task = try item(5103)
        store.show(story)
        store.follow(task)
        #expect(store.selected?.id == 5103)
        #expect(store.history.map(\.id) == [5101])
        // The one that shows already: nothing to go back to.
        store.follow(task)
        #expect(store.history.map(\.id) == [5101])
        store.back()
        #expect(store.selected?.id == 5101)
        #expect(store.details?.item.id == 5101)
        #expect(store.history.isEmpty)
        // From the sprint, it starts over.
        store.follow(task)
        store.show(try item(5110))
        #expect(store.history.isEmpty)
        store.close()
        #expect(store.selected == nil && store.details == nil)
    }

    @Test func aLinkedWorkItemShowsAsTheSprintKnowsIt() throws {
        let store = makeStore()
        store.show(try item(5101))
        let link = WorkItem(
            id: 5103, organization: "CONTOSO", project: "Storefront", type: "Task", title: "Old title", state: "Active",
            category: .resolved
        )
        store.follow(link)
        let known = try item(5103)
        #expect(store.selected == known)
    }

    @Test func showsTheNewestOfWhatTheSprintKnowsAndWhatWasRead() throws {
        let sprint = try item(5103)
        let changed = try #require(sprint.changedAt)
        // Read when it hadn't changed: the sprint's, which knows its team's states.
        var same = sprint
        same.category = .resolved
        #expect(WorkItemDetailsStore.newest(sprint, same) == sprint)
        // Changed since, in the same state: what was read, with the sprint's category.
        var newer = sprint
        newer.title = "Show saved items under the cart, newest first"
        newer.category = .resolved
        newer.changedAt = changed + 60
        #expect(WorkItemDetailsStore.newest(sprint, newer)?.title == newer.title)
        #expect(WorkItemDetailsStore.newest(sprint, newer)?.category == sprint.category)
        // A linked work item that couldn't be read, then was.
        let unread = WorkItem(
            id: 9, organization: "contoso", project: "Storefront", type: "Work Item", title: "Work item 9", state: "", category: .proposed
        )
        var read = unread
        read.type = "Bug"
        read.title = "Coupon codes are case-sensitive"
        read.state = "Active"
        read.category = .inProgress
        read.changedAt = changed
        #expect(WorkItemDetailsStore.newest(unread, read) == read)
        #expect(WorkItemDetailsStore.newest(unread, nil) == unread)
        #expect(WorkItemDetailsStore.newest(nil, read) == read)
    }

    @Test func keepsWhatItReadForAWhile() throws {
        let store = makeStore()
        let story = try item(5101)
        let read = clock.now
        store.show(story)
        store.show(try item(5103))
        clock.now += 30
        store.show(story)
        #expect(store.details?.readAt == read)
        // A while later, it's read again when it shows.
        clock.now += 60
        store.show(try item(5103))
        store.show(story)
        #expect(store.details?.readAt == clock.now)
        clock.now += 90
        store.refreshIfStale()
        #expect(store.details?.readAt == clock.now)
        // Asked to, at once.
        clock.now += 1
        store.reload()
        #expect(store.details?.readAt == clock.now)
    }

    @Test func readsAgainWhenTheSprintShowsItChanged() throws {
        let store = makeStore()
        let first = clock.now
        store.show(try item(5103))
        // The sprint refreshes, with nothing new about it.
        clock.now += 10
        store.boardChanged(board)
        #expect(store.details?.readAt == first)
        // Someone changed it.
        var changed = board
        let row = try #require(changed.rows.firstIndex { $0.tasks.contains { $0.id == 5103 } })
        let index = try #require(changed.rows[row].tasks.firstIndex { $0.id == 5103 })
        changed.rows[row].tasks[index].state = "Closed"
        changed.rows[row].tasks[index].category = .completed
        changed.rows[row].tasks[index].changedAt = clock.now
        store.boardChanged(changed)
        #expect(store.details?.readAt == clock.now)
        #expect(store.selected?.state == "Closed")
        #expect(store.selected?.category == .completed)

        // While no window shows the details, once one does again.
        store.setVisible(false, for: "window.test")
        clock.now += 10
        changed.rows[row].tasks[index].changedAt = clock.now
        store.boardChanged(changed)
        let hidden = clock.now - 10
        #expect(store.details?.readAt == hidden)
        clock.now += 5
        store.setVisible(true, for: "window.test")
        #expect(store.details?.readAt == clock.now)
    }

    @Test func anotherTeamsSprintClosesTheDetails() throws {
        let store = makeStore()
        store.show(try item(5103))
        // The other team's sprint, while it loads.
        store.boardChanged(nil)
        #expect(store.selected != nil)
        var other = board
        other.team = DemoData.otherTeam
        store.boardChanged(other)
        #expect(store.selected == nil)
    }

    @Test func forgetsWhatItReadAQuarterOfAnHourLater() throws {
        let store = makeStore()
        store.show(try item(5101))
        store.show(try item(5103))
        #expect(store.keptWorkItems.map(\.id).sorted() == [5101, 5103])
        clock.now += WorkItemDetailsStore.keptFor - 1
        store.expire()
        #expect(store.keptWorkItems.count == 2)
        // On screen, what shows stays while it does; what was read before is forgotten.
        clock.now += 1
        store.expire()
        #expect(store.keptWorkItems.isEmpty)
        #expect(store.details?.item.id == 5103)
        // Off screen, it's forgotten too.
        store.setVisible(false, for: "window.test")
        store.expire()
        #expect(store.selected == nil && store.details == nil && store.history.isEmpty)
    }

    @Test func showsAnyNumber() {
        #expect(WorkItemDetailsPanel.number(5) == "5")
        #expect(WorkItemDetailsPanel.number(2.5) == "2.5")
        #expect(WorkItemDetailsPanel.number(1e19) == "10000000000000000000.0")
        #expect(Hours.text(3) == "3 h")
        #expect(Hours.text(1.5) == "1.5 h")
        #expect(Hours.text(-1e300).hasSuffix(" h"))
    }

    @Test func opensTheSprintPageFromAListOrAWidget() throws {
        let store = makeStore()
        var opened = 0
        store.hasPage = { true }
        store.openPage = { opened += 1 }
        store.reveal(try item(5110))
        #expect(store.selected?.id == 5110)
        #expect(opened == 1)
    }

    @Test func forgetsEverythingWhenStopped() throws {
        let store = makeStore()
        store.show(try item(5103))
        store.follow(try item(5101))
        store.stop()
        #expect(store.selected == nil && store.details == nil && store.history.isEmpty)
        #expect(!store.isLoading)
    }

    @Test func saysWhatWentWrong() {
        #expect(WorkItemDetailsStore.message(for: .notFound).contains("can't find"))
        #expect(WorkItemDetailsStore.message(for: .forbidden) == "You don't have access to this work item.")
        #expect(WorkItemDetailsStore.message(for: .http(500)) == ADOError.http(500).description)
    }
}
