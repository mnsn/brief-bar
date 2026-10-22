import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

// MARK: - Made-up sprints, work items and pipelines

enum WorkFixture {
    static let team = TeamRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", id: "t1", name: "Shop Team")
    static let otherTeam = TeamRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", id: "t2", name: "Checkout Team")

    /// Days in UTC, as Azure DevOps keeps a sprint's dates.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func teamJSON(_ team: TeamRef) -> [String: Any] {
        ["id": team.id, "name": team.name, "projectId": team.projectId, "projectName": team.projectName, "url": "https://example.invalid"]
    }

    /// The sprint going on at the reference time (2026-10-18): October 12 to 25.
    static func iteration(_ id: String = "i1", name: String = "Sprint 7", start: String? = "2026-10-12T00:00:00Z",
                          finish: String? = "2026-10-25T00:00:00Z") -> [String: Any] {
        var attributes: [String: Any] = ["timeFrame": "current"]
        attributes["startDate"] = start ?? NSNull()
        attributes["finishDate"] = finish ?? NSNull()
        return ["id": id, "name": name, "path": "Shop\\\(name)", "attributes": attributes, "url": "https://example.invalid"]
    }

    static func relations(_ roots: [Int], children: [(parent: Int, child: Int)] = []) -> [String: Any] {
        let top: [[String: Any]] = roots.map { ["rel": NSNull(), "source": NSNull(), "target": ["id": $0, "url": "https://example.invalid"]] }
        let under: [[String: Any]] = children.map {
            ["rel": "System.LinkTypes.Hierarchy-Forward", "source": ["id": $0.parent], "target": ["id": $0.child]]
        }
        return ["workItemRelations": top + under, "url": "https://example.invalid"]
    }

    static func workItem(
        _ id: Int, _ type: String = "Task", _ title: String = "A task", state: String = "New", assignee: Person? = nil, parent: Int? = nil,
        remaining: Double? = nil, rank: Double? = nil
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "System.Id": id, "System.WorkItemType": type, "System.Title": title, "System.State": state, "System.TeamProject": "Shop",
            "System.ChangedDate": iso(t(-hour)),
        ]
        if let assignee { fields["System.AssignedTo"] = Fixture.identity(assignee) }
        if let parent { fields["System.Parent"] = parent }
        if let remaining { fields["Microsoft.VSTS.Scheduling.RemainingWork"] = remaining }
        if let rank { fields["Microsoft.VSTS.Common.StackRank"] = rank }
        return ["id": id, "rev": 1, "fields": fields, "url": "https://example.invalid"]
    }

    static var backlogConfiguration: [String: Any] { [
        "taskBacklog": ["name": "Tasks", "workItemTypes": [["name": "Task", "url": "https://example.invalid"]]],
        "workItemTypeMappedStates": [
            ["workItemTypeName": "Task", "states": ["New": "Proposed", "Active": "InProgress", "Closed": "Completed"]],
            ["workItemTypeName": "User Story",
             "states": ["New": "Proposed", "Ready to Code": "Proposed", "Active": "InProgress", "Closed": "Completed"]],
        ],
    ] }

    /// Serves a team: your identity, your teams, the team's sprint and board setup, and the sprint's work items.
    static func serve(
        _ server: StubServer, teams: [TeamRef] = [WorkFixture.team], sprints: [String: [[String: Any]]] = [WorkFixture.team.id: [WorkFixture.iteration()]],
        relations: [String: [String: Any]] = [:], items: [[String: Any]] = []
    ) {
        server.on("/\(Fixture.org)/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/\(Fixture.org)/_apis/teams", json: Fixture.list(teams.map(teamJSON)))
        server.on("/_apis/work/backlogconfiguration", json: backlogConfiguration)
        for (team, list) in sprints {
            server.on("/\(team)/_apis/work/teamsettings/iterations", json: Fixture.list(list))
        }
        for (iteration, json) in relations {
            server.on("/iterations/\(iteration)/workitems", json: json)
        }
        let bodies = Dictionary(uniqueKeysWithValues: items.map { (($0["id"] as? Int) ?? 0, Fixture.data($0)) })
        server.on("/_apis/wit/workitems") { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let ids = (query.first { $0.name == "ids" }?.value ?? "").split(separator: ",").compactMap { Int($0) }
            let found = ids.compactMap { bodies[$0].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
            return .json(Fixture.list(found))
        }
    }

    static func build(
        _ id: Int, definition: Int, status: String = "completed", result: String? = "succeeded", queued: Date, minutes: Double = 5,
        branch: String = "refs/heads/main", reason: String = "individualCI", requestedFor: Person? = People.sam, project: String = "p1"
    ) -> [String: Any] {
        var json: [String: Any] = [
            "id": id, "buildNumber": "20261018.\(id)", "status": status, "reason": reason, "sourceBranch": branch,
            "queueTime": iso(queued), "definition": ["id": definition, "name": "pipeline \(definition)", "path": "\\Shop"],
            "project": ["id": project, "name": project == "p1" ? "Shop" : "Other"],
        ]
        if let result { json["result"] = result }
        if status != "notStarted" { json["startTime"] = iso(queued.addingTimeInterval(30)) }
        if status == "completed" { json["finishTime"] = iso(queued.addingTimeInterval(30 + minutes * 60)) }
        if let requestedFor { json["requestedFor"] = Fixture.identity(requestedFor) }
        return json
    }

    static func record(
        _ id: String, _ type: String, _ name: String, parent: String? = nil, order: Int? = nil, state: String = "completed",
        result: String? = "succeeded", identifier: String? = nil, finished: Date? = nil, issues: [[String: Any]] = []
    ) -> [String: Any] {
        var json: [String: Any] = ["id": id, "type": type, "name": name, "state": state, "issues": issues]
        json["parentId"] = parent ?? NSNull()
        json["result"] = result ?? NSNull()
        if let order { json["order"] = order }
        if let identifier { json["identifier"] = identifier }
        if let finished { json["finishTime"] = iso(finished) }
        return json
    }

    static func timeline(_ records: [[String: Any]]) -> [String: Any] {
        ["id": UUID().uuidString, "changeId": 1, "records": records]
    }
}

/// Hands out tokens like `FakeTokens`, but holds the `holdAt`-th request (each request asks for a token first) until
/// released: a refresh caught in the middle.
actor HeldTokens: AccessTokenProvider {
    private let value: String
    private let holdAt: Int
    private var calls = 0
    private var held: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false

    init(_ value: String, holdAt: Int) {
        self.value = value
        self.holdAt = holdAt
    }

    func token() async throws -> AccessToken {
        calls += 1
        if calls == holdAt {
            isHolding = true
            await withCheckedContinuation { held = $0 }
        }
        return AccessToken(value: value, expiresOn: .distantFuture)
    }

    func invalidate() {}

    func release() {
        held?.resume()
        held = nil
    }
}

/// Waits until `condition` holds, for as long as a busy machine could need.
func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestError("Timed out waiting for \(what)")
}

/// Waits until the engine is caught in the middle of a refresh.
func waitUntilHeld(_ tokens: HeldTokens) async throws {
    try await waitUntil("a request to be held") { await tokens.isHolding }
}

