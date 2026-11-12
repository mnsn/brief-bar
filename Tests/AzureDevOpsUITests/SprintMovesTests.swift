import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Moving a work item of yours to another sprint, on My Work, with Make Changes in Azure DevOps on: what goes to Azure
/// DevOps, only while it's on and you confirm; where it shows at once; Undo; what the line under My Work's header says when
/// it can't move; and your team's sprints, read only as you move one to the next. With the demo's made-up sprint and your
/// work outside it, as a sprint that reads Azure DevOps would have them, and a stand-in for Azure DevOps that answers as it
/// does.
@MainActor
@Suite struct SprintMovesTests {
    /// What the stand-in for Azure DevOps was sent, and answers.
    final class AzureDevOps {
        var sent: [ADOWrite] = []
        var fails: ADOError?
        /// Whom the Azure CLI is signed in as: as the client does, a change asked for as someone else goes nowhere.
        var signedIn: String?
        /// How many times your team's sprints were read.
        var sprintsRead = 0
        var sprintsFail: ADOError?
        var next: Sprint? = DemoData.nextSprint(now: SprintMovesTests.referenceNow)

        func send(_ write: ADOWrite, as account: String? = nil) throws -> ADOWrite.Answer {
            if let signedIn, let account, account != signedIn { throw ADOError.otherAccount }
            sent.append(write)
            if let fails { throw fails }
            guard case .setIteration(let key, _, let path) = write else { throw ADOError.http(400) }
            return .workItem(try ADOJSON.decoder().decode(ADOWorkItem.self, from: JSONSerialization.data(withJSONObject: [
                "id": key.id, "rev": 2, "fields": ["System.Id": key.id, "System.IterationPath": path, "System.ChangedDate": "2030-01-01T10:00:00Z"],
            ] as [String: Any])))
        }

        func readNext() throws -> Sprint? {
            sprintsRead += 1
            if let sprintsFail { throw sprintsFail }
            return next
        }
    }

    nonisolated static let referenceNow = Date()

    /// Task 5052, "Remove the old cart cookie", of yours in Sprint 41, under a story of Sprint 42.
    private let key = WorkItemKey(DemoData.organization, 5052)

    /// A sprint that reads Azure DevOps, with the demo's Sprint 42 and your work outside it read, and what moves it.
    private func live(makesChanges: Bool = true) -> (sprint: SprintStore, moves: SprintMoves, azure: AzureDevOps) {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = makesChanges
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
        let sprint = SprintStore(settings: settings, mode: .live, client: store.client)
        sprint.receive(SprintSnapshot(
            board: DemoData.sprintBoard(now: Self.referenceNow), hasLoaded: true, outside: DemoData.outsideWork(now: Self.referenceNow)
        ))
        let moves = SprintMoves(sprint: sprint, settings: settings, client: store.client)
        let azure = AzureDevOps()
        moves.send = { write, account in try azure.send(write, as: account) }
        moves.readNextSprint = { try azure.readNext() }
        return (sprint, moves, azure)
    }

    /// The sprint and your work outside it, read again as they are, as someone signed in to the Azure CLI.
    private func read(_ sprint: SprintStore, as account: String) {
        sprint.receive(SprintSnapshot(board: sprint.board, hasLoaded: true, outside: sprint.outside, account: account))
    }

    private func item(_ sprint: SprintStore, _ id: Int = 5052) throws -> WorkItem {
        try #require(sprint.item(WorkItemKey(DemoData.organization, id)))
    }

    private func place(_ sprint: SprintStore, _ id: Int = 5052) -> String? {
        guard let outside = sprint.outside, let item = sprint.item(WorkItemKey(DemoData.organization, id)) else { return nil }
        return outside.place(of: item)
    }

    @Test func nothingMovesOrIsReadWhileItsOff() async throws {
        let (sprint, moves, azure) = live(makesChanges: false)
        let task = try item(sprint)
        #expect(!moves.canMove(task))
        #expect(moves.propose(task) == nil)
        #expect(await moves.proposeNext(task) == nil)
        #expect(azure.sprintsRead == 0)
        let proposal = SprintMoves.Proposal(
            move: SprintMoves.Move(key: key, name: "Task 5052", title: task.title, from: "Storefront\\Sprint 41", to: "Storefront\\Sprint 42"),
            target: .current, sprint: DemoData.sprint(now: Self.referenceNow)
        )
        await moves.move(proposal)
        #expect(azure.sent.isEmpty)
        #expect(moves.state == nil)
        #expect(place(sprint) == "Sprint 41")
    }

