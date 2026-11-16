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

    /// Each work item on the sprint's board, task, story or bug, offers its type's states; one the board doesn't have, or
    /// whose type's states the team's configuration doesn't say, none, and nothing says how to turn anything on for it.
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
    /// way. One outside the sprint, or whose type's states the team's configuration doesn't say, doesn't. Moving a card
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
        await changing.value
        #expect(azure.sent.isEmpty)
        let change = StateChanges.Change(
            key: key, name: "Task 5104", title: task.title, from: "New", to: "Active", account: "robin@contoso.example"
        )
        #expect(states.line == .failed(change, .notListed))
        #expect(ADOWriteProblem.notListed.sentence(.setState) == "As BriefBar reads the sprint now, it isn't in the state it was in "
            + "when you chose another, or isn't on its board, so its state didn't change.")
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
        await changing.value
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
