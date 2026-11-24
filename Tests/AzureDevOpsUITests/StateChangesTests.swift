import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// A work item's state on the Sprint page, with Make Changes in Azure DevOps on: the states it can be put in, those of its
/// type on the sprint's board; what goes to Azure DevOps, only while it's on and as you choose; how it shows at once; Undo;
/// and what the line under the page's header says when it didn't change. With the demo's made-up sprint, as a sprint that
/// reads Azure DevOps would have it, and a stand-in for Azure DevOps that answers as it does.
@MainActor
@Suite struct StateChangesTests {
    /// What the stand-in for Azure DevOps was sent, and answers.
    @MainActor
    final class AzureDevOps {
        var sent: [ADOWrite] = []
        var fails: ADOError?
        /// Whom the Azure CLI is signed in as: as the client does, a change asked for as someone else goes nowhere.
        var signedIn: String?

        /// As the client does: nothing goes as someone else, nor once `wanted` no longer wants it, as it's about to go.
        func send(
            _ write: ADOWrite, as account: String? = nil, while wanted: (@Sendable () async -> Bool)? = nil
        ) async throws -> ADOWrite.Answer {
            if let signedIn, let account, account != signedIn { throw ADOError.otherAccount }
            if let wanted, !(await wanted()) { throw CancellationError() }
            sent.append(write)
            if let fails { throw fails }
            guard case .setState(let key, _, let state) = write else { throw ADOError.http(400) }
            return .workItem(try ADOJSON.decoder().decode(ADOWorkItem.self, from: JSONSerialization.data(withJSONObject: [
                "id": key.id, "rev": 2,
                "fields": ["System.Id": key.id, "System.State": state, "System.ChangedDate": "2030-01-01T10:00:00Z"],
            ] as [String: Any])))
        }
    }

    nonisolated static let referenceNow = Date()

    /// Task 5104, "Move a saved item back to the cart", New, under User Story 5101.
    private let key = WorkItemKey(DemoData.organization, 5104)

    /// A sprint that reads Azure DevOps, with the demo's Sprint 42 read, and what changes its work items' states.
    private func live(makesChanges: Bool = true) -> (sprint: SprintStore, states: StateChanges, azure: AzureDevOps) {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = makesChanges
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
        let sprint = SprintStore(settings: settings, mode: .live, client: store.client)
        sprint.receive(SprintSnapshot(board: DemoData.sprintBoard(now: Self.referenceNow), hasLoaded: true))
        let states = StateChanges(sprint: sprint, settings: settings, client: store.client)
        let azure = AzureDevOps()
        states.send = { write, account, wanted in try await azure.send(write, as: account, while: wanted) }
        return (sprint, states, azure)
    }

    /// The sprint read again as it is, as someone signed in to the Azure CLI.
    private func read(_ sprint: SprintStore, as account: String) {
        sprint.receive(SprintSnapshot(board: sprint.board, hasLoaded: true, account: account))
    }

    private func item(_ sprint: SprintStore, _ id: Int = 5104) throws -> WorkItem {
        try #require(sprint.board?.item(WorkItemKey(DemoData.organization, id)))
    }

    /// The sprint read again with a work item in another state, as someone else changed it.
    private func readAgain(_ sprint: SprintStore, _ id: Int = 5104, in state: String) throws {
        var board = try #require(sprint.board)
        board.rows = board.rows.map { row in
            var row = row
            row.tasks = row.tasks.map { task in
                guard task.id == id else { return task }
                var changed = task
                changed.state = state
                changed.category = WorkItem.Category(category: board.categories(of: task.type)?[state], state: state)
                return changed
            }
            return row
        }
        sprint.receive(SprintSnapshot(board: board, hasLoaded: true, account: sprint.account))
    }

    // MARK: What it offers