    /// Only your work outside the sprint moves, read with its iteration, while a sprint is going on: not the sprint's own.
    @Test func onlyYourWorkOutsideTheSprintMoves() throws {
        let (sprint, moves, _) = live()
        #expect(moves.canMove(try item(sprint)))
        #expect(moves.canMove(try item(sprint, 4870)))
        // In the sprint, read without an iteration.
        #expect(!moves.canMove(try item(sprint, 5104)))
        // Outside, but in the sprint's iteration: its board doesn't have it yet.
        var inSprint = try item(sprint)
        inSprint.iteration = "Storefront\\Sprint 42"
        #expect(!moves.canMove(inSprint))
        // With no sprint going on.
        sprint.receive(SprintSnapshot(hasLoaded: true, outside: DemoData.outsideWork(now: Self.referenceNow)))
        #expect(!moves.canMove(try item(sprint)))
        #expect(moves.propose(try item(sprint)) == nil)
    }

    /// A move goes once, as you confirmed it, testing where the work item was, and shows where Azure DevOps put it at once;
    /// Undo moves it back, without asking, and is then done with.
    @Test func aMoveGoesOnceAsConfirmedAndUndoMovesItBack() async throws {
        let (sprint, moves, azure) = live()
        let proposal = try #require(moves.propose(try item(sprint)))
        #expect(proposal.target == .current)
        #expect(proposal.move.from == "Storefront\\Sprint 41" && proposal.move.to == "Storefront\\Sprint 42")
        #expect(SprintMoveText.title(proposal) == "Move Task 5052 to Sprint 42?")
        #expect(SprintMoveText.confirm(proposal) == "Move to Sprint 42")
        #expect(SprintMoveText.message(proposal) == "“Remove the old cart cookie” is in Sprint 41. BriefBar sets its iteration in "
            + "Azure DevOps to Sprint 42, your team's current sprint, as you. You can undo it on My Work.")
        #expect(azure.sent.isEmpty)

        await moves.move(proposal)
        #expect(azure.sent == [.setIteration(key, from: "Storefront\\Sprint 41", to: "Storefront\\Sprint 42")])
        #expect(moves.state == .moved(proposal.move))
        #expect(SprintMoveText.moved(proposal.move) == "Moved Task 5052 from Sprint 41 to Sprint 42.")
        // In the sprint's iteration, it has no place to say, and isn't counted as outside it.
        #expect(try item(sprint).iteration == "Storefront\\Sprint 42")
        #expect(place(sprint) == nil)
        #expect(sprint.outside?.notInSprint.contains { $0.key == key } == false)
        #expect(moves.undoable == proposal.move)
        // It can't move again from where it was: it's in the sprint now.
        #expect(!moves.canMove(try item(sprint)))