/// Collects what a running engine publishes.
final class Collected<Snapshot: Sendable>: Sendable {
    private let snapshots = Mutex<[Snapshot]>([])

    func add(_ snapshot: Snapshot) {
        snapshots.withLock { $0.append(snapshot) }
    }

    @discardableResult
    func wait(_ what: String, timeout: Duration = .seconds(10), until predicate: (Snapshot) -> Bool) async throws -> Snapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let latest = snapshots.withLock({ $0.last }), predicate(latest) { return latest }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError("Timed out waiting for \(what)")
    }
}

private func item(
    _ id: Int, _ type: String = "Task", state: String = "New", category: WorkItem.Category? = nil, assignee: Person? = nil,
    parent: Int? = nil, hours: Double? = nil, rank: Double? = nil
) -> WorkItem {
    WorkItem(
        id: id, organization: Fixture.org, project: "Shop", type: type, title: "Item \(id)", state: state,
        category: category ?? WorkItem.Category(category: nil, state: state), assignedTo: assignee, parentId: parent,
        remainingWork: hours, rank: rank
    )
}

private func relation(_ target: Int, under source: Int? = nil) -> ADOIterationWorkItems.Relation {
    ADOIterationWorkItems.Relation(
        rel: source == nil ? nil : "System.LinkTypes.Hierarchy-Forward", source: source.map { .init(id: $0) }, target: .init(id: target)
    )
}

private let sprint = Sprint(id: "i1", name: "Sprint 7", path: "Shop\\Sprint 7",
                            start: Timestamp.parse("2026-10-12T00:00:00Z"), finish: Timestamp.parse("2026-10-25T00:00:00Z"))

// MARK: - Decoding

@Suite struct WorkDecodingTests {
    @Test func decodesTeamsAndSkipsOnesWithoutAProject() throws {
        var lost = WorkFixture.teamJSON(WorkFixture.otherTeam)
        lost["projectId"] = nil
        let list = try Fixture.decode(ADOList<ADOTeam>.self, Fixture.list([WorkFixture.teamJSON(WorkFixture.team), lost]))
        #expect(list.value.compactMap { TeamRef(organization: Fixture.org, $0) } == [WorkFixture.team])
    }

    @Test func decodesASprintWithAndWithoutDates() throws {
        let dated = Sprint(try Fixture.decode(ADOIteration.self, WorkFixture.iteration()))
        #expect(dated.name == "Sprint 7")
        #expect(dated.path == "Shop\\Sprint 7")
        #expect(dated.start == Timestamp.parse("2026-10-12T00:00:00Z"))
        #expect(dated.length == 14)

        var odd = WorkFixture.iteration(start: nil, finish: nil)
        odd["attributes"] = ["startDate": "soon", "finishDate": NSNull()]
        let undated = Sprint(try Fixture.decode(ADOIteration.self, odd))
        #expect(undated.start == nil && undated.finish == nil)
        #expect(undated.daysLeft(now: t(0)) == nil)
    }

    @Test func decodesWorkItemsLeniently() throws {
        var json = WorkFixture.workItem(9, "Task", "  Fix   the\ttotal ", state: "Active", assignee: People.sam, parent: 8, remaining: 2.5)
        var fields = json["fields"] as! [String: Any]
        fields["Microsoft.VSTS.Common.StackRank"] = "first"
        fields["System.Tags"] = "backend; checkout ;"
        json["fields"] = fields
        let list = try Fixture.decode(ADOList<ADOWorkItem>.self, Fixture.list([json, ["id": "not a number"]]))
        #expect(list.skipped == 1)
        let task = WorkItem(organization: Fixture.org, project: "Shop", try #require(list.value.first),
                            categories: ["Task": ["Active": "InProgress"]])
        #expect(task.title == "Fix the total")
        #expect(task.category == .inProgress)
        #expect(task.assignedTo == People.sam)
        #expect(task.parentId == 8)
        #expect(task.remainingWork == 2.5)
        #expect(task.rank == nil)
        #expect(task.tags == ["backend", "checkout"])
        #expect(task.webURL.absoluteString == "https://dev.azure.com/contoso/Shop/_workitems/edit/9")
        #expect(ADOWorkItem.fieldNames.contains("System.Parent"))

        // With errorPolicy=omit, a work item that can't be read comes back as null.
        let withGaps = try Fixture.decode(ADOList<ADOWorkItem>.self, ["count": 2, "value": [WorkFixture.workItem(1), NSNull()]])
        #expect(withGaps.value.map(\.id) == [1])
        #expect(withGaps.skipped == 1)
    }

    @Test func decodesTheBacklogConfiguration() throws {
        let configuration = try Fixture.decode(ADOBacklogConfiguration.self, WorkFixture.backlogConfiguration)
        #expect(configuration.taskBacklog?.workItemTypes?.elements.map(\.name) == ["Task"])
        #expect(configuration.workItemTypeMappedStates?.elements.first { $0.workItemTypeName == "User Story" }?.states["Ready to Code"] == "Proposed")
    }

    @Test func decodesRunsAndTheirTimelines() throws {
        let service = Person(id: "00000002-0000-8888-8000-000000000000", name: "Microsoft.VisualStudio.Services.TFS")
        let builds = try Fixture.decode(ADOList<ADOBuild>.self, Fixture.list([
            WorkFixture.build(1, definition: 5, queued: t(-hour), branch: "refs/pull/12/merge", reason: "pullRequest"),
            WorkFixture.build(2, definition: 5, status: "inProgress", result: nil, queued: t(-minute), reason: "schedule", requestedFor: service),
            ["id": 3],
        ]))
        #expect(builds.skipped == 1)
        let runs = builds.value.map { PipelineRun(organization: Fixture.org, projectName: "Shop", $0) }
        #expect(runs.map(\.status) == [.succeeded, .running])
        #expect(runs.map(\.trigger) == [.pullRequest, .schedule])
        #expect(runs.map(\.branch) == ["!12", "main"])
        #expect(runs.map(\.requestedFor) == ["Sam Rivera", nil])
        #expect(runs[0].duration(now: t(0)) == 300)
        #expect(runs[0].webURL.absoluteString == "https://dev.azure.com/contoso/Shop/_build/results?buildId=1")

        let timeline = try Fixture.decode(ADOTimeline.self, WorkFixture.timeline([
            WorkFixture.record("s1", "Stage", "Build", order: 1),
            ["id": 7, "type": "Stage"],
        ]))
        #expect(timeline.records.elements.map(\.id) == ["s1"])
    }

    @Test func decodesPipelinesToPin() throws {
        let definition = try Fixture.decode(ADOBuildDefinition.self, [
            "id": 31, "name": "shop-web CI", "path": "\\Shop\\CI", "queueStatus": "enabled", "project": ["id": "p1", "name": "Shop"],
        ])
        let pipeline = try #require(PipelineRef(organization: Fixture.org, definition))
        #expect(pipeline.folder == "Shop\\CI")
        #expect(pipeline.id == "contoso/p1/31")
        #expect(pipeline.webURL.absoluteString == "https://dev.azure.com/contoso/Shop/_build?definitionId=31")
        #expect(PipelineRef(organization: Fixture.org, try Fixture.decode(ADOBuildDefinition.self, ["id": 1, "name": "x"])) == nil)
    }
}

