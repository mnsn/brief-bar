import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Reads that wait for the test to answer them, as Azure DevOps answers later: what the store does meanwhile.
@MainActor
private final class ReadGate {
    private(set) var asked: [WorkItem] = []
    private var waiting: [CheckedContinuation<WorkItemDetailsStore.Read, Never>] = []

    var reader: WorkItemDetailsStore.Reader {
        { [self] item in await self.read(item) }
    }

    private func read(_ item: WorkItem) async -> WorkItemDetailsStore.Read {
        asked.append(item)
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Waits for the store to ask, then answers its oldest read.
    func answer(_ read: WorkItemDetailsStore.Read) async throws {
        try await until("a read") { !waiting.isEmpty }
        waiting.removeFirst().resume(returning: read)
    }
}

private struct Timeout: Error, CustomStringConvertible {
    let description: String
}

/// Lets the store's reads go on until `condition` holds.
@MainActor
private func until(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Timeout(description: "Timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// The work item whose details show beside the sprint: which one, going back and forth, and when it's read again. With the
/// made-up sprint, whose details are read at once, or with reads the tests answer.
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

    /// With the made-up sprint's details, or, with `reader`, live, with reads it answers.
    private func makeStore(reader: WorkItemDetailsStore.Reader? = nil) -> WorkItemDetailsStore {
        let clock = self.clock
        let store = WorkItemDetailsStore(
            mode: reader == nil ? .demo : .live, client: ADOClient(tokens: NoTokens()), board: Empty().eraseToAnyPublisher(),
            now: { clock.now }, reader: reader
        )
        store.boardChanged(board)
        store.setVisible(true, for: "window.test")
        return store
    }

    private func item(_ id: Int, in board: SprintBoard? = nil) throws -> WorkItem {
        try #require((board ?? self.board).item(WorkItemKey(DemoData.organization, id)))
    }

    /// The sprint, with a work item changed at `date`.
    private func board(changing id: Int, at date: Date) -> SprintBoard {
        var changed = board
        for row in changed.rows.indices {
            if changed.rows[row].parent?.id == id { changed.rows[row].parent?.changedAt = date }
            for task in changed.rows[row].tasks.indices where changed.rows[row].tasks[task].id == id {
                changed.rows[row].tasks[task].changedAt = date
            }
        }
        return changed
    }

    /// A work item's details, as read when it last changed at `changedAt`, by `account`.
    private func read(_ id: Int, changedAt: Date? = nil, account: String? = nil) throws -> WorkItemDetailsStore.Read {
        var read = try item(id)
        if let changedAt { read.changedAt = changedAt }
        return WorkItemDetailsStore.Read(result: .success(WorkItemDetails(item: read, readAt: clock.now)), account: account)
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
        #expect(store.history.map(\.item.id) == [5101])
        // The one that shows already: nothing to go back to.
        store.follow(task)
        #expect(store.history.map(\.item.id) == [5101])
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

    @Test func opensPagesOverTheDetailsAndGoesBackThroughThem() throws {
        let store = makeStore()
        let story = try item(5101)
        let pullRequest = ItemRef.pullRequest(organization: DemoData.organization, number: 4120)
        let session = try #require(ItemRef.session("c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11"))
        // Nothing shows to open it over.
        store.open(page: pullRequest)
        #expect(store.pages.isEmpty)
        store.show(story)
        #expect(!store.canGoBack)
        store.open(page: pullRequest)
        // The one that shows, once.
        store.open(page: pullRequest)
        store.open(page: session)
        #expect(store.pages == [pullRequest, session])
        #expect(store.canGoBack)
        // A work item is followed, not opened as a page.
        store.open(page: .workItem(organization: DemoData.organization, id: 5103))
        #expect(store.pages == [pullRequest, session])
        // One that shows under the one on top: back to it, rather than once more.
        store.open(page: pullRequest)
        #expect(store.pages == [pullRequest])
        store.open(page: session)
        store.back()
        #expect(store.pages == [pullRequest])
        #expect(store.selected?.id == 5101)
        store.back()
        #expect(store.pages.isEmpty)
        #expect(store.selected?.id == 5101)
        #expect(!store.canGoBack)

        // By its crumbs: to a page, or to the work item under them.
        store.open(page: pullRequest)
        store.open(page: session)
        store.back(toPage: 0)
        #expect(store.pages == [pullRequest])
        store.back(toPage: 3)
        #expect(store.pages == [pullRequest])
        store.back(toPage: nil)
        #expect(store.pages.isEmpty)

        // A work item followed from a page: back goes to the page it was followed from.
        store.open(page: pullRequest)
        store.follow(try item(5103))
        #expect(store.pages.isEmpty)
        #expect(store.history == [WorkItemDetailsStore.Visit(item: try #require(store.history.first?.item), pages: [pullRequest])])
        #expect(store.history.map(\.item.id) == [5101])
        store.back()
        #expect(store.selected?.id == 5101)
        #expect(store.pages == [pullRequest])
        // The work item that shows, from a page over it: back to it, with nothing to come back from.
        store.follow(story)
        #expect(store.pages.isEmpty)
        #expect(store.history.isEmpty)

        // Without Show Links, the pages go, those to go back to too.
        store.open(page: pullRequest)
        store.follow(try item(5103))
        store.open(page: session)
        store.closePages()
        #expect(store.pages.isEmpty)
        store.back()
        #expect(store.selected?.id == 5101)
        #expect(store.pages.isEmpty)

        // From the sprint, or closed, the pages go.
        store.open(page: session)
        store.show(try item(5110))
        #expect(store.pages.isEmpty)
        store.open(page: session)
        store.close()
        #expect(store.pages.isEmpty)
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

    @Test func readsAgainWhenTheSprintShowsAChangeWhileItsRead() async throws {
        let gate = ReadGate()
        let store = makeStore(reader: gate.reader)
        let task = try item(5103)
        let before = try #require(task.changedAt)
        store.show(task)
        try await until("the read") { gate.asked.count == 1 }
        // The sprint shows it changed, while it's read: what's read may be from before.
        store.boardChanged(board(changing: 5103, at: before + 60))
        #expect(store.selected?.changedAt == before + 60)
        #expect(store.isLoading && gate.asked.count == 1)
        try await gate.answer(read(5103, changedAt: before))
        // It shows, and it's read again rather than left under the newer title.
        try await until("the second read") { gate.asked.count == 2 }
        #expect(store.details?.item.changedAt == before)
        #expect(store.isLoading)
        try await gate.answer(read(5103, changedAt: before + 60))
        try await until("the second read to show") { !store.isLoading }
        #expect(store.details?.item.changedAt == before + 60)
        #expect(gate.asked.count == 2)
    }

    @Test func aReadThatHasTheChangeIsntReadAgain() async throws {
        let gate = ReadGate()
        let store = makeStore(reader: gate.reader)
        let task = try item(5103)
        let before = try #require(task.changedAt)
        store.show(task)
        store.boardChanged(board(changing: 5103, at: before + 60))
        try await gate.answer(read(5103, changedAt: before + 60))
        try await until("the read") { !store.isLoading }
        // Nor one the sprint didn't show changing.
        store.show(try item(5101))
        try await gate.answer(read(5101))
        try await until("the story's read") { !store.isLoading }
        #expect(store.details?.item.id == 5101)
        #expect(gate.asked.map(\.id) == [5103, 5101])
    }

    @Test func aWorkItemThatCouldntBeReadIsReadAgainWhenItChanges() async throws {
        let gate = ReadGate()
        let store = makeStore(reader: gate.reader)
        let task = try item(5103)
        let before = try #require(task.changedAt)
        store.show(task)
        try await gate.answer(WorkItemDetailsStore.Read(result: .failure(.http(500)), account: nil))
        try await until("the failure") { store.failure != nil }
        #expect(store.details == nil)
        // The sprint refreshes without a change to it: nothing more.
        store.boardChanged(board)
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.count == 1)
        // It changed: read again.
        store.boardChanged(board(changing: 5103, at: before + 60))
        try await until("the second read") { gate.asked.count == 2 }
        try await gate.answer(read(5103, changedAt: before + 60))
        try await until("the details") { store.details != nil }
        #expect(store.failure == nil)
    }

    @Test func aReadThatFailsWhileTheWorkItemChangesIsTriedAgain() async throws {
        let gate = ReadGate()
        let store = makeStore(reader: gate.reader)
        let task = try item(5103)
        let before = try #require(task.changedAt)
        store.show(task)
        try await until("the read") { gate.asked.count == 1 }
        store.boardChanged(board(changing: 5103, at: before + 60))
        try await gate.answer(WorkItemDetailsStore.Read(result: .failure(.http(500)), account: nil))
        try await until("the second read") { gate.asked.count == 2 }
        try await gate.answer(read(5103, changedAt: before + 60))
        try await until("the details") { store.details != nil }
        #expect(store.failure == nil)
        #expect(gate.asked.count == 2)
    }

    @Test func aNewerCopyOfAWorkItemIsReadAgain() throws {
        let store = makeStore()
        let task = try item(5103)
        let first = clock.now
        store.show(task)
        clock.now += 30
        store.show(try item(5101))
        store.show(task)
        #expect(store.details?.readAt == first)
        // Within a minute, it shows as kept, unless what comes with it, such as a link read with other details, says it
        // changed since.
        var newer = task
        newer.changedAt = (task.changedAt ?? first) + 60
        store.show(try item(5101))
        store.follow(newer)
        #expect(store.details?.readAt == clock.now)
    }

    @Test func aLinkShowsTheNewestOfWhatTheSprintKnowsAndWhatWasRead() throws {
        let store = makeStore()
        store.show(try item(5101))
        let task = try item(5103)
        let changed = try #require(task.changedAt)
        // Done since the sprint last refreshed.
        var done = task
        done.state = "Closed"
        done.category = .completed
        done.changedAt = changed + 60
        #expect(store.linked(WorkItemDetails.Link(kind: .child, name: "Child", workItemId: 5103, item: done)) == done)
        var older = done
        older.changedAt = changed - 60
        #expect(store.linked(WorkItemDetails.Link(kind: .child, name: "Child", workItemId: 5103, item: older)) == task)
        // Not in the sprint: as read, or nothing when it couldn't be.
        let elsewhere = WorkItem(
            id: 9, organization: "contoso", project: "Storefront", type: "Bug", title: "Coupon codes are case-sensitive",
            state: "Active", category: .inProgress, changedAt: changed
        )
        #expect(store.linked(WorkItemDetails.Link(kind: .other, name: "Related", workItemId: 9, item: elsewhere)) == elsewhere)
        #expect(store.linked(WorkItemDetails.Link(kind: .other, name: "Related", workItemId: 9)) == nil)
    }

    @Test func forgetsTheDetailsWhenSomeoneElseSignsIn() async throws {
        let gate = ReadGate()
        let store = makeStore(reader: gate.reader)
        store.show(try item(5103))
        try await gate.answer(read(5103, account: "tenant/robin"))
        try await until("the task's details") { store.details?.item.id == 5103 }
        store.show(try item(5101))
        try await gate.answer(read(5101, account: "tenant/robin"))
        try await until("the story's details") { store.details?.item.id == 5101 }
        store.follow(try item(5103))
        #expect(store.keptWorkItems.count == 2)
        #expect(store.history.map(\.item.id) == [5101])

        // The same account, or none the refresh can tell: nothing changes.
        store.accountChanged("tenant/robin")
        store.accountChanged(nil)
        #expect(store.selected?.id == 5103 && store.details?.item.id == 5103)

        // Someone else: what was read as Robin goes, and so do the details on screen.
        store.accountChanged("tenant/sam")
        #expect(store.selected == nil && store.details == nil && store.history.isEmpty)
        #expect(store.keptWorkItems.isEmpty)
        #expect(gate.asked.count == 2)

        // A read that ends as yet another account starts over too, without what it read.
        store.show(try item(5110))
        try await gate.answer(read(5110, account: "tenant/priya"))
        try await until("the bug's read") { !store.isLoading }
        #expect(store.selected == nil && store.details == nil && store.keptWorkItems.isEmpty)

        // A read under way when someone else signs in stops, and what it brings is left out.
        store.show(try item(5112))
        #expect(store.isLoading)
        store.accountChanged("tenant/alex")
        #expect(!store.isLoading && store.selected == nil)
        try await gate.answer(read(5112, account: "tenant/alex"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.selected == nil && store.details == nil && store.keptWorkItems.isEmpty)
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

    @Test func theDetailsCoverTheBoardOnlyInANarrowWindow() {
        let wide = SprintPage.DetailsLayout(width: 1_000, showsDetails: true)
        #expect(wide.isBeside && !wide.coversBoard && wide.panelWidth == 400)
        // Where the board is out of sight, it's out of reach of VoiceOver and the keyboard.
        let narrow = SprintPage.DetailsLayout(width: 560, showsDetails: true)
        #expect(!narrow.isBeside && narrow.coversBoard)
        #expect(!SprintPage.DetailsLayout(width: 560, showsDetails: false).coversBoard)
        #expect(SprintPage.DetailsLayout(width: SprintPage.DetailsLayout.besideWidth, showsDetails: true).isBeside)
        #expect(SprintPage.DetailsLayout(width: 2_000, showsDetails: true).panelWidth == 480)
        #expect(SprintPage.DetailsLayout(width: 700, showsDetails: true).panelWidth == 330)
    }

    @Test func saysWhatWentWrong() {
        #expect(WorkItemDetailsStore.message(for: .notFound).contains("can't find"))
        #expect(WorkItemDetailsStore.message(for: .forbidden) == "You don't have access to this work item.")
        #expect(WorkItemDetailsStore.message(for: .http(500)) == ADOError.http(500).description)
    }
}
