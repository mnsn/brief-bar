import Foundation
import Testing
@testable import AzureDevOpsCore

/// A work item's state on the Sprint page: the states of its type, as the team's backlog configuration maps them, in the
/// order its process goes through them; and what a change of one shows until the sprint is read again.
@Suite struct SprintStatesTests {
    // MARK: The states offered

    /// A type's states by category, to start, in progress, resolved and done; two of the same category as the default
    /// processes order them, a process's own after them; never Removed; the type whatever the case of its letters; none for
    /// a type the configuration doesn't map.
    @Test func offersATypesStatesInItsProcesssOrder() {
        var board = DemoData.sprintBoard(now: t(0))
        board.stateCategories = [
            "Task": ["Closed": "Completed", "Removed": "Removed", "Active": "InProgress", "New": "Proposed"],
            "Product Backlog Item": [
                "Done": "Completed", "Committed": "InProgress", "Approved": "Proposed", "New": "Proposed", "Removed": "Removed",
            ],
            "Bug": ["Resolved": "Resolved", "Closed": "Completed", "Active": "InProgress", "Triage": "Proposed", "New": "Proposed"],
            "Issue": ["Doing": "InProgress", "Done": "Completed", "To Do": "Proposed"],
        ]
        #expect(board.states(of: "Task").map(\.name) == ["New", "Active", "Closed"])
        #expect(board.states(of: "TASK").map(\.name) == ["New", "Active", "Closed"])
        #expect(board.states(of: "Product Backlog Item").map(\.name) == ["New", "Approved", "Committed", "Done"])
        #expect(board.states(of: "Bug").map(\.name) == ["New", "Triage", "Active", "Resolved", "Closed"])
        #expect(board.states(of: "Bug").map(\.category) == [.proposed, .proposed, .inProgress, .resolved, .completed])
        #expect(board.states(of: "Issue").map(\.name) == ["To Do", "Doing", "Done"])
        #expect(board.states(of: "Epic").isEmpty)
        #expect(board.categories(of: "Epic") == nil)
    }

