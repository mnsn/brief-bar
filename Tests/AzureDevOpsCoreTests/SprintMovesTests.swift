import Foundation
import Testing
@testable import AzureDevOpsCore

/// Moving a work item of yours to another sprint, on My Work: the team's next sprint, read only as you ask for it, and where
/// a work item it moved shows until the sprint and your work outside it are read again.
@Suite struct SprintMovesTests {
    // MARK: The next sprint

    /// A team's sprint, as Azure DevOps lists it, from its start, two weeks long.
    private static func iteration(_ number: Int, start: String?, timeFrame: String) -> [String: Any] {
        var json = WorkFixture.iteration("i\(number)", name: "Sprint \(number)", start: start.map { "\($0)T00:00:00Z" }, finish: nil)
        var attributes = json["attributes"] as? [String: Any] ?? [:]
        attributes["timeFrame"] = timeFrame
        json["attributes"] = attributes
        return json
    }

    private static func iterations(_ list: [[String: Any]]) throws -> [ADOIteration] {
        try list.map { try Fixture.decode(ADOIteration.self, $0) }
    }

    /// The current sprint of the fixtures: Sprint 7, from October 12.
    private static let current = Sprint(try! Fixture.decode(ADOIteration.self, WorkFixture.iteration()))

    /// The one that starts first after the current one does, however Azure DevOps lists them; with no current sprint, the
    /// first that starts after today.
    @Test func theNextSprintStartsFirstAfterTheCurrentOne() throws {
        let list = try Self.iterations([
            Self.iteration(6, start: "2026-09-28", timeFrame: "past"),
            WorkFixture.iteration(),
            Self.iteration(9, start: "2026-11-09", timeFrame: "future"),
            Self.iteration(8, start: "2026-10-26", timeFrame: "future"),
        ])
        #expect(Sprint.next(after: Self.current, in: list, now: t(0), calendar: WorkFixture.utc)?.name == "Sprint 8")
        // Listed without the current one.
        #expect(Sprint.next(after: Self.current, in: Array(list.dropFirst(2)), now: t(0), calendar: WorkFixture.utc)?.name == "Sprint 8")
        // With none going on, the first after today, October 18.
        #expect(Sprint.next(after: nil, in: list, now: t(0), calendar: WorkFixture.utc)?.name == "Sprint 8")
        #expect(Sprint.next(after: nil, in: list, now: t(10 * day), calendar: WorkFixture.utc)?.name == "Sprint 9")
        // None after it.
        #expect(Sprint.next(after: Self.current, in: Array(list.prefix(2)), now: t(0), calendar: WorkFixture.utc) == nil)
        #expect(Sprint.next(after: Self.current, in: [], now: t(0), calendar: WorkFixture.utc) == nil)
    }

    /// Without dates, the first that Azure DevOps says the team hasn't reached yet, as it lists them, when none after the
    /// current one has dates; never one it's past.
    @Test func withoutDatesTheNextIsTheFirstFutureOne() throws {
        let list = try Self.iterations([
            Self.iteration(5, start: nil, timeFrame: "past"),
            WorkFixture.iteration(),
            Self.iteration(12, start: nil, timeFrame: "future"),
            Self.iteration(11, start: nil, timeFrame: "future"),
        ])
        #expect(Sprint.next(after: Self.current, in: list, now: t(0), calendar: WorkFixture.utc)?.name == "Sprint 12")
        let dated = try list + Self.iterations([Self.iteration(8, start: "2026-10-26", timeFrame: "future")])
        #expect(Sprint.next(after: Self.current, in: dated, now: t(0), calendar: WorkFixture.utc)?.name == "Sprint 8")
        #expect(Sprint.next(after: Self.current, in: Array(list.prefix(2)), now: t(0), calendar: WorkFixture.utc) == nil)
    }