        await moves.undo()
        #expect(azure.sent.last == .setIteration(key, from: "Storefront\\Sprint 42", to: "Storefront\\Sprint 41"))
        #expect(azure.sent.count == 2)
        #expect(moves.state == .moved(proposal.move.back))
        #expect(SprintMoveText.moved(proposal.move.back) == "Moved Task 5052 back to Sprint 41.")
        #expect(place(sprint) == "Sprint 41")
        #expect(moves.undoable == nil)
        await moves.undo()
        #expect(azure.sent.count == 2)
        moves.dismiss()
        #expect(moves.state == nil)
    }

    /// Your team's sprints are read only as you move one to the next, once within the hour; what the line says while they
    /// are, when they can't be, Try Again, and when the team has no sprint after the current one.
    @Test func theNextSprintIsReadOnlyAsYouMoveOneThere() async throws {
        let (sprint, moves, azure) = live()
        _ = moves.propose(try item(sprint))
        #expect(azure.sprintsRead == 0)

        let proposal = try #require(await moves.proposeNext(try item(sprint)))
        #expect(azure.sprintsRead == 1)
        #expect(proposal.target == .next)
        #expect(proposal.sprint.name == "Sprint 43")
        #expect(proposal.move.to == "Storefront\\Sprint 43")
        #expect(moves.finding == nil)
        let dates = try #require(SprintMoveText.dates(proposal.sprint))
        #expect(SprintMoveText.message(proposal).contains("to Sprint 43, your team's next sprint, \(dates), as you."))
        await moves.move(proposal)
        #expect(azure.sent == [.setIteration(key, from: "Storefront\\Sprint 41", to: "Storefront\\Sprint 43")])
        #expect(place(sprint) == "Sprint 43")
        // Still outside the sprint, it can move again: Undo is the first thing its menu offers.
        #expect(moves.canMove(try item(sprint)))
        #expect(moves.undoable == proposal.move)

        azure.sprintsFail = .http(500)
        #expect(await moves.proposeNext(try item(sprint, 4870)) == nil)
        guard case .failed(let name, let failedKey, let problem)? = moves.finding else {
            Issue.record("Expected the sprints not to be read, got \(String(describing: moves.finding))")
            return
        }
        #expect(name == "Task 4870" && failedKey == WorkItemKey(DemoData.organization, 4870))
        #expect(SprintMoveText.findFailed(problem) == "Couldn't find your team's next sprint. \(problem)")
        // Said in place of what the move did, which comes back once it's dismissed.
        azure.sprintsFail = nil
        let again = try #require(await moves.retryFinding())
        #expect(again.move.key == WorkItemKey(DemoData.organization, 4870))
        #expect(moves.finding == nil)
        #expect(moves.state == .moved(proposal.move))

        azure.next = nil
        #expect(await moves.proposeNext(try item(sprint, 4870)) == nil)
        #expect(moves.finding == .none(after: "Sprint 42"))
        #expect(SprintMoveText.noNextSprint(after: "Sprint 42") == "Your team has no sprint after Sprint 42 in Azure DevOps yet.")
        moves.dismiss()
        #expect(moves.finding == nil)
    }

    /// A move that didn't happen says why, and leaves the work item where it was read; Try Again sends it again where it may
    /// help: not once Azure DevOps refused it, as when someone moved it meanwhile.
    @Test func aMoveThatFailsSaysWhyAndCanBeTriedAgain() async throws {
        let (sprint, moves, azure) = live()
        azure.fails = .offline
        let proposal = try #require(moves.propose(try item(sprint)))
        await moves.move(proposal)
        #expect(moves.state == .failed(proposal.move, .offline))
        #expect(SprintMoveText.failed(proposal.move) == "Couldn't move Task 5052 to Sprint 42.")
        #expect(place(sprint) == "Sprint 41")
        #expect(moves.undoable == nil)

        azure.fails = nil
        await moves.retry()
        #expect(azure.sent.count == 2)
        #expect(moves.state == .moved(proposal.move))
        #expect(place(sprint) == nil)

        azure.fails = .refused(nil, message: "Test operation failed.")
        let other = try #require(moves.propose(try item(sprint, 4870)))
        await moves.move(other)
        #expect(moves.state == .failed(other.move, .refused("Test operation failed.")))
        #expect(!SprintMoves.retries(.refused("Test operation failed.")))
        azure.fails = nil
        await moves.retry()
        #expect(azure.sent.count == 3)
        #expect(moves.state == .failed(other.move, .refused("Test operation failed.")))
    }

    /// A move goes as whom BriefBar read the work item as when you chose to move it, and only from where it was then, as
    /// BriefBar reads it as you confirm: not once a read found it elsewhere, nor once it's gone from your work, and not again
    /// once it's where it goes, as when confirmed in another window too. Signed in as someone else since, nothing goes.
    @Test func aMoveGoesAsWhomItWasReadAsFromWhereItWas() async throws {
        let (sprint, moves, azure) = live()
        azure.signedIn = "robin@contoso.example"
        read(sprint, as: "robin@contoso.example")
        let proposal = try #require(moves.propose(try item(sprint)))
        #expect(proposal.move.account == "robin@contoso.example")
        let board = try #require(sprint.board), outside = try #require(sprint.outside)

        // Read again in Sprint 43, as someone moved it meanwhile.
        var elsewhere = try item(sprint)
        elsewhere.iteration = "Storefront\\Sprint 43"
        sprint.receive(SprintSnapshot(
            board: board, hasLoaded: true, outside: outside.placing(elsewhere, board: board), account: "robin@contoso.example"
        ))
        await moves.move(proposal)
        #expect(azure.sent.isEmpty)
        #expect(moves.state == .failed(proposal.move, .notListed))
        #expect(ADOWriteProblem.notListed.sentence(.setIteration)
            == "As BriefBar reads your work now, it isn't where it was when you chose to move it, so it didn't move.")
        #expect(!SprintMoves.retries(.notListed))
        await moves.retry()
        #expect(azure.sent.isEmpty)

        // Gone from your work.
        sprint.receive(SprintSnapshot(
            board: board, hasLoaded: true, outside: OutsideWork(items: outside.items.filter { $0.key != key }, sprintPath: board.sprint.path),
            account: "robin@contoso.example"
        ))
        await moves.move(proposal)
        #expect(azure.sent.isEmpty)
        #expect(moves.state == .failed(proposal.move, .notListed))

        // Back where it was: it goes, as whom it was read as, and once only.
        sprint.receive(SprintSnapshot(board: board, hasLoaded: true, outside: outside, account: "robin@contoso.example"))
        await moves.move(proposal)
        #expect(azure.sent == [.setIteration(key, from: "Storefront\\Sprint 41", to: "Storefront\\Sprint 42")])
        #expect(moves.state == .moved(proposal.move))
        await moves.move(proposal)
        #expect(azure.sent.count == 1)
        #expect(moves.state == .moved(proposal.move))

        // Asked for before someone else signed in: what was going on goes, and nothing goes as them.
        let other = try #require(moves.propose(try item(sprint, 4870)))
        azure.signedIn = "sam@contoso.example"
        read(sprint, as: "sam@contoso.example")
        #expect(moves.state == nil)
        await moves.move(other)
        #expect(azure.sent.count == 1)
        #expect(moves.state == .failed(other.move, .otherAccount))
    }

    /// A move called off before it went, as the setting goes off while it waits for a token, sends nothing and leaves nothing
    /// on its way; with the setting back on, a move goes again.
    @Test func aMoveCalledOffBeforeItWentLeavesNothingOnItsWay() async throws {
        let (sprint, moves, azure) = live()
        moves.send = { write, account in
            // Waits, as for a token, until it's called off: longer than a test can wait, on however busy a machine.
            try await Task.sleep(for: .seconds(600))
            return try azure.send(write, as: account)
        }
        let proposal = try #require(moves.propose(try item(sprint)))
        let moving = Task { await moves.move(proposal) }
        try await waitUntil { moves.isBusy }
        moves.settings.makesChanges = false
        await moving.value
        #expect(azure.sent.isEmpty)
        #expect(moves.state == nil)
        #expect(!moves.isBusy)
        #expect(place(sprint) == "Sprint 41")

        moves.settings.makesChanges = true
        moves.send = { write, account in try azure.send(write, as: account) }
        let again = try #require(moves.propose(try item(sprint)))
        await moves.move(again)
        #expect(azure.sent.count == 1)
        #expect(moves.state == .moved(again.move))
    }

    /// Undo is for the move you just made, while the work item is where it went: not once it moved elsewhere since, as
    /// someone else moved it, the setting went off, or someone else signed in.
    @Test func undoGoesOnceItsNoLongerWhereItWent() async throws {
        let (sprint, moves, _) = live()
        let next = try #require(await moves.proposeNext(try item(sprint)))
        await moves.move(next)
        #expect(moves.undoable == next.move)
        // Read again, back in Sprint 41.
        sprint.receive(SprintSnapshot(
            board: DemoData.sprintBoard(now: Self.referenceNow), hasLoaded: true, outside: DemoData.outsideWork(now: Self.referenceNow)
        ))
        #expect(moves.undoable == nil)

        let current = try #require(moves.propose(try item(sprint)))
        await moves.move(current)
        #expect(moves.undoable == current.move)
        moves.settings.makesChanges = false
        #expect(moves.undoable == nil)
        #expect(moves.state == nil)
        moves.settings.makesChanges = true
        #expect(moves.undoable == nil)

        let again = try #require(moves.propose(try item(sprint, 4870)))
        await moves.move(again)
        #expect(moves.undoable == again.move)
        read(sprint, as: "robin@contoso.example")
        #expect(moves.undoable == again.move)
        read(sprint, as: "sam@contoso.example")
        #expect(moves.undoable == nil)
    }

    /// Your team's next sprint is read as you ask for it, then known for an hour, for the sprint going on, by team.
    @Test func theNextSprintIsKnownForAnHour() async throws {
        let (sprint, _, _) = live()
        var read: [String] = []
        sprint.readNextSprint = { team, current in
            read.append("\(team.name) after \(current.name)")
            return DemoData.nextSprint(now: Self.referenceNow)
        }
        let start = Self.referenceNow
        #expect(try await sprint.nextSprint(now: start)?.name == "Sprint 43")
        #expect(try await sprint.nextSprint(now: start.addingTimeInterval(59 * 60))?.name == "Sprint 43")
        #expect(read == ["Storefront Team after Sprint 42"])
        #expect(try await sprint.nextSprint(now: start.addingTimeInterval(60 * 60))?.name == "Sprint 43")
        #expect(read.count == 2)
        // Forgotten, as a move there failed: read again.
        sprint.forgetNextSprint(at: "Storefront\\Sprint 41")
        #expect(try await sprint.nextSprint(now: start.addingTimeInterval(61 * 60))?.name == "Sprint 43")
        #expect(read.count == 2)
        sprint.forgetNextSprint(at: "storefront\\sprint 43")
        #expect(try await sprint.nextSprint(now: start.addingTimeInterval(61 * 60))?.name == "Sprint 43")
        #expect(read.count == 3)
        // With no sprint going on, there's nothing to read it after.
        sprint.receive(SprintSnapshot(hasLoaded: true, outside: DemoData.outsideWork(now: Self.referenceNow)))
        #expect(try await sprint.nextSprint(now: start) == nil)
        #expect(read.count == 3)
    }

    /// No next sprint isn't kept, as one may be added any time; one a move to failed is read again as you move one there, as
    /// it may have been deleted or renamed since.
    @Test func theNextSprintIsReadAgainWhenThereWasNoneOrAMoveThereFailed() async throws {
        let (sprint, moves, azure) = live()
        sprint.readNextSprint = { _, _ in try azure.readNext() }
        moves.readNextSprint = { [weak sprint] in try await sprint?.nextSprint() }
        azure.next = nil
        #expect(await moves.proposeNext(try item(sprint)) == nil)
        #expect(moves.finding == .none(after: "Sprint 42"))
        azure.next = DemoData.nextSprint(now: Self.referenceNow)
        let proposal = try #require(await moves.proposeNext(try item(sprint)))
        #expect(moves.finding == nil)
        _ = try #require(await moves.proposeNext(try item(sprint)))
        #expect(azure.sprintsRead == 2)

        let refusal = "TF401347: Invalid tree name given for work item 5052, field 'System.IterationPath'."
        azure.fails = .refused(nil, message: refusal)
        await moves.move(proposal)
        #expect(moves.state == .failed(proposal.move, .refused(refusal)))
        _ = try #require(await moves.proposeNext(try item(sprint)))
        #expect(azure.sprintsRead == 3)
    }

    /// The demo moves only its made-up work, and sends nothing.
    @Test func theDemoMovesOnlyItsMadeUpWork() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = true
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .demo)
        let sprint = SprintStore(settings: settings, mode: .demo, client: store.client)
        await sprint.loadOnce()
        let moves = SprintMoves(sprint: sprint, settings: settings, client: store.client)
        let azure = AzureDevOps()
        moves.send = { write, account in try azure.send(write, as: account) }
        let proposal = try #require(await moves.proposeNext(try item(sprint)))
        #expect(proposal.sprint.name == "Sprint 43")
        await moves.move(proposal)
        #expect(azure.sent.isEmpty)
        #expect(place(sprint) == "Sprint 43")
        #expect(moves.state == .moved(proposal.move))
    }

    /// Waits for what the moves do, which runs on the main actor between this test's awaits, for as long as a busy machine
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