// MARK: - The task board

@Suite struct SprintBoardTests {
    @Test func laysOutStoriesWithTheirTasks() {
        let items = [
            item(1, "User Story", state: "Active", rank: 2), item(2, state: "Active", parent: 1, rank: 2), item(3, state: "Closed", parent: 1, rank: 1),
            item(4, "Bug", state: "New", rank: 1),
            item(5, "User Story", state: "New", rank: 3),
            item(6, state: "New", rank: 1),
            item(7, state: "Removed", parent: 1),
            item(8, state: "New", parent: 2),
            item(9, "User Story", state: "Removed"), item(10, state: "Active", parent: 9, rank: 5),
        ]
        let relations = [relation(1), relation(4), relation(5), relation(6), relation(9), relation(2, under: 1), relation(3, under: 1),
                         relation(7, under: 1), relation(8, under: 2), relation(10, under: 9)]
        let board = SprintBoard.build(team: WorkFixture.team, sprint: sprint, me: People.me.id, relations: relations, items: items,
                                      taskTypes: ["Task"])
        // Stories and bugs in backlog order; then the tasks without one in the sprint, including a task's task and
        // the tasks of a removed story.
        #expect(board.rows.map(\.id) == [4, 1, 5, 0])
        #expect(board.rows[1].tasks.map(\.id) == [3, 2])
        #expect(board.rows[2].tasks.isEmpty)
        #expect(board.rows[3].parent == nil)
        #expect(Set(board.rows[3].tasks.map(\.id)) == [6, 8, 10])
        #expect(board.tasks.count == 5)
        #expect(board.count(in: .done) == 1)
        #expect(board.count(in: .toDo) == 2)
    }

    @Test func tracksBugsAsTasksWhenTheTeamDoes() {
        let items = [item(1, "User Story", state: "Active"), item(2, "Bug", state: "Active", parent: 1), item(3, "Bug", state: "New")]
        let relations = [relation(1), relation(3), relation(2, under: 1)]
        let asTasks = SprintBoard.build(team: WorkFixture.team, sprint: sprint, me: "", relations: relations, items: items,
                                        taskTypes: ["Task", "Bug"])
        #expect(asTasks.rows.map(\.id) == [1, 0])
        #expect(asTasks.rows[0].tasks.map(\.id) == [2])
        #expect(asTasks.rows[1].tasks.map(\.id) == [3])
        let asStories = SprintBoard.build(team: WorkFixture.team, sprint: sprint, me: "", relations: relations, items: items,
                                          taskTypes: ["Task"])
        #expect(asStories.rows.map(\.id) == [1, 3])
    }

    @Test func justMineKeepsYourStoriesAndYourTasks() {
        let me = People.me
        let items = [
            item(1, "User Story", assignee: me, rank: 1), item(2, parent: 1, rank: 1), item(3, assignee: People.sam, parent: 1, rank: 2),
            item(4, "User Story", assignee: People.sam, rank: 2), item(5, assignee: me, parent: 4, rank: 1), item(6, parent: 4, rank: 2),
            item(7, "User Story", assignee: People.sam, rank: 3), item(8, assignee: People.sam, parent: 7),
        ]
        let relations = [relation(1), relation(4), relation(7), relation(2, under: 1), relation(3, under: 1), relation(5, under: 4),
                         relation(6, under: 4), relation(8, under: 7)]
        let board = SprintBoard.build(team: WorkFixture.team, sprint: sprint, me: me.id.uppercased(), relations: relations, items: items,
                                      taskTypes: ["Task"])
        let mine = board.justMine()
        #expect(mine.rows.map(\.id) == [1, 4])
        #expect(mine.rows[0].tasks.map(\.id) == [2, 3])
        #expect(mine.rows[1].tasks.map(\.id) == [5])
    }

    @Test func groupsStoriesByWhereTheyStand() {
        func row(_ parent: WorkItem?, _ tasks: [WorkItem]) -> SprintBoard.Row { SprintBoard.Row(parent: parent, tasks: tasks) }
        #expect(row(item(1, "User Story", state: "Closed"), [item(2)]).progress == .done)
        #expect(row(item(1, "User Story", state: "Active"), []).progress == .inProgress)
        // Stories aren't always moved along: a task that started, or is done, counts.
        #expect(row(item(1, "User Story", state: "New"), [item(2, state: "Active")]).progress == .inProgress)
        #expect(row(item(1, "User Story", state: "New"), [item(2, state: "Closed"), item(3)]).progress == .inProgress)
        #expect(row(item(1, "User Story", state: "New"), [item(2)]).progress == .toDo)
        #expect(row(nil, [item(2, state: "Closed")]).progress == .done)
        #expect(row(item(1, "Bug", state: "Resolved"), []).progress == .inProgress)

        let ordered = row(item(1, "User Story"), [item(2, state: "Closed", rank: 1), item(3, rank: 2), item(4, state: "Active", rank: 3)])
            .tasksInWorkOrder
        #expect(ordered.map(\.id) == [4, 3, 2])
    }

    @Test func yourWorkIsInProgressThenToDo() {
        let me = People.me
        let items = [
            item(1, "User Story", assignee: People.sam, rank: 1), item(2, assignee: me, parent: 1, rank: 2),
            item(3, state: "Active", assignee: me, parent: 1, rank: 3), item(4, state: "Closed", assignee: me, parent: 1, rank: 1),
            item(5, "User Story", state: "New", assignee: me, rank: 2), item(6, "User Story", state: "Closed", assignee: me, rank: 3),
        ]
        let relations = [relation(1), relation(5), relation(6), relation(2, under: 1), relation(3, under: 1), relation(4, under: 1)]
        let board = SprintBoard.build(team: WorkFixture.team, sprint: sprint, me: me.id, relations: relations, items: items,
                                      taskTypes: ["Task"])
        #expect(board.myWork.map(\.id) == [3, 2, 5])
        #expect(board.myDoneCount == 2)
    }

    @Test func categoriesComeFromTheTeamOrAreGuessed() {
        #expect(WorkItem.Category(category: "InProgress", state: "Doing") == .inProgress)
        #expect(WorkItem.Category(category: "Proposed", state: "Ready to Code") == .proposed)
        #expect(WorkItem.Category(category: nil, state: "To Do") == .proposed)
        #expect(WorkItem.Category(category: nil, state: "Done") == .completed)
        #expect(WorkItem.Category(category: nil, state: "Resolved") == .resolved)
        #expect(WorkItem.Category(category: nil, state: "Removed") == .removed)
        #expect(WorkItem.Category(category: nil, state: "Committed") == .inProgress)
        #expect(WorkItem.Category.resolved.column == .inProgress)
        #expect(WorkItem.Category.removed.column == nil)
    }