    /// The team's sprints are read with one GET, of them all, rather than of the current one alone.
    @Test func readsTheTeamsSprintsWithOneGET() async throws {
        let server = StubServer()
        server.on("/t1/_apis/work/teamsettings/iterations", json: Fixture.list([
            WorkFixture.iteration(), Self.iteration(8, start: "2026-10-26", timeFrame: "future"),
        ]))
        let next = try await TeamSprints.next(
            of: WorkFixture.team, after: Self.current, client: server.client(), now: t(0), calendar: WorkFixture.utc
        )
        #expect(next?.name == "Sprint 8")
        #expect(next?.path == "Shop\\Sprint 8")
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.url?.absoluteString == "https://dev.azure.com/contoso/p1/t1/_apis/work/teamsettings/iterations?api-version=7.1")
    }

    // MARK: Where a move shows at once

    /// As Azure DevOps answered: where it says it is, and when it says it changed; else where it went, and when.
    @Test func aMovedWorkItemIsWhereAzureDevOpsSaysItIs() throws {
        let item = try #require(DemoData.outsideWork(now: t(0)).items.first { $0.id == 5052 })
        let answer = try Fixture.decode(ADOWorkItem.self, WorkFixture.workItem(5052, iteration: "Storefront\\Sprint 43"))
        let moved = item.moved(to: "Storefront\\sprint 43", answer: answer, at: t(60))
        #expect(moved.iteration == "Storefront\\Sprint 43")
        #expect(moved.changedAt == answer.fields.changedDate)
        #expect(moved.title == item.title && moved.state == item.state && moved.category == item.category)
        let unanswered = item.moved(to: "Storefront\\Sprint 43", answer: nil, at: t(60))
        #expect(unanswered.iteration == "Storefront\\Sprint 43")
        #expect(unanswered.changedAt == t(60))
    }

    /// Moved to another sprint, it leaves the sprint's board: a story with its row, its tasks left without a story; moved
    /// within it, or as it was read without an iteration, it stays.
    @Test func aWorkItemMovedOutOfTheSprintLeavesItsBoard() throws {
        let board = DemoData.sprintBoard(now: t(0))
        let task = try #require(board.item(WorkItemKey(DemoData.organization, 5104)))
        var elsewhere = task
        elsewhere.iteration = "Storefront\\Sprint 43"
        let without = board.moving(elsewhere)
        #expect(without.item(task.key) == nil)
        #expect(without.rows.first { $0.parent?.id == 5101 }?.tasks.map(\.id) == [5102, 5103, 5105])
        #expect(without.rows.count == board.rows.count)

        var here = task
        here.iteration = "storefront\\SPRINT 42"
        #expect(board.moving(here) == board)
        #expect(board.moving(task) == board)

        let story = board.removing(WorkItemKey(DemoData.organization, 5101))
        #expect(story.rows.allSatisfy { $0.parent?.id != 5101 })
        let loose = try #require(story.rows.first { $0.parent == nil })
        #expect(Set(loose.tasks.map(\.id)).isSuperset(of: [5102, 5103, 5104, 5105]))
        #expect(story.items.count == board.items.count - 1)
    }

    /// Moved, it's among your work outside the sprint where it went, in order, as a read would have it: one that left the
    /// sprint's board joins it; one moved into the sprint's own iteration stays, with no place to say, until the board has it.
    @Test func aMovedWorkItemIsAmongYourWorkWhereItWent() throws {
        let board = DemoData.sprintBoard(now: t(0))
        let outside = DemoData.outsideWork(now: t(0))
        var item = try #require(outside.items.first { $0.id == 4870 })
        #expect(outside.place(of: item) == OutsideWork.noSprint)

        item.iteration = "Storefront\\Sprint 43"
        let later = outside.placing(item, board: board)
        #expect(later.items.count == outside.items.count)
        #expect(later.items.first?.id == 4870)
        #expect(later.place(of: item) == "Sprint 43")
        #expect(later.taskTypes == outside.taskTypes && later.sprintPath == outside.sprintPath)
        // In a sprint after the current one, as the Board orders them by name: Start next offers it last.
        #expect(later.isLater(item))
        #expect(!outside.isLater(try #require(outside.items.first { $0.id == 5052 })))
        #expect(!outside.isLater(try #require(outside.items.first { $0.id == 4870 })))
        item.iteration = "Storefront\\Sprint 100"
        #expect(outside.isLater(item))
        #expect(!OutsideWork(items: outside.items, taskTypes: outside.taskTypes).isLater(item))

        item.iteration = board.sprint.path
        let inSprint = outside.placing(item, board: board)
        #expect(inSprint.items.contains { $0.id == 4870 })
        #expect(inSprint.place(of: item) == nil)
        #expect(!inSprint.notInSprint.contains { $0.id == 4870 })

        var task = try #require(board.item(WorkItemKey(DemoData.organization, 5104)))
        task.iteration = "Storefront\\Sprint 41"
        let left = outside.placing(task, board: board.moving(task))
        #expect(left.items.contains { $0.id == 5104 })
        #expect(left.place(of: task) == "Sprint 41")
    }

    // MARK: Until a read after it

    /// What BriefBar moved shows where it went at once, and stays there over a read that started before the move, which may
    /// have read it where it was; a read that started after it shows it as Azure DevOps has it.
    @Test func aMoveStaysOverAReadThatStartedBeforeIt() async throws {
        let server = StubServer()
        let items = [
            WorkFixture.workItem(1, "User Story", "Story", state: "Active"),
            WorkFixture.workItem(2, state: "Active", assignee: People.me, parent: 1),
            WorkFixture.workItem(10, assignee: People.me, parent: 1, iteration: "Shop\\Sprint 5"),
        ]
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1], children: [(1, 2)])], items: items)
        server.on("/_apis/work/predefinedqueries/AssignedToMe", json: ["results": [["id": 2], ["id": 10]]])
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(), configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.team),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.setReadsOutside(true)
        await engine.refreshNow()
        let read = try #require(await engine.currentSnapshot().outside?.items.first { $0.id == 10 })
        #expect(read.iteration == "Shop\\Sprint 5")

        // Moved to the next sprint at 10:10.
        clock.set(t(10 * minute))
        await engine.moved(read.moved(to: "Shop\\Sprint 8", answer: nil, at: clock.value))
        var outside = try #require(await engine.currentSnapshot().outside)
        #expect(outside.items.first { $0.id == 10 }.flatMap(outside.place(of:)) == "Sprint 8")

        // A read that started at 10:05 still found it in Sprint 5.
        clock.set(t(5 * minute))
        await engine.refreshNow()
        outside = try #require(await engine.currentSnapshot().outside)
        #expect(outside.items.first { $0.id == 10 }.flatMap(outside.place(of:)) == "Sprint 8")

        // One that started at 10:20 finds it where Azure DevOps has it, here back in Sprint 5, as someone moved it back.
        clock.set(t(20 * minute))
        await engine.refreshNow()
        outside = try #require(await engine.currentSnapshot().outside)
        #expect(outside.items.first { $0.id == 10 }.flatMap(outside.place(of:)) == "Sprint 5")

        // Moved into the sprint, it leaves your work outside it once the board has it.
        clock.set(t(30 * minute))
        await engine.moved(read.moved(to: "Shop\\Sprint 7", answer: nil, at: clock.value))
        outside = try #require(await engine.currentSnapshot().outside)
        #expect(outside.notInSprint.allSatisfy { $0.id != 10 })
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1], children: [(1, 2), (1, 10)])], items: items)
        clock.set(t(40 * minute))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.item(WorkItemKey(Fixture.org, 10)) != nil)
        #expect(snapshot.outside?.items.contains { $0.id == 10 } == false)
    }

    /// A refresh that read the board again, and then couldn't read your work outside the sprint, as Azure DevOps asked
    /// BriefBar to slow down, keeps what BriefBar moved where it went, until a read after it succeeds.
    @Test func aMoveStaysOverARefreshThatFailedAfterReadingTheBoard() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1], children: [(1, 2), (1, 3)])], items: [
            WorkFixture.workItem(1, "User Story", "Story", state: "Active"),
            WorkFixture.workItem(2, state: "Active", assignee: People.me, parent: 1),
            WorkFixture.workItem(3, assignee: People.me, parent: 1),
        ])
        server.on("/_apis/work/predefinedqueries/AssignedToMe", json: ["results": [["id": 2], ["id": 3]]])
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(), configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.team),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.setReadsOutside(true)
        await engine.refreshNow()
        let task = try #require(await engine.currentSnapshot().board?.item(WorkItemKey(Fixture.org, 3)))
        await engine.moved(task.moved(to: "Shop\\Sprint 8", answer: nil, at: clock.value))

        server.on("/_apis/work/predefinedqueries/AssignedToMe") { _ in
            StubServer.Reply(status: 429, headers: ["Retry-After": "120"], body: Data())
        }
        clock.set(t(5 * minute))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.problem != nil)
        #expect(snapshot.board?.item(task.key) == nil)
        let outside = try #require(snapshot.outside)
        #expect(outside.items.first { $0.id == 3 }.flatMap(outside.place(of:)) == "Sprint 8")
    }

    /// A refresh that read the board again, but not your work outside the sprint, as that read failed or stopped as My Work
    /// stopped wanting it, keeps what BriefBar moved where it went; one that reads all that's wanted then settles it.
    @Test func aMoveStaysUntilARefreshReadsAllThatsWanted() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1], children: [(1, 2), (1, 3)])], items: [
            WorkFixture.workItem(1, "User Story", "Story", state: "Active"),
            WorkFixture.workItem(2, state: "Active", assignee: People.me, parent: 1),
            WorkFixture.workItem(3, assignee: People.me, parent: 1),
            WorkFixture.workItem(10, assignee: People.me, parent: 1, iteration: "Shop\\Sprint 5"),
        ])
        let assigned = "/_apis/work/predefinedqueries/AssignedToMe"
        server.on(assigned, json: ["results": [["id": 2], ["id": 3], ["id": 10]]])
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(), configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.team),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.setReadsOutside(true)
        await engine.refreshNow()
        let task = try #require(await engine.currentSnapshot().board?.item(WorkItemKey(Fixture.org, 3)))
        await engine.moved(task.moved(to: "Shop\\Sprint 8", answer: nil, at: clock.value))
        func placed() async -> (onBoard: Bool, place: String?) {
            let snapshot = await engine.currentSnapshot()
            let outside = snapshot.outside
            return (snapshot.board?.item(task.key) != nil, outside?.items.first { $0.id == 3 }.flatMap { outside?.place(of: $0) })
        }

        // Your work outside the sprint couldn't be read.
        server.on(assigned) { _ in .status(500) }
        clock.set(t(5 * minute))
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().outside?.problem != nil)
        var now = await placed()
        #expect(!now.onBoard && now.place == "Sprint 8")

        // My Work stopped wanting it while it was read.
        let gate = DispatchSemaphore(value: 0)
        server.on(assigned) { _ in
            _ = gate.wait(timeout: .now() + 240)
            return .json(["results": [["id": 2], ["id": 3], ["id": 10]]])
        }
        let asked = server.requests.filter { $0.url?.path.contains(assigned) == true }.count
        clock.set(t(10 * minute))
        let refreshing = Task { await engine.refreshNow() }
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while server.requests.filter({ $0.url?.path.contains(assigned) == true }).count == asked, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await engine.setReadsOutside(false)
        gate.signal()
        await refreshing.value
        now = await placed()
        #expect(!now.onBoard && now.place == "Sprint 8")

        // Not wanted, it isn't waited for: the board, read after the move, is as Azure DevOps has it.
        clock.set(t(15 * minute))
        await engine.refreshNow()
        now = await placed()
        #expect(now.onBoard)
    }

    /// Moved out of the sprint, it leaves the board at once, and joins your work outside it.
    @Test func aMoveOutOfTheSprintLeavesTheBoardAtOnce() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1], children: [(1, 2), (1, 3)])], items: [
            WorkFixture.workItem(1, "User Story", "Story", state: "Active"),
            WorkFixture.workItem(2, state: "Active", assignee: People.me, parent: 1),
            WorkFixture.workItem(3, assignee: People.me, parent: 1),
        ])
        server.on("/_apis/work/predefinedqueries/AssignedToMe", json: ["results": [["id": 2], ["id": 3]]])
        let engine = SprintEngine(
            client: server.client(), configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.setReadsOutside(true)
        await engine.refreshNow()
        let task = try #require(await engine.currentSnapshot().board?.item(WorkItemKey(Fixture.org, 3)))
        await engine.moved(task.moved(to: "Shop\\Sprint 8", answer: nil, at: t(0)))
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.item(task.key) == nil)
        #expect(snapshot.board?.myWork.map(\.id) == [2])
        let outside = try #require(snapshot.outside)
        #expect(outside.items.first { $0.id == 3 }.flatMap(outside.place(of:)) == "Sprint 8")
    }
}