    /// The team's states come with its sprint, from the backlog configuration the engine reads for its task types.
    @Test func theSprintsBoardHasItsTeamsStates() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1], children: [(1, 2)])], items: [
            WorkFixture.workItem(1, "User Story", "Story", state: "Active"),
            WorkFixture.workItem(2, state: "Active", parent: 1),
        ])
        let engine = SprintEngine(
            client: server.client(), configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        let board = try #require(await engine.currentSnapshot().board)
        #expect(board.states(of: "Task").map(\.name) == ["New", "Active", "Closed"])
        #expect(board.states(of: "User Story").map(\.name) == ["New", "Ready to Code", "Active", "Closed"])
    }

    // MARK: Where a change shows at once

    /// As Azure DevOps answered: in the state it says, in the category the board maps it to, changed when it says; else in
    /// the state asked for, at once; and, for a state the board doesn't map, in the category its name says.
    @Test func aWorkItemWhoseStateChangedIsAsAzureDevOpsSays() throws {
        let board = DemoData.sprintBoard(now: t(0))
        let task = try #require(board.item(WorkItemKey(DemoData.organization, 5104)))
        #expect(task.state == "New" && task.category == .proposed)
        let answer = try Fixture.decode(ADOWorkItem.self, WorkFixture.workItem(5104, state: "Active"))
        let changed = task.changing(state: "Active", answer: answer, at: t(60), categories: board.categories(of: task.type))
        #expect(changed.state == "Active" && changed.category == .inProgress)
        #expect(changed.changedAt == answer.fields.changedDate)
        #expect(changed.title == task.title && changed.remainingWork == task.remainingWork && changed.iteration == task.iteration)
        let unanswered = task.changing(state: "Closed", answer: nil, at: t(60), categories: board.categories(of: "task"))
        #expect(unanswered.state == "Closed" && unanswered.category == .completed && unanswered.changedAt == t(60))
        let guessed = task.changing(state: "Blocked", answer: nil, at: t(60), categories: board.categories(of: task.type))
        #expect(guessed.category == .inProgress)
    }

    /// Changed, it's in its new state where it was on the board, a story's row or a task in it, with nothing else of it
    /// changed; in a removed state, it leaves the board; one the board doesn't have changes nothing.
    @Test func aWorkItemWhoseStateChangedStaysWhereItIs() throws {
        let board = DemoData.sprintBoard(now: t(0))
        let task = try #require(board.item(WorkItemKey(DemoData.organization, 5104)))
        // Only its state is the change's: the rest is the board's, as read.
        var stale = task
        stale.title = "As it was when its state changed"
        let closed = board.changingState(stale.changing(state: "Closed", answer: nil, at: t(60), categories: board.categories(of: "Task")))
        let row = try #require(closed.rows.first { $0.parent?.id == 5101 })
        #expect(row.tasks.map(\.id) == [5102, 5103, 5104, 5105])
        let shown = try #require(closed.item(task.key))
        #expect(shown.state == "Closed" && shown.isDone && shown.changedAt == t(60))
        #expect(shown.title == task.title)
        #expect(closed.count(in: .done) == board.count(in: .done) + 1)

        let story = try #require(board.item(WorkItemKey(DemoData.organization, 5101)))
        let categories = board.categories(of: story.type)
        let resolved = board.changingState(story.changing(state: "Resolved", answer: nil, at: t(60), categories: categories))
        #expect(resolved.rows.first { $0.parent?.id == 5101 }?.parent?.category == .resolved)
        #expect(resolved.rows.map(\.id) == board.rows.map(\.id))

        let removing = task.changing(state: "Removed", answer: nil, at: t(60), categories: board.categories(of: "Task"))
        let removed = board.changingState(removing)
        #expect(removed.item(task.key) == nil)

        var elsewhere = task
        elsewhere.id = 9_999
        #expect(board.changingState(elsewhere.changing(state: "Closed", answer: nil, at: t(60), categories: nil)) == board)
    }

    // MARK: Until a read after it

    /// What BriefBar changed the state of shows in it at once, and stays so over a read that started before the change,
    /// which may have read it as it was; a read that started after it shows it as Azure DevOps has it.
    @Test func aStateChangeStaysOverAReadThatStartedBeforeIt() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1], children: [(1, 2)])], items: [
            WorkFixture.workItem(1, "User Story", "Story", state: "Active"),
            WorkFixture.workItem(2, state: "New", assignee: People.me, parent: 1),
        ])
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(), configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.team),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        let board = try #require(await engine.currentSnapshot().board)
        let task = try #require(board.item(WorkItemKey(Fixture.org, 2)))
        #expect(task.state == "New")

        // Set to Active at 10:10.
        clock.set(t(10 * minute))
        let categories = board.categories(of: task.type)
        await engine.changedState(task.changing(state: "Active", answer: nil, at: clock.value, categories: categories))
        #expect(await engine.currentSnapshot().board?.item(task.key)?.state == "Active")

        // A read that started at 10:05 still found it New.
        clock.set(t(5 * minute))
        await engine.refreshNow()
        let kept = try #require(await engine.currentSnapshot().board?.item(task.key))
        #expect(kept.state == "Active" && kept.category == .inProgress)

        // One that started at 10:20 finds it as Azure DevOps has it, here New again, as someone set it back.
        clock.set(t(20 * minute))
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.item(task.key)?.state == "New")
    }

    /// Another team chosen, what BriefBar changed of the last one's sprint goes with its board.
    @Test func anotherTeamsSprintForgetsTheStatesChanged() async throws {
        let server = StubServer()
        WorkFixture.serve(
            server, teams: [WorkFixture.team, WorkFixture.otherTeam],
            sprints: [WorkFixture.team.id: [WorkFixture.iteration()], WorkFixture.otherTeam.id: [WorkFixture.iteration("i2")]],
            relations: ["i1": WorkFixture.relations([2]), "i2": WorkFixture.relations([2])],
            items: [WorkFixture.workItem(2, state: "New")]
        )
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(), configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.team),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        let board = try #require(await engine.currentSnapshot().board)
        let task = try #require(board.item(WorkItemKey(Fixture.org, 2)))
        clock.set(t(10 * minute))
        let categories = board.categories(of: task.type)
        await engine.changedState(task.changing(state: "Closed", answer: nil, at: clock.value, categories: categories))

        await engine.setConfiguration(SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.otherTeam))
        clock.set(t(5 * minute))
        await engine.refreshNow()
        let other = try #require(await engine.currentSnapshot().board)
        #expect(other.team.id == WorkFixture.otherTeam.id)
        #expect(other.item(task.key)?.state == "New")
    }
}