    @Test func countsSprintDaysInTheLocalDay() {
        // 10:00 UTC on October 18, in a sprint from October 12 to 25.
        #expect(sprint.daysLeft(now: t(0), calendar: WorkFixture.utc) == 8)
        #expect(sprint.day(now: t(0), calendar: WorkFixture.utc) == 7)
        #expect(sprint.length == 14)
        #expect(sprint.isCurrent(now: t(0), calendar: WorkFixture.utc))
        #expect(abs((sprint.elapsed(now: t(0), calendar: WorkFixture.utc) ?? 0) - 6.5 / 14) < 0.0001)
        // The last day still counts, wherever you are: 23:30 on October 25 in California is October 26 in UTC.
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let lastEvening = Timestamp.parse("2026-10-26T06:30:00Z")!
        #expect(sprint.daysLeft(now: lastEvening, calendar: pacific) == 1)
        #expect(sprint.isCurrent(now: lastEvening, calendar: pacific))
        #expect(!sprint.isCurrent(now: lastEvening, calendar: WorkFixture.utc))
        #expect(sprint.daysLeft(now: lastEvening, calendar: WorkFixture.utc) == 0)
        // Before it starts, every day is left.
        #expect(sprint.daysLeft(now: t(-10 * day), calendar: WorkFixture.utc) == 14)
        // Whatever calendar the Mac uses: its days are the same days.
        for identifier in [Calendar.Identifier.buddhist, .persian, .hebrew, .islamicUmmAlQura, .japanese] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            #expect(sprint.isCurrent(now: t(0), calendar: calendar), "\(identifier)")
            #expect(sprint.daysLeft(now: t(0), calendar: calendar) == 8, "\(identifier)")
        }
    }

    @Test func demoBoardHasEverything() {
        let board = DemoData.sprintBoard(now: t(0), calendar: WorkFixture.utc)
        #expect(board.sprint.isCurrent(now: t(0), calendar: WorkFixture.utc))
        #expect(Set(board.rows.compactMap(\.parent).map { SprintBoard.Row(parent: $0, tasks: []).progress }).count >= 2)
        #expect(board.rows.contains { $0.parent == nil })
        #expect(board.rows.contains { $0.isDone })
        #expect(!board.myWork.isEmpty)
    }
}

// MARK: - Pipelines

@Suite struct PipelineTests {
    @Test func mapsRunsStatusesTriggersAndBranches() {
        #expect(PipelineRun.Status(status: "completed", result: "failed") == .failed)
        #expect(PipelineRun.Status(status: "completed", result: "partiallySucceeded") == .partiallySucceeded)
        #expect(PipelineRun.Status(status: "completed", result: "canceled") == .canceled)
        #expect(PipelineRun.Status(status: "cancelling", result: nil) == .running)
        #expect(PipelineRun.Status(status: "notStarted", result: nil) == .queued)
        #expect(PipelineRun.Status(status: "postponed", result: nil) == .queued)
        #expect(PipelineRun.Trigger("batchedCI") == .push)
        #expect(PipelineRun.Trigger("resourceTrigger") == .pipeline)
        #expect(PipelineRun.Trigger("something new") == .other)
        #expect(PipelineRun.branch("refs/heads/feature/a") == "feature/a")
        #expect(PipelineRun.branch("refs/tags/v1.2") == "v1.2")
        #expect(PipelineRun.branch("refs/pull/77/merge") == "!77")
        #expect(PipelineRun.branch(nil) == "")
    }

    @Test func readsAStagesFromATimeline() throws {
        let timeline = try Fixture.decode(ADOTimeline.self, WorkFixture.timeline([
            WorkFixture.record("s3", "Stage", "Deploy", order: 3, state: "pending", result: nil),
            WorkFixture.record("s1", "Stage", "Build", order: 1),
            WorkFixture.record("s2", "Stage", "Test", order: 2, result: "succeededWithIssues"),
            WorkFixture.record("c3", "Checkpoint", "Checkpoint", parent: "s3", state: "inProgress", result: nil),
            WorkFixture.record("j1", "Job", "Compile", parent: "s1"),
        ]))
        let running = PipelineStage.stages(from: timeline, runFinished: false)
        #expect(running.map(\.name) == ["Build", "Test", "Deploy"])
        #expect(running.map(\.state) == [.succeeded, .warning, .waiting])
        // Once the run is over, a stage that never ran was skipped.
        #expect(PipelineStage.stages(from: timeline, runFinished: true).last?.state == .skipped)
    }

    @Test func readsJobsWhenAPipelineHasNoStages() throws {
        let hidden = try Fixture.decode(ADOTimeline.self, WorkFixture.timeline([
            WorkFixture.record("s", "Stage", "__default", identifier: "__default"),
            WorkFixture.record("p2", "Phase", "Package", parent: "s", order: 2, state: "inProgress", result: nil),
            WorkFixture.record("p1", "Phase", "Compile", parent: "s", order: 1, result: "failed"),
        ]))
        #expect(PipelineStage.stages(from: hidden, runFinished: false).map(\.name) == ["Compile", "Package"])
        #expect(PipelineStage.stages(from: hidden, runFinished: false).map(\.state) == [.failed, .running])

        let classic = try Fixture.decode(ADOTimeline.self, WorkFixture.timeline([
            WorkFixture.record("j", "Job", "Agent job 1", result: "canceled"),
        ]))
        #expect(PipelineStage.stages(from: classic, runFinished: true).map(\.state) == [.canceled])
    }

    @Test func findsWhereARunFailedFirst() throws {
        let timeline = try Fixture.decode(ADOTimeline.self, WorkFixture.timeline([
            WorkFixture.record("s", "Stage", "Test", order: 2, result: "failed"),
            WorkFixture.record("p", "Phase", "Tests", parent: "s", result: "failed"),
            WorkFixture.record("j", "Job", "Unit tests", parent: "p", result: "failed"),
            WorkFixture.record("t2", "Task", "Publish results", parent: "j", result: "failed", finished: t(-minute),
                               issues: [["type": "error", "message": "Later"]]),
            WorkFixture.record("t1", "Task", "Run unit tests", parent: "j", result: "failed", finished: t(-2 * minute), issues: [
                ["type": "warning", "message": "Slow"],
                ["type": "error", "message": "##[error]2 tests   failed\nin CheckoutTests."],
            ]),
        ]))
        let failure = try #require(PipelineFailure.first(in: timeline))
        #expect(failure == PipelineFailure(stage: "Test", step: "Run unit tests", message: "2 tests failed in CheckoutTests."))

        let jobOnly = try Fixture.decode(ADOTimeline.self, WorkFixture.timeline([
            WorkFixture.record("s", "Stage", "__default", result: "failed", identifier: "__default"),
            WorkFixture.record("j", "Job", "Build", parent: "s", result: "failed"),
        ]))
        #expect(PipelineFailure.first(in: jobOnly) == PipelineFailure(stage: nil, step: "Build", message: nil))
        #expect(PipelineFailure.clean(String(repeating: "x", count: 400)).count == 300)
    }

