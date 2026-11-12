import Foundation
import Testing
@testable import BriefBarCore

/// Start next, Up Next's last slot on My Work while the Board shows your sprint work: what's in To start, to start next.
@Suite struct StartNextTests {
    private typealias Steps = NextStepsTests

    /// The sprint's To start first, in its order, then, with + All My Tasks, yours outside it, after them: nothing else, not
    /// what's started, resolved or done, or what a pull request on the board names.
    @Test func offersTheSprintsWorkToStartFirstThenYoursOutsideIt() throws {
        let stages: [Int: StageReading] = [4101: Steps.reading(.inProgress, .draft, at: 1)]
        let work = [
            // The sprint's, as its backlog orders them: started first, then to start.
            Steps.work(5103, .inProgress, story: 5001),
            Steps.work(5104, .toDo, story: 5001),
            Steps.work(5107, .toDo, story: 5001, linked: [Steps.linked(4101)]),
            Steps.work(5150, .toDo),
            Steps.work(5106, .resolved, story: 5001),
            // Yours outside it, as the Board has them.
            Steps.work(5052, .toDo, story: 5001),
            Steps.work(4990, .inProgress),
            Steps.work(4870, .toDo),
        ]
        let board = Steps.board(stages, missions: []).withWork(work, missions: [], stories: [Steps.task(5001)])
        let next = try #require(board.startNext)
        #expect(next.tasks.map(\.ref) == [5104, 5150, 5052, 4870].map(Steps.task))
        #expect(next.task.ref == Steps.task(5104))
        #expect(!next.isPicked)
        #expect(next.count == 4)
        #expect(next.more == "3 more")

        // Nothing to start: no slot.
        let started = Steps.board(stages, missions: []).withWork([Steps.work(5103, .inProgress)], missions: [], stories: [])
        #expect(started.startNext == nil)
        #expect(Steps.board(stages, missions: []).startNext == nil)
    }

    /// Your work in a sprint after the current one, as one you moved to the next, comes last, the nearest sprint's first,
    /// after the rest of yours outside the sprint, which the Board has latest sprint first; the Board keeps its order.
    @Test func aLaterSprintsWorkComesLastTheNearestFirst() throws {
        func later(_ id: Int, _ sprint: Int) -> SprintWork {
            var work = Steps.work(id, .toDo)
            work.laterSprint = "Storefront\\Sprint \(sprint)"
            return work
        }
        let work = [Steps.work(5104, .toDo, story: 5001), later(5190, 44), later(5052, 43), Steps.work(4870, .toDo), later(5191, 43)]
        let stories = [Steps.task(5001)]
        let board = Steps.board([:], missions: []).withWork(work, missions: [], stories: stories)
        #expect(board.startNext?.tasks.map(\.ref) == [5104, 4870, 5052, 5191, 5190].map(Steps.task))
        #expect(board.lanes.first { $0.kind == .notInAMission }?.tasks.map(\.ref) == [5190, 5052, 4870, 5191].map(Steps.task))

        // By the number in their names: Sprint 9 is nearer than Sprint 10.
        let numbered = Steps.board([:], missions: []).withWork([later(5190, 10), later(5191, 9)], missions: [], stories: [])
        #expect(numbered.startNext?.tasks.map(\.ref) == [5191, 5190].map(Steps.task))

        // Nothing else to start: it's next. The one you chose comes first all the same.
        let alone = Steps.board([:], missions: []).withWork([later(5052, 43)], missions: [], stories: [])
        #expect(alone.startNext?.task.ref == Steps.task(5052))
        let picked = Steps.board([:], missions: []).withWork(work, missions: [], stories: stories, startPick: Steps.task(5190))
        #expect(picked.startNext?.tasks.map(\.ref) == [5190, 5104, 4870, 5052, 5191].map(Steps.task))
    }

    /// The one you chose comes first, in the slot and in its lane's To start, while it's there; otherwise it waits, and the
    /// backlog's order chooses.
    @Test func theOneYouChoseComesFirstWhileItsThere() throws {
        let work = [
            Steps.work(5104, .toDo, story: 5001), Steps.work(5105, .toDo, story: 5001), Steps.work(5108, .toDo, story: 5001),
            Steps.work(5150, .toDo), Steps.work(5103, .inProgress, story: 5001),
        ]
        let stories = [Steps.task(5001)]
        let picked = Steps.board([:], missions: []).withWork(work, missions: [], stories: stories, startPick: Steps.task(5108))
        let next = try #require(picked.startNext)
        #expect(next.task.ref == Steps.task(5108))
        #expect(next.tasks.map(\.ref) == [5108, 5104, 5105, 5150].map(Steps.task))
        #expect(next.isPicked)
        let lane = try #require(picked.lanes.first { $0.story == Steps.task(5001) })
        #expect(lane.tasks(in: .toStart).map(\.ref) == [5108, 5104, 5105].map(Steps.task))
        #expect(lane.tasks(in: .inProgress).map(\.ref) == [Steps.task(5103)])

        // Started, it's not there: the backlog's order chooses, and its lane keeps it.
        for pick in [Steps.task(5103), Steps.task(9999)] {
            let waits = Steps.board([:], missions: []).withWork(work, missions: [], stories: stories, startPick: pick)
            #expect(waits.startNext?.task.ref == Steps.task(5104))
            #expect(waits.startNext?.isPicked == false)
            #expect(waits.lanes.first { $0.story == Steps.task(5001) }?.tasks.map(\.ref) == [5104, 5105, 5108, 5103].map(Steps.task))
        }
    }
}
