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
        /// How many times your team's sprints were read.
        var sprintsRead = 0
        var sprintsFail: ADOError?
        var next: Sprint? = DemoData.nextSprint(now: SprintMovesTests.referenceNow)

        func send(_ write: ADOWrite) throws -> ADOWrite.Answer {
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
        moves.send = { write, _ in try azure.send(write) }
        moves.readNextSprint = { try azure.readNext() }
        return (sprint, moves, azure)
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

    /// A move that didn't happen says why, and leaves the work item where it was read; Try Again sends it again.
    @Test func aMoveThatFailsSaysWhyAndCanBeTriedAgain() async throws {
        let (sprint, moves, azure) = live()
        azure.fails = .refused(nil, message: "Test operation failed.")
        let proposal = try #require(moves.propose(try item(sprint)))
        await moves.move(proposal)
        #expect(moves.state == .failed(proposal.move, .refused("Test operation failed.")))
        #expect(SprintMoveText.failed(proposal.move) == "Couldn't move Task 5052 to Sprint 42.")
        #expect(place(sprint) == "Sprint 41")
        #expect(moves.undoable == nil)

        azure.fails = nil
        await moves.retry()
        #expect(azure.sent.count == 2)
        #expect(moves.state == .moved(proposal.move))
        #expect(place(sprint) == nil)
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
        moves.accountChanged("robin@contoso.example")
        #expect(moves.undoable == again.move)
        moves.accountChanged("sam@contoso.example")
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
        // With no sprint going on, there's nothing to read it after.
        sprint.receive(SprintSnapshot(hasLoaded: true, outside: DemoData.outsideWork(now: Self.referenceNow)))
        #expect(try await sprint.nextSprint(now: start) == nil)
        #expect(read.count == 2)
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
        moves.send = { write, _ in try azure.send(write) }
        let proposal = try #require(await moves.proposeNext(try item(sprint)))
        #expect(proposal.sprint.name == "Sprint 43")
        await moves.move(proposal)
        #expect(azure.sent.isEmpty)
        #expect(place(sprint) == "Sprint 43")
        #expect(moves.state == .moved(proposal.move))
    }
}