    @Test func headlinesSayWhatTheLatestRunIsDoing() {
        let pipeline = PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: 1, name: "CI")
        func run(_ status: PipelineRun.Status) -> PipelineRun {
            PipelineRun(id: 1, organization: Fixture.org, projectName: "Shop", number: "1", status: status, trigger: .push, branch: "main")
        }
        let stages = [PipelineStage(id: "1", name: "Build", state: .succeeded), PipelineStage(id: "2", name: "Test", state: .running)]
        #expect(PipelineStatus(pipeline: pipeline, runs: []).headline == "No runs yet")
        #expect(PipelineStatus(pipeline: pipeline, runs: [run(.running)], stages: stages).headline == "Running Test")
        #expect(PipelineStatus(pipeline: pipeline, runs: [run(.running)],
                               stages: [PipelineStage(id: "3", name: "Production", state: .waiting)]).headline
            == "Waiting for approval to Production")
        #expect(PipelineStatus(pipeline: pipeline, runs: [run(.failed)],
                               failure: PipelineFailure(stage: "Test", step: "Run", message: nil)).headline == "Failed in Test")
        #expect(PipelineStatus(pipeline: pipeline, runs: [run(.failed)]).headline == "Failed")
        #expect(PipelineStatus(pipeline: pipeline, runs: [run(.partiallySucceeded)]).headline == "Succeeded with issues")

        let counts = PipelineCounts([PipelineStatus(pipeline: pipeline, runs: [run(.failed)]), PipelineStatus(pipeline: pipeline, runs: [run(.queued)]),
                                     PipelineStatus(pipeline: pipeline, runs: [run(.succeeded)]), PipelineStatus(pipeline: pipeline, runs: [])])
        #expect((counts.failed, counts.running, counts.succeeded) == (1, 1, 1))
        // By state: a failed pipeline is something wrong, a queued one is running, and one that succeeded isn't counted.
        #expect(counts.states == StateCounts(failing: 1, running: 1))
        #expect([run(.failed), run(.queued), run(.running), run(.succeeded), run(.partiallySucceeded), run(.canceled)]
            .map { PipelineStatus(pipeline: pipeline, runs: [$0]).state } == [.failing, .running, .running, nil, nil, nil])
        #expect(PipelineStatus(pipeline: pipeline, runs: []).state == nil)
        #expect(PipelineStatus(pipeline: pipeline, runs: [run(.failed)], failure: PipelineFailure(stage: "Test", step: "Run", message: nil))
            .briefSentence == "“\(pipeline.name)” failed in Test.")
        // The demo's: one failed its tests, and one runs while a release waits for approval.
        #expect(PipelineCounts(DemoData.pipelines()).states == StateCounts(failing: 1, running: 2))
        #expect(RunDuration.short(42) == "42s")
        #expect(RunDuration.short(372) == "6m 12s")
        #expect(RunDuration.short(3_900) == "1h 5m")
        #expect(RunDuration.short(7_200) == "2h")
    }

    @Test func buildsWorkEndpointURLs() {
        let team = TeamRef(organization: "contoso", projectId: "p1", projectName: "My Shop", id: "t1", name: "Shop Team")
        #expect(ADOEndpoint.myTeams(organization: "contoso").absoluteString
            == "https://dev.azure.com/contoso/_apis/teams?$mine=true&$top=500&api-version=7.1-preview.3")
        #expect(ADOEndpoint.currentIteration(team: team).absoluteString
            == "https://dev.azure.com/contoso/p1/t1/_apis/work/teamsettings/iterations?$timeframe=current&api-version=7.1")
        #expect(ADOEndpoint.iterationWorkItems(team: team, iterationId: "i1").absoluteString
            == "https://dev.azure.com/contoso/p1/t1/_apis/work/teamsettings/iterations/i1/workitems?api-version=7.1")
        #expect(ADOEndpoint.backlogConfiguration(team: team).absoluteString
            == "https://dev.azure.com/contoso/p1/t1/_apis/work/backlogconfiguration?api-version=7.1")
        #expect(ADOEndpoint.workItems(organization: "contoso", ids: [3, 1], fields: ["System.Title", "System.State"]).absoluteString
            == "https://dev.azure.com/contoso/_apis/wit/workitems?ids=3%2C1&fields=System.Title%2CSystem.State&errorPolicy=omit&api-version=7.1")
        #expect(ADOEndpoint.buildDefinitions(organization: "contoso", projectId: "p1", containing: " web* ").absoluteString
            == "https://dev.azure.com/contoso/p1/_apis/build/definitions?name=%2Aweb%2A&queryOrder=definitionNameAscending&$top=50&api-version=7.1")
        #expect(ADOEndpoint.buildDefinitions(organization: "contoso", projectId: "p1", containing: "").absoluteString
            == "https://dev.azure.com/contoso/p1/_apis/build/definitions?queryOrder=definitionNameAscending&$top=50&api-version=7.1")
        #expect(ADOEndpoint.builds(organization: "contoso", projectId: "p1", definitionIds: [9, 4], branch: "main").absoluteString
            == "https://dev.azure.com/contoso/p1/_apis/build/builds?definitions=4%2C9&maxBuildsPerDefinition=10"
            + "&queryOrder=queueTimeDescending&branchName=refs%2Fheads%2Fmain&api-version=7.1")
        #expect(ADOEndpoint.timeline(organization: "contoso", projectId: "p1", buildId: 7).absoluteString
            == "https://dev.azure.com/contoso/p1/_apis/build/builds/7/timeline?api-version=7.1")
        #expect(ADOEndpoint.projects(organization: "contoso").absoluteString
            == "https://dev.azure.com/contoso/_apis/projects?$top=1000&api-version=7.1")
        #expect(team.taskboardURL(sprint: Sprint(id: "i1", name: "Sprint 7", path: "My Shop\\2026\\Sprint 7", start: nil, finish: nil))
            .absoluteString == "https://dev.azure.com/contoso/My%20Shop/_sprints/taskboard/Shop%20Team/My%20Shop/2026/Sprint%207")
    }
}

// MARK: - Engines against a stub Azure DevOps

@Suite struct SprintEngineTests {
    private func engine(_ server: StubServer, team: TeamRef? = WorkFixture.team, interval: TimeInterval = 60,
                        published: Collected<SprintSnapshot>? = nil) -> SprintEngine {
        SprintEngine(
            client: server.client(), configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: team, interval: interval),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { published?.add($0) }
    }