    /// Off, nothing's offered or sent, and its state's tooltip says how to turn it on; on, its type's states, in its
    /// process's order.
    @Test func nothingChangesWhileItsOff() async throws {
        let (sprint, states, azure) = live(makesChanges: false)
        let task = try item(sprint)
        #expect(states.choices(for: task).isEmpty)
        #expect(!states.canChange(task))
        #expect(states.needsSetting(task))
        #expect(StateChangeText.help(task, canChange: false, needsSetting: true)
            == "State: New. Turn on Make Changes in Azure DevOps, in Settings › Pull Requests, to change it here.")
        await states.change(task, to: "Active")
        #expect(azure.sent.isEmpty)
        #expect(states.line == nil)
        #expect(try item(sprint).state == "New")

        states.settings.makesChanges = true
        #expect(states.choices(for: task).map(\.name) == ["New", "Active", "Closed"])
        #expect(!states.needsSetting(task))
        #expect(StateChangeText.help(task, canChange: true, needsSetting: false) == "State: New. Click to change it")
    }

    /// Each work item on the sprint's board, task, story or bug, offers its type's states; one BriefBar doesn't read, as your
    /// work outside the sprint before it's read, or whose type's states the team's configuration doesn't say, none, and
    /// nothing says how to turn anything on for it.
    @Test func offersTheStatesOfItsTypeForWhatsOnTheBoard() throws {
        let (sprint, states, _) = live()
        #expect(states.choices(for: try item(sprint, 5101)).map(\.name) == ["New", "Active", "Resolved", "Closed"])
        #expect(states.choices(for: try item(sprint, 5110)).map(\.name) == ["New", "Active", "Resolved", "Closed"])
        let outside = try #require(DemoData.outsideWork(now: Self.referenceNow).items.first { $0.id == 5052 })
        #expect(states.choices(for: outside).isEmpty)

        var unmapped = try #require(sprint.board)
        unmapped.stateCategories = [:]
        sprint.receive(SprintSnapshot(board: unmapped, hasLoaded: true))
        #expect(states.choices(for: try item(sprint)).isEmpty)
        states.settings.makesChanges = false
        #expect(!states.needsSetting(try item(sprint)))
    }

    /// VoiceOver's actions on a work item's card offer each state it can go to but its own, and none while a change is on its
    /// way, which they couldn't make, as its menus' are dimmed then.
    @Test func voiceOversActionsOfferNoStateWhileAChangeIsOnItsWay() throws {
        let (sprint, states, _) = live()
        let task = try item(sprint)
        #expect(states.actionChoices(for: task).map(\.name) == ["Active", "Closed"])
        let other = StateChanges.Change(key: WorkItemKey(DemoData.organization, 5105), name: "Task 5105", title: "", from: "New", to: "Active")
        states.showForRendering(.sending(other))
        #expect(states.actionChoices(for: task).isEmpty)
        states.showForRendering(.failed(other, .offline))
        #expect(states.actionChoices(for: task).map(\.name) == ["Active", "Closed"])
    }

    /// On My Work's Board, a work item on the sprint's board changes state as its card moves, whatever the setting: from the
    /// state it's in to the first of each kind its type has, held, saying why, while the setting's off or a change is on its
    /// way. One BriefBar doesn't read, or whose type's states the team's configuration doesn't say, doesn't. Moving a card
    /// sends the change as choosing it does.
    @Test func myWorksBoardMovesTheSprintsWorkToTheStatesItsTypeHas() async throws {
        let (sprint, states, azure) = live(makesChanges: false)
        let task: [SprintWork.Progress: String] = [.toDo: "New", .inProgress: "Active", .completed: "Closed"]
        #expect(states.boardStates(for: try item(sprint)) == .changes(current: "New", first: task, held: StateChangeText.turnOnToMove))
        #expect(StateChangeText.turnOnToMove
            == "Turn on Make Changes in Azure DevOps, in Settings › Pull Requests, to set its state by moving its card")

        states.settings.makesChanges = true
        let bug = try item(sprint, 5110)
        #expect(states.boardStates(for: bug) == .changes(
            current: bug.state, first: [.toDo: "New", .inProgress: "Active", .resolved: "Resolved", .completed: "Closed"], held: nil
        ))
        let outside = try #require(DemoData.outsideWork(now: Self.referenceNow).items.first { $0.id == 5052 })
        #expect(states.boardStates(for: outside) == nil)

        let change = StateChanges.Change(key: key, name: "Task 5104", title: "", from: "New", to: "Active")
        states.showForRendering(.sending(change))
        #expect(states.boardStates(for: try item(sprint)) == .changes(
            current: "New", first: task, held: "Task 5104 is changing to Active: one state changes at a time"
        ))
        states.showForRendering(nil)
        // It says once it's in that state, as the Board waits to know.
        #expect(await states.change(try item(sprint), to: "Active"))
        #expect(azure.sent == [.setState(key, from: "New", to: "Active")])
        #expect(states.boardStates(for: try item(sprint)) == .changes(current: "Active", first: task, held: nil))

        var unmapped = try #require(sprint.board)
        unmapped.stateCategories = [:]
        sprint.receive(SprintSnapshot(board: unmapped, hasLoaded: true))
        #expect(states.boardStates(for: try item(sprint)) == nil)
    }

    // MARK: Changing

    /// A change goes once, from the state BriefBar reads it in, and shows at once as Azure DevOps answered; Undo puts it
    /// back, without asking, and is then done with. The state it's in already sends nothing.
    @Test func aChangeGoesOnceAndUndoPutsItBack() async throws {
        let (sprint, states, azure) = live()
        await states.change(try item(sprint), to: "New")
        #expect(azure.sent.isEmpty)

        await states.change(try item(sprint), to: "Active")
        #expect(azure.sent == [.setState(key, from: "New", to: "Active")])
        let change = StateChanges.Change(
            key: key, name: "Task 5104", title: "Move a saved item back to the cart", from: "New", to: "Active"
        )
        #expect(states.line == .changed(change))
        #expect(StateChangeText.changed(change) == "Changed Task 5104 from New to Active.")
        let shown = try item(sprint)
        #expect(shown.state == "Active" && shown.category == .inProgress)
        #expect(shown.changedAt == ISO8601DateFormatter().date(from: "2030-01-01T10:00:00Z"))
        #expect(states.undoable == change)
        #expect(StateChangeText.undo(change) == "Undo: Change Back to New")

        await states.undo()
        #expect(azure.sent == [.setState(key, from: "New", to: "Active"), .setState(key, from: "Active", to: "New")])
        #expect(states.line == .changed(change.back))
        #expect(StateChangeText.changed(change.back) == "Changed Task 5104 back to New.")
        #expect(try item(sprint).state == "New")
        #expect(states.undoable == nil)
        await states.undo()
        #expect(azure.sent.count == 2)
        states.dismiss()
        #expect(states.line == nil)
    }

    /// A change that didn't happen says why, and leaves the work item as it was read; Try Again sends it again where it may
    /// help: not once Azure DevOps refused it, as when someone changed it meanwhile, or its process doesn't allow it.
    @Test func aChangeThatFailsSaysWhyAndCanBeTriedAgain() async throws {
        let (sprint, states, azure) = live()
        azure.fails = .offline
        #expect(await !states.change(try item(sprint), to: "Closed"))
        let change = StateChanges.Change(
            key: key, name: "Task 5104", title: "Move a saved item back to the cart", from: "New", to: "Closed"
        )
        #expect(states.line == .failed(change, .offline))
        #expect(StateChangeText.failed(change) == "Couldn't change Task 5104 to Closed.")
        #expect(try item(sprint).state == "New")
        #expect(states.undoable == nil)

        azure.fails = nil
        await states.retry()
        #expect(azure.sent.count == 2)
        #expect(states.line == .changed(change))
        #expect(try item(sprint).isDone)

        let refusal = "TF401320: Rule Error for field State. Error code: InvalidListValue."
        azure.fails = .refused(nil, message: refusal)
        await states.change(try item(sprint, 5105), to: "Active")
        let refused = StateChanges.Change(
            key: WorkItemKey(DemoData.organization, 5105), name: "Task 5105", title: "Test saving with an empty cart", from: "New",
            to: "Active"
        )
        #expect(states.line == .failed(refused, .refused(refusal)))
        #expect(!StateChanges.retries(.refused(refusal)))
        azure.fails = nil
        await states.retry()
        #expect(azure.sent.count == 3)
        #expect(states.line == .failed(refused, .refused(refusal)))
    }

    /// A change goes as whom BriefBar read the sprint as when you chose it, and only from the state it was in then, as
    /// BriefBar reads it as it goes: not once a read found it in another, nor once it's gone from the board; and not again
    /// once it's in the state it goes to. Signed in as someone else since, nothing goes as them, and what was going on goes.
    @Test func aChangeGoesAsWhomItWasReadAsFromTheStateItWasIn() async throws {
        let (sprint, states, azure) = live()
        azure.signedIn = "robin@contoso.example"
        read(sprint, as: "robin@contoso.example")
        var token: CheckedContinuation<Void, Never>?
        states.send = { write, account, wanted in
            await withCheckedContinuation { token = $0 }
            return try await azure.send(write, as: account, while: wanted)
        }
        let task = try item(sprint)
        let changing = Task { await states.change(task, to: "Active") }
        try await waitUntil { token != nil }
        // Read again while the token came: someone set it to Closed.
        try readAgain(sprint, in: "Closed")
        token?.resume()
        #expect(await !changing.value)
        #expect(azure.sent.isEmpty)
        let change = StateChanges.Change(
            key: key, name: "Task 5104", title: task.title, from: "New", to: "Active", account: "robin@contoso.example"
        )
        #expect(states.line == .failed(change, .notListed))
        #expect(ADOWriteProblem.notListed.sentence(.setState) == "As BriefBar reads it now, it isn't in the state it was in when "
            + "you chose another, or BriefBar doesn't read it anymore, so its state didn't change.")
        #expect(try item(sprint).state == "Closed")

        // From Closed, it goes, as whom it was read as, and once only.
        states.send = { write, account, wanted in try await azure.send(write, as: account, while: wanted) }
        await states.change(try item(sprint), to: "Active")
        #expect(azure.sent == [.setState(key, from: "Closed", to: "Active")])
        await states.change(try item(sprint), to: "Active")
        #expect(azure.sent.count == 1)

        // Someone else signed in since the sprint was read: nothing goes as them.
        azure.signedIn = "sam@contoso.example"
        await states.change(try item(sprint, 5105), to: "Active")
        #expect(azure.sent.count == 1)
        #expect(states.line == .failed(
            StateChanges.Change(key: WorkItemKey(DemoData.organization, 5105), name: "Task 5105", title: "Test saving with an empty cart",
                                from: "New", to: "Active", account: "robin@contoso.example"),
            .otherAccount
        ))
        // Read as them, what was going on goes.
        read(sprint, as: "sam@contoso.example")
        #expect(states.line == nil)
        #expect(states.undoable == nil)
    }

    /// A change is called off as it waits for its token once a read finds its work item in the state it goes to, as someone
    /// else put it there: nothing goes, and the line says nothing, but it says the work item is in that state, as BriefBar
    /// reads it, for My Work's Board, where its card goes there.
    @Test func aChangeCalledOffAsAReadFindsItWhereItGoesSaysItsThere() async throws {
        let (sprint, states, azure) = live()
        var token: CheckedContinuation<Void, Never>?
        states.send = { write, account, wanted in
            await withCheckedContinuation { token = $0 }
            return try await azure.send(write, as: account, while: wanted)
        }
        let task = try item(sprint)
        let changing = Task { await states.change(task, to: "Active") }
        try await waitUntil { token != nil }
        try readAgain(sprint, in: "Active")
        token?.resume()
        #expect(await changing.value)
        #expect(azure.sent.isEmpty)
        #expect(states.line == nil)
        #expect(try item(sprint).state == "Active")
    }

    /// A change asked for of the work item as you chose it, which a read found since in the state it goes to, as someone else
    /// put it there before the change began: nothing goes, and the line says nothing, but it says the work item is in that
    /// state, for My Work's Board, where its card goes there.
    @Test func aChangeToTheStateAReadFoundItInSinceYouChoseItSaysItsThere() async throws {
        let (sprint, states, azure) = live()
        let task = try item(sprint)
        try readAgain(sprint, in: "Active")
        #expect(await states.change(task, to: "Active"))
        #expect(azure.sent.isEmpty)
        #expect(states.line == nil)
        #expect(try item(sprint).state == "Active")
    }

    /// Turned off as a change waits for its token, it never goes, and leaves nothing on its way; and turned off after one
    /// went, Undo goes with the line.
    @Test func turningItOffCallsOffWhatHasntGoneAndForgetsUndo() async throws {
        let (sprint, states, azure) = live()
        states.send = { write, account, wanted in
            // Waits, as for a token, until it's called off: longer than a test can wait, on however busy a machine.
            try await Task.sleep(for: .seconds(600))
            return try await azure.send(write, as: account, while: wanted)
        }
        let task = try item(sprint)
        let changing = Task { await states.change(task, to: "Active") }
        try await waitUntil { states.isBusy }
        states.settings.makesChanges = false
        #expect(await !changing.value)
        #expect(azure.sent.isEmpty)
        #expect(states.line == nil)
        #expect(!states.isBusy)
        #expect(try item(sprint).state == "New")

        states.settings.makesChanges = true
        states.send = { write, account, wanted in try await azure.send(write, as: account, while: wanted) }
        await states.change(try item(sprint), to: "Active")
        #expect(states.undoable != nil)
        states.settings.makesChanges = false
        #expect(states.undoable == nil)
        #expect(states.line == nil)
        #expect(states.choices(for: try item(sprint)).isEmpty)
    }

    /// Undo is for the change you just made, while the work item is in the state it went to: not once it's in another, as
    /// someone else changed it.
    @Test func undoGoesOnceItsNoLongerInTheStateItWentTo() async throws {
        let (sprint, states, _) = live()
        await states.change(try item(sprint), to: "Active")
        #expect(states.undoable != nil)
        try readAgain(sprint, in: "Closed")
        #expect(states.undoable == nil)
        // A story's, changed the same way.
        await states.change(try item(sprint, 5101), to: "Resolved")
        let story = try item(sprint, 5101)
        #expect(story.state == "Resolved" && story.category == .resolved)
        #expect(states.undoable?.name == "User Story 5101")
    }

    /// The demo changes only its made-up sprint, and sends nothing.
    @Test func theDemoChangesOnlyItsMadeUpSprint() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = true
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .demo)
        let sprint = SprintStore(settings: settings, mode: .demo, client: store.client)
        await sprint.loadOnce()
        let states = StateChanges(sprint: sprint, settings: settings, client: store.client)
        let azure = AzureDevOps()
        states.send = { write, account, wanted in try await azure.send(write, as: account, while: wanted) }
        await states.change(try item(sprint), to: "Closed")
        #expect(azure.sent.isEmpty)
        #expect(try item(sprint).isDone)
        #expect(states.undoable?.to == "Closed")
    }

    // MARK: Off the sprint's board

    /// The sprint read again with your work outside it, as My Work reads it.
    private func readOutside(_ sprint: SprintStore, _ outside: OutsideWork = DemoData.outsideWork(now: referenceNow)) {
        sprint.receive(SprintSnapshot(board: sprint.board, hasLoaded: true, outside: outside, account: sprint.account))
    }

    /// Someone else's task, in the team's project, as Show Links read it for My Work's Map.
    private func samsTask(_ sprint: SprintStore) throws -> WorkItem {
        WorkItem(
            id: 9_001, organization: DemoData.organization, project: try #require(sprint.board).team.projectName, type: "Task",
            title: "Check the coupon totals", state: "Active", category: .inProgress
        )
    }

    /// A work item off the sprint's board offers its type's states too, as the team's configuration maps them, once BriefBar
    /// reads it in the team's project: one of yours outside the sprint, which My Work's Board moves as it does the sprint's,
    /// and one Show Links read, as someone else's that My Work's Map shows; not before, nor one in another project, whose
    /// process may give its type other states.
    @Test func offersTheStatesOfWorkOffTheBoardInTheTeamsProject() throws {
        let (sprint, states, _) = live(makesChanges: false)
        let outside = try #require(DemoData.outsideWork(now: Self.referenceNow).items.first { $0.id == 5052 })
        #expect(!states.needsSetting(outside))
        readOutside(sprint)
        #expect(states.needsSetting(outside))
        states.settings.makesChanges = true
        #expect(states.choices(for: outside).map(\.name) == ["New", "Active", "Closed"])
        #expect(states.boardStates(for: outside) == .changes(
            current: "New", first: [.toDo: "New", .inProgress: "Active", .completed: "Closed"], held: nil
        ))

        let task = try samsTask(sprint)
        #expect(states.choices(for: task).isEmpty)
        var read = task
        states.linked = { $0 == read.key ? read : nil }
        #expect(states.choices(for: task).map(\.name) == ["New", "Active", "Closed"])
        #expect(states.actionChoices(for: task).map(\.name) == ["New", "Closed"])
        read.project = "Payments"
        #expect(states.choices(for: task).isEmpty)
    }

    /// A change of one of your work items outside the sprint goes as one of the sprint's does, from the state BriefBar reads
    /// it in, shows at once among them, as Azure DevOps answered, and tells what else shows it. Once a read leaves it out, as
    /// one that's done, Undo still puts it back, from the state it went to.
    @Test func aChangeOfYourWorkOutsideTheSprintShowsAmongItAndUndoPutsItBack() async throws {
        let (sprint, states, azure) = live()
        readOutside(sprint)
        var told: [(key: WorkItemKey, item: WorkItem?)] = []
        states.elsewhere = { key, item in told.append((key, item)) }
        let key = WorkItemKey(DemoData.organization, 5052)
        let task = try #require(sprint.outside?.items.first { $0.key == key })
        #expect(await states.change(task, to: "Closed"))
        #expect(azure.sent == [.setState(key, from: "New", to: "Closed")])
        let shown = try #require(sprint.outside?.items.first { $0.key == key })
        #expect(shown.state == "Closed" && shown.isDone)
        #expect(told.map(\.key) == [key] && told.first?.item?.state == "Closed")
        let change = StateChanges.Change(key: key, name: "Task 5052", title: task.title, from: "New", to: "Closed")
        #expect(states.line == .changed(change))
        #expect(states.undoable == change)

        var read = try #require(sprint.outside)
        read.items.removeAll { $0.key == key }
        readOutside(sprint, read)
        #expect(states.undoable == change)
        await states.undo()
        #expect(azure.sent == [.setState(key, from: "New", to: "Closed"), .setState(key, from: "Closed", to: "New")])
        #expect(states.line == .changed(change.back))
        #expect(told.map(\.key) == [key, key] && told.last?.item?.state == "New")
    }

    /// A change of a work item only Show Links reads, as someone else's on My Work's Map, goes from the state Show Links read
    /// it in, and tells what else shows it, as Azure DevOps answered; one that didn't happen tells it too, for Show Links to
    /// read it again.
    @Test func aChangeOfAWorkItemShowLinksReadsTellsWhatElseShowsIt() async throws {
        let (sprint, states, azure) = live()
        var read = try samsTask(sprint)
        let key = read.key
        states.linked = { $0 == key ? read : nil }
        var told: [(key: WorkItemKey, item: WorkItem?)] = []
        states.elsewhere = { key, item in
            told.append((key, item))
            // Show Links shows it so at once.
            if let item { read = item }
        }
        #expect(await states.change(read, to: "Closed"))
        #expect(azure.sent == [.setState(key, from: "Active", to: "Closed")])
        #expect(told.map(\.key) == [key] && told.first?.item?.state == "Closed")
        #expect(states.undoable?.name == "Task 9001")

        azure.fails = .offline
        #expect(await !states.change(read, to: "Active"))
        #expect(states.line == .failed(
            StateChanges.Change(key: key, name: "Task 9001", title: read.title, from: "Closed", to: "Active"), .offline
        ))
        #expect(told.map(\.key) == [key, key] && told.last?.item == nil)
    }

    /// A work item off the sprint's board is read as whichever of what BriefBar reads of it changed last, as My Work's Map
    /// shows it too: one of yours outside the sprint that Show Links read since in another state, in that one. One changed
    /// to a state the team's process counts as done, though its name doesn't say so, stays done as Show Links reads it in
    /// that state, guessing its category from its name.
    @Test func aWorkItemOffTheBoardIsReadAsItChangedLastInTheTeamsCategory() async throws {
        let (sprint, states, _) = live()
        var board = try #require(sprint.board)
        board.stateCategories["Task"]?["Ready to ship"] = "Completed"
        sprint.receive(SprintSnapshot(board: board, hasLoaded: true))
        readOutside(sprint)
        let key = WorkItemKey(DemoData.organization, 5052)
        let mine = try #require(sprint.outside?.items.first { $0.key == key })
        var closed = mine
        closed.state = "Closed"
        closed.category = .completed
        closed.changedAt = mine.changedAt?.addingTimeInterval(60)
        states.linked = { $0 == key ? closed : nil }
        #expect(states.item(key) == closed)

        var sams = try samsTask(sprint)
        states.linked = { $0 == sams.key ? sams : nil }
        #expect(await states.change(sams, to: "Ready to ship"))
        let changed = try #require(states.item(sams.key))
        #expect(changed.state == "Ready to ship" && changed.isDone)
        sams.state = "Ready to ship"
        sams.category = WorkItem.Category(category: nil, state: "Ready to ship")
        sams.changedAt = changed.changedAt
        #expect(!sams.isDone)
        #expect(states.item(sams.key) == changed)
    }

    /// A work item only Show Links reads, as a parent My Work's Map shows, in a state the team's process counts as done
    /// though its name doesn't say so, is done as the team's backlog configuration maps its type's states, which Show Links
    /// doesn't read; one in another project, whose process may map them otherwise, keeps the category its state's name gives.
    @Test func aWorkItemOnlyShowLinksReadsIsInTheTeamsCategoryOfItsState() throws {
        let (sprint, states, _) = live()
        var board = try #require(sprint.board)
        board.stateCategories["Feature"] = ["New": "Proposed", "Active": "InProgress", "Verified": "Completed"]
        sprint.receive(SprintSnapshot(board: board, hasLoaded: true))
        var parent = WorkItem(
            id: 9_002, organization: DemoData.organization, project: board.team.projectName, type: "Feature",
            title: "Coupons at checkout", state: "Verified", category: WorkItem.Category(category: nil, state: "Verified")
        )
        #expect(!parent.isDone)
        states.linked = { $0 == parent.key ? parent : nil }
        #expect(states.item(parent.key)?.isDone == true)
        parent.project = "Payments"
        #expect(states.item(parent.key) == parent)
    }

    /// A work item on the sprint's board, as a story My Work's Map shows as your tasks' parent, is read as the board has it
    /// while something shows the sprint, which reads it the most often then. Once nothing does, it's read as whichever
    /// changed last of the board's, as the sprint was last read, and Show Links', which reads it for the Map then: closed and
    /// renamed since, it shows so; a read from before the sprint's leaves it as the board has it.
    @Test func aWorkItemOnTheBoardIsReadAsItChangedLastWhileNothingShowsTheSprint() throws {
        let (sprint, states, _) = live()
        let story = try item(sprint, 5101)
        let changedAt = try #require(story.changedAt)
        #expect(!sprint.isShowing)
        var older = story
        older.state = "New"
        older.changedAt = changedAt.addingTimeInterval(-60)
        states.linked = { $0 == story.key ? older : nil }
        #expect(states.item(story.key) == story)

        var closed = story
        closed.title = "Save items for later"
        closed.state = "Closed"
        closed.category = .completed
        closed.changedAt = changedAt.addingTimeInterval(60)
        states.linked = { $0 == story.key ? closed : nil }
        #expect(states.item(story.key) == closed)
        #expect(states.item(story.key)?.isDone == true)

        sprint.setVisible(true, for: "sprint")
        #expect(states.item(story.key) == story)
    }

    /// Waits for what the changes do, which runs on the main actor between this test's awaits, for as long as a busy machine
    /// could need (`waitLimit`), failing the test if it doesn't happen.
    private func waitUntil(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