    @Test func loadsTheTeamsSprintWithGETRequestsOnly() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1, 2], children: [(1, 3), (1, 4)])], items: [
            WorkFixture.workItem(1, "User Story", "Story", state: "Ready to Code", assignee: People.sam, rank: 1),
            WorkFixture.workItem(2, "User Story", "Other story", state: "Active", rank: 2),
            WorkFixture.workItem(3, state: "Active", assignee: People.me, parent: 1, remaining: 3),
            WorkFixture.workItem(4, state: "Closed", parent: 1),
        ])
        let engine = engine(server)
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.problem == nil)
        #expect(snapshot.hasLoaded)
        #expect(snapshot.teams == [WorkFixture.team])
        let board = try #require(snapshot.board)
        #expect(board.sprint.name == "Sprint 7")
        #expect(board.me == People.me.id)
        #expect(board.rows.map(\.id) == [1, 2])
        // The team's own state mapping: "Ready to Code" is a state of its own process.
        #expect(board.rows[0].parent?.category == .proposed)
        #expect(board.rows[0].progress == .inProgress)
        #expect(board.myWork.map(\.id) == [3])
        #expect(board.remainingWork == 3)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        // Your teams, your identity, the sprint, the board's setup, the sprint's work items and their fields.
        #expect(server.requests.count == 6)

        // The next refresh reads just the sprint's work items again.
        await engine.refreshNow()
        #expect(server.requests.count == 8)
    }

    @Test func findsTheTeamWithASprintGoingOnToday() async throws {
        let server = StubServer()
        WorkFixture.serve(
            server, teams: [WorkFixture.team, WorkFixture.otherTeam],
            sprints: [
                // Azure DevOps calls a team's last sprint current even when it's long over.
                WorkFixture.team.id: [WorkFixture.iteration("old", name: "Sprint 1", start: "2024-06-02T00:00:00Z", finish: "2024-06-15T00:00:00Z")],
                WorkFixture.otherTeam.id: [WorkFixture.iteration("i2", name: "Sprint 8")],
            ],
            relations: ["i2": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")]
        )
        let engine = engine(server, team: nil)
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.foundTeam == WorkFixture.otherTeam)
        #expect(snapshot.board?.sprint.name == "Sprint 8")
        #expect(snapshot.teams.map(\.id).sorted() == ["t1", "t2"])
    }

    @Test func prefersTheTeamWithMoreOfYourWork() async throws {
        let server = StubServer()
        WorkFixture.serve(
            server, teams: [WorkFixture.team, WorkFixture.otherTeam],
            sprints: [WorkFixture.team.id: [WorkFixture.iteration("i1")], WorkFixture.otherTeam.id: [WorkFixture.iteration("i2")]],
            relations: ["i1": WorkFixture.relations([1]), "i2": WorkFixture.relations([2, 3])],
            items: [WorkFixture.workItem(1, assignee: People.sam), WorkFixture.workItem(2, assignee: People.me),
                    WorkFixture.workItem(3, assignee: People.me)]
        )
        let engine = engine(server, team: nil)
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().foundTeam == WorkFixture.otherTeam)
    }

    @Test func saysWhenTheTeamHasNoSprint() async {
        let server = StubServer()
        WorkFixture.serve(server, sprints: [WorkFixture.team.id: []])
        let engine = engine(server)
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board == nil)
        #expect(snapshot.problem == nil)
        #expect(snapshot.hasLoaded)

        let none = await SprintEngine.loadOnce(client: server.client(), configuration: SprintEngine.Configuration(organizations: []))
        #expect(none.problem == .noOrganizations)
    }

    @Test func looksForTheTeamAgainWhenOneCouldntBeRead() async throws {
        let server = StubServer()
        WorkFixture.serve(
            server, teams: [WorkFixture.team, WorkFixture.otherTeam],
            sprints: [WorkFixture.team.id: [], WorkFixture.otherTeam.id: [WorkFixture.iteration("i2")]],
            relations: ["i2": WorkFixture.relations([1])], items: [WorkFixture.workItem(1)]
        )
        let failures = Locked(0)
        server.on("/t2/_apis/work/teamsettings/iterations", query: ["$timeframe": "current"]) { _ in
            failures.increment() == 1 ? .status(500) : .json(Fixture.list([WorkFixture.iteration("i2")]))
        }
        let engine = engine(server, team: nil)
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().foundTeam == nil)
        // Not "no sprint" for an hour: the next refresh looks again.
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.foundTeam == WorkFixture.otherTeam)
        #expect(snapshot.board != nil)
    }

    @Test func startsOverWhenSomeoneElseSignsIn() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])],
                          items: [WorkFixture.workItem(1, assignee: People.sam)])
        let tokens = FakeTokens(server.id)
        await tokens.signIn(as: "tenant/robin")
        let engine = SprintEngine(
            client: server.client(tokens: tokens), configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.me == People.me.id)

        await tokens.signIn(as: "tenant/sam")
        server.on("/\(Fixture.org)/_apis/connectionData", json: ["authenticatedUser": ["id": People.sam.id.uppercased()]])
        await engine.refreshNow()
        let board = try #require(await engine.currentSnapshot().board)
        #expect(board.me == People.sam.id)
        #expect(board.myWork.map(\.id) == [1])
    }

    @Test func readsWorkItemsTwoHundredAtATime() async throws {
        let server = StubServer()
        let ids = Array(1...250)
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations(ids)], items: ids.map { WorkFixture.workItem($0) })
        let engine = engine(server)
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.rows.first?.tasks.count == 250)
        let batches = server.requests.filter { $0.url?.path.hasSuffix("/_apis/wit/workitems") == true }.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ids" }?.value?
                .split(separator: ",").count ?? 0
        }
        #expect(batches == [200, 50])
    }

    @Test func readsOnlyWhileSomethingShowsTheSprint() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1)])
        let published = Collected<SprintSnapshot>()
        let engine = engine(server, published: published)
        await engine.start()
        defer { Task { await engine.stop() } }
        // Nothing should happen, so there's nothing to wait for: give it time. A slow machine can't fail this.
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.isEmpty)

        await engine.setActive(true)
        try await published.wait("the sprint") { $0.board != nil && !$0.isRefreshing }
        await engine.setActive(false)
        let count = server.requests.count
        await engine.refresh()
        // Nothing should happen, so there's nothing to wait for: give it time. A slow machine can't fail this.
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(server.requests.count == count)
    }

    @Test func stopsReadingWhenHiddenMidRefresh() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1)])
        // The first token is for checking who's signed in; the second is for the first request, your teams.
        let tokens = HeldTokens(server.id, holdAt: 2)
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org], team: WorkFixture.team), now: { t(0) },
            calendar: WorkFixture.utc
        ) { _ in }
        await engine.start()
        defer { Task { await engine.stop() } }
        await engine.setActive(true)
        try await waitUntilHeld(tokens)
        await engine.setActive(false)
        await tokens.release()
        // The request under way finishes, and the refresh stops: any request after it would be counted by then.
        try await waitUntil("the refresh to stop") {
            let refreshing = await engine.currentSnapshot().isRefreshing
            return !refreshing && !server.requests.isEmpty
        }
        #expect(server.requests.count == 1)
        #expect(await engine.currentSnapshot().refreshedAt == nil)
    }

    @Test func backsOffWhenAzureDevOpsCantBeRead() async {
        let server = StubServer()
        WorkFixture.serve(server)
        server.on("/_apis/work/teamsettings/iterations") { _ in .status(500) }
        let engine = engine(server)
        #expect(await engine.nextDelay() == 60)
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().problem == .unreachable("Azure DevOps answered with HTTP 500."))
        #expect(await engine.nextDelay() == 120)
        await engine.refreshNow()
        #expect(await engine.nextDelay() == 240)
    }
}

@Suite struct PipelinesEngineTests {
    private let web = PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: 31, name: "web CI")
    private let api = PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: 32, name: "api CI")
    private let release = PipelineRef(organization: Fixture.org, projectId: "p2", projectName: "Other", definitionId: 40, name: "Release",
                                      branch: "main")

    private func serve(_ server: StubServer, running: Bool = true) {
        server.on("/p1/_apis/build/builds", json: Fixture.list([
            WorkFixture.build(102, definition: 32, status: running ? "inProgress" : "completed", result: running ? nil : "succeeded",
                              queued: t(-2 * minute)),
            WorkFixture.build(101, definition: 31, result: "failed", queued: t(-hour)),
            WorkFixture.build(100, definition: 31, queued: t(-2 * hour)),
        ]))
        server.on("/p2/_apis/build/builds", json: Fixture.list([
            WorkFixture.build(200, definition: 40, queued: t(-day), project: "p2"),
        ]))
        server.on("/_apis/build/builds/101/timeline", json: WorkFixture.timeline([
            WorkFixture.record("s1", "Stage", "Build", order: 1),
            WorkFixture.record("s2", "Stage", "Test", order: 2, result: "failed"),
            WorkFixture.record("t1", "Task", "Run tests", parent: "s2", result: "failed", issues: [["type": "error", "message": "Boom"]]),
        ]))
        server.on("/_apis/build/builds/102/timeline", json: WorkFixture.timeline([
            WorkFixture.record("s1", "Stage", "Build", order: 1, state: running ? "inProgress" : "completed", result: running ? nil : "succeeded"),
        ]))
        server.on("/_apis/build/builds/200/timeline", json: WorkFixture.timeline([WorkFixture.record("s1", "Stage", "Deploy", order: 1)]))
    }

    @Test func readsEachProjectsPinnedPipelinesInOneRequest() async throws {
        let server = StubServer()
        serve(server)
        let engine = PipelinesEngine(client: server.client(), configuration: PipelinesEngine.Configuration(pipelines: [web, api, release])) { _ in }
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.problem == nil)
        #expect(snapshot.statuses.map(\.pipeline.name) == ["web CI", "api CI", "Release"])
        #expect(snapshot.statuses[0].runs.map(\.id) == [101, 100])
        #expect(snapshot.statuses[0].headline == "Failed in Test")
        #expect(snapshot.statuses[0].failure?.message == "Boom")
        #expect(snapshot.statuses[1].headline == "Running Build")
        #expect(snapshot.statuses[2].stages.map(\.name) == ["Deploy"])

        let builds = server.requests.filter { $0.url?.path.hasSuffix("/_apis/build/builds") == true }
        #expect(builds.count == 2)
        let release = try #require(builds.first { $0.url?.path.contains("/p2/") == true }?.url)
        #expect(release.query?.contains("branchName=refs%2Fheads%2Fmain") == true)
        // Two lists, and the latest run of each pipeline's stages.
        #expect(server.requests.count == 5)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    }

    @Test func readsAFinishedRunsStagesOnce() async {
        let server = StubServer()
        serve(server)
        let engine = PipelinesEngine(client: server.client(), configuration: PipelinesEngine.Configuration(pipelines: [web, api])) { _ in }
        await engine.refreshNow()
        await engine.refreshNow()
        let timelines = server.requests.compactMap(\.url?.path).filter { $0.hasSuffix("/timeline") }
        #expect(timelines.filter { $0.contains("/101/") }.count == 1)
        #expect(timelines.filter { $0.contains("/102/") }.count == 2)
    }

    @Test func aRunWithoutATimelineIsNotASignInProblem() async {
        let server = StubServer()
        serve(server, running: false)
        // Azure DevOps answers a timeline that isn't there with no content.
        server.on("/_apis/build/builds/101/timeline") { _ in StubServer.Reply(status: 204, headers: [:], body: Data()) }
        let tokens = FakeTokens(server.id)
        let engine = PipelinesEngine(client: server.client(tokens: tokens), configuration: PipelinesEngine.Configuration(pipelines: [web])) { _ in }
        await engine.refreshNow()
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.problem == nil)
        #expect(snapshot.statuses.first?.stages.isEmpty == true)
        #expect(await tokens.invalidations == 0)
        // A finished run's missing timeline isn't asked for again.
        #expect(server.requests.compactMap(\.url?.path).filter { $0.contains("/101/timeline") }.count == 1)
    }

    @Test func sleepsWhileNothingIsPinned() async {
        let server = StubServer()
        let engine = PipelinesEngine(client: server.client(), configuration: PipelinesEngine.Configuration(pipelines: [])) { _ in }
        await engine.setActive(true)
        await engine.refreshNow()
        #expect(await engine.sleepTime() >= 3_600)
        #expect(server.requests.isEmpty)
    }

    @Test func forgetsTheLastAccountsRunsWhenSomeoneElseSignsIn() async throws {
        let server = StubServer()
        serve(server, running: false)
        let tokens = FakeTokens(server.id)
        await tokens.signIn(as: "tenant/robin")
        let engine = PipelinesEngine(client: server.client(tokens: tokens), configuration: PipelinesEngine.Configuration(pipelines: [web])) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().statuses.first?.failure?.message == "Boom")

        // The new account may not read the pipeline: nothing of the last one's stays.
        await tokens.signIn(as: "tenant/sam")
        server.on("/p1/_apis/build/builds") { _ in .status(403) }
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        let status = try #require(snapshot.statuses.first)
        #expect(status.runs.isEmpty)
        #expect(status.stages.isEmpty)
        #expect(status.failure == nil)
        #expect(snapshot.problem == .unreachable("No access to this organization."))
    }

    @Test func stopsReadingWhenHiddenMidRefresh() async throws {
        let server = StubServer()
        serve(server)
        // The first token is for checking who's signed in; the second is for the first request, the first project's runs.
        let tokens = HeldTokens(server.id, holdAt: 2)
        let engine = PipelinesEngine(client: server.client(tokens: tokens), configuration: PipelinesEngine.Configuration(pipelines: [web, release])) { _ in }
        await engine.start()
        defer { Task { await engine.stop() } }
        await engine.setActive(true)
        try await waitUntilHeld(tokens)
        await engine.setActive(false)
        await tokens.release()
        // The request under way finishes, and the refresh stops: any request after it would be counted by then.
        try await waitUntil("the refresh to stop") {
            let refreshing = await engine.currentSnapshot().isRefreshing
            return !refreshing && !server.requests.isEmpty
        }
        // Not the other project's runs, nor any stages.
        #expect(server.requests.count == 1)
        #expect(await engine.currentSnapshot().refreshedAt == nil)
    }

    @Test func keepsTwoOrganizationsRunsApart() async throws {
        let server = StubServer()
        let contoso = PipelineRef(organization: "contoso", projectId: "p1", projectName: "Shop", definitionId: 31, name: "web CI")
        let fabrikam = PipelineRef(organization: "fabrikam", projectId: "p1", projectName: "Shop", definitionId: 31, name: "web CI")
        for organization in ["contoso", "fabrikam"] {
            server.on("/\(organization)/p1/_apis/build/builds", json: Fixture.list([WorkFixture.build(42, definition: 31, queued: t(-hour))]))
        }
        server.on("/contoso/p1/_apis/build/builds/42/timeline", json: WorkFixture.timeline([WorkFixture.record("s", "Stage", "Build", order: 1)]))
        server.on("/fabrikam/p1/_apis/build/builds/42/timeline", json: WorkFixture.timeline([WorkFixture.record("s", "Stage", "Deploy", order: 1)]))
        let engine = PipelinesEngine(client: server.client(), configuration: PipelinesEngine.Configuration(pipelines: [contoso, fabrikam])) { _ in }
        await engine.refreshNow()
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().statuses.map { $0.stages.map(\.name) } == [["Build"], ["Deploy"]])
        // Each read once: they're finished.
        #expect(server.requests.compactMap(\.url?.path).filter { $0.hasSuffix("/42/timeline") }.count == 2)
    }

    @Test func readsARetriedRunsStagesAgain() async throws {
        let server = StubServer()
        let attempt = Locked(0)
        server.on("/p1/_apis/build/builds") { _ in
            switch attempt.value {
            case 0: return .json(Fixture.list([WorkFixture.build(42, definition: 31, result: "failed", queued: t(-hour), minutes: 3)]))
            case 1: return .json(Fixture.list([WorkFixture.build(42, definition: 31, status: "inProgress", result: nil, queued: t(-hour))]))
            default: return .json(Fixture.list([WorkFixture.build(42, definition: 31, queued: t(-hour), minutes: 20)]))
            }
        }
        server.on("/_apis/build/builds/42/timeline") { _ in
            switch attempt.value {
            case 0: return .json(WorkFixture.timeline([
                WorkFixture.record("s", "Stage", "Test", order: 1, result: "failed"),
                WorkFixture.record("t", "Task", "Run tests", parent: "s", result: "failed", issues: [["type": "error", "message": "Boom"]]),
            ]))
            case 1: return .json(WorkFixture.timeline([WorkFixture.record("s", "Stage", "Test", order: 1, state: "inProgress", result: nil)]))
            default: return .json(WorkFixture.timeline([WorkFixture.record("s", "Stage", "Test", order: 1)]))
            }
        }
        let engine = PipelinesEngine(client: server.client(), configuration: PipelinesEngine.Configuration(pipelines: [web])) { _ in }
        await engine.refreshNow()
        var status = try #require(await engine.currentSnapshot().statuses.first)
        #expect(status.stages.map(\.state) == [.failed])
        #expect(status.failure?.message == "Boom")

        // Run again: the same build, running.
        attempt.set(1)
        await engine.refreshNow()
        status = try #require(await engine.currentSnapshot().statuses.first)
        #expect(status.latest?.status == .running)
        #expect(status.stages.map(\.state) == [.running])
        #expect(status.failure == nil)

        attempt.set(2)
        await engine.refreshNow()
        status = try #require(await engine.currentSnapshot().statuses.first)
        #expect(status.stages.map(\.state) == [.succeeded])
        #expect(status.headline == "Succeeded")
        #expect(server.requests.compactMap(\.url?.path).filter { $0.hasSuffix("/42/timeline") }.count == 3)
    }

    @Test func timelinesThatKeepFailingDontHoldUpTheRest() async throws {
        let server = StubServer()
        let pipelines = (1...7).map {
            PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: $0, name: "CI \($0)")
        }
        server.on("/p1/_apis/build/builds", json: Fixture.list((1...7).map {
            WorkFixture.build(100 + $0, definition: $0, queued: t(-Double($0) * minute))
        }))
        for build in 101...106 {
            server.on("/_apis/build/builds/\(build)/timeline") { _ in .status(500) }
        }
        server.on("/_apis/build/builds/107/timeline", json: WorkFixture.timeline([WorkFixture.record("s", "Stage", "Build", order: 1)]))
        let clock = Locked(t(0))
        let engine = PipelinesEngine(
            client: server.client(), configuration: PipelinesEngine.Configuration(pipelines: pipelines), now: { clock.value }
        ) { _ in }
        func timelines() -> Int { server.requests.compactMap(\.url?.path).filter { $0.hasSuffix("/timeline") }.count }

        await engine.refreshNow()
        #expect(timelines() == 6)
        clock.set(t(60))
        await engine.refreshNow()
        // The seventh, never read, goes before the six that failed.
        #expect(await engine.currentSnapshot().statuses.last?.stages.map(\.name) == ["Build"])
        #expect(await engine.currentSnapshot().problem == nil)
        // A second later, the ones that failed twice wait; only the one that failed once is tried again.
        let before = timelines()
        clock.set(t(61))
        await engine.refreshNow()
        #expect(timelines() - before == 1)
    }

    @Test func aTimelineYouMayNotReadIsntAskedForAgain() async throws {
        let server = StubServer()
        serve(server)
        server.on("/_apis/build/builds/102/timeline") { _ in .status(403) }
        let engine = PipelinesEngine(client: server.client(), configuration: PipelinesEngine.Configuration(pipelines: [api])) { _ in }
        await engine.refreshNow()
        await engine.refreshNow()
        // It's running, so its stages would be read every refresh; but not when you may not read them.
        #expect(server.requests.compactMap(\.url?.path).filter { $0.contains("/102/timeline") }.count == 1)
        #expect(await engine.currentSnapshot().problem == nil)
    }

    @Test func waitsWhenAzureDevOpsAsksToSlowDown() async {
        let server = StubServer()
        server.on("/_apis/build/builds") { _ in .status(429, headers: ["Retry-After": "120"]) }
        let engine = PipelinesEngine(client: server.client(), configuration: PipelinesEngine.Configuration(pipelines: [web])) { _ in }
        await engine.refreshNow()
        guard case .throttled? = await engine.currentSnapshot().problem else {
            Issue.record("Expected to be throttled")
            return
        }
        #expect(await engine.nextDelay() >= 110)
    }

    @Test func readsOnlyWhileSomethingShowsThem() async throws {
        let server = StubServer()
        serve(server, running: false)
        let published = Collected<PipelinesSnapshot>()
        let engine = PipelinesEngine(client: server.client(), configuration: PipelinesEngine.Configuration(pipelines: [web])) {
            published.add($0)
        }
        await engine.start()
        defer { Task { await engine.stop() } }
        // Nothing should happen, so there's nothing to wait for: give it time. A slow machine can't fail this.
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.isEmpty)
        await engine.setActive(true)
        try await published.wait("the pipelines") { $0.hasLoaded && !$0.isRefreshing && !$0.statuses.isEmpty }
        await engine.setActive(false)
        let count = server.requests.count
        await engine.refresh()
        // Nothing should happen, so there's nothing to wait for: give it time. A slow machine can't fail this.
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(server.requests.count == count)
    }

    @Test func findsPipelinesByName() async throws {
        let server = StubServer()
        server.on("/p1/_apis/build/definitions", query: ["name": "*web*"], json: Fixture.list([
            ["id": 31, "name": "web CI", "path": "\\Shop", "project": ["id": "p1", "name": "Shop"]],
        ]))
        let found = try await PipelineSearch.pipelines(containing: "web", organization: Fixture.org, projectId: "p1", client: server.client())
        #expect(found.map(\.name) == ["web CI"])
        #expect(found.first?.folder == "Shop")
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
