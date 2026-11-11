import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsCore

/// Which stories a pull request is for (§7.4.2): by each linked work item's own type, never its parent's, never guessed.
@Suite struct WorkItemStoriesTests {
    static let organization = "contoso"
    static let pullRequest = PRKey(organization, 4101)

    static func item(
        _ id: Int, _ type: String, parent: Int? = nil, rank: Double? = nil, project: String = "Storefront", organization: String = organization
    ) -> WorkItem {
        WorkItem(
            id: id, organization: organization, project: project, type: type, title: "\(type) \(id)", state: "Active",
            category: .inProgress, parentId: parent, rank: rank
        )
    }

    static func ref(_ id: Int) -> ItemRef { .workItem(organization: organization, id: id) }

    static let board = SprintBoard(
        team: TeamRef(organization: "Contoso", projectId: "p1", projectName: "Storefront", id: "t1", name: "Storefront Team"),
        sprint: Sprint(id: "s1", name: "Sprint 42", path: "Storefront\\Sprint 42", start: nil, finish: nil),
        rows: [
            SprintBoard.Row(parent: item(5101, "User Story", rank: 1), tasks: [
                item(5102, "Task", parent: 5101, rank: 1),
                // Read with the sprint, without its parent.
                item(5103, "Task", rank: 2),
            ]),
            // A bug the sprint puts under a story, as a team that tracks bugs as tasks does; and a task moved to another
            // story after the sprint read its links.
            SprintBoard.Row(parent: item(5110, "User Story", rank: 2), tasks: [
                item(5111, "Bug", parent: 5110, rank: 3), item(5112, "Task", parent: 5101, rank: 5),
            ]),
            // A story the board shows under another, as a team that nests them does.
            SprintBoard.Row(parent: item(5120, "User Story", rank: 3), tasks: [item(5121, "User Story", parent: 5120, rank: 4)]),
        ],
        me: "me", taskTypes: ["Task", "Bug"], portfolioTypes: ["Feature", "Epic", "Initiative"]
    )

    @Test func aTaskGivesItsParentWithItsPlaceInTheBacklog() {
        let stories = WorkItemStories(workItems: [Self.item(5102, "Task", parent: 5101, rank: 4), Self.item(5101, "User Story")], board: nil)
        #expect(stories.stories(of: Self.pullRequest, workItems: [5102]) == [
            OrderStory(ref: Self.ref(5101), type: "User Story", task: Self.ref(5102), rank: 4),
        ])
        // Its parent not read yet: the story, by its number, without its type.
        let unread = WorkItemStories(workItems: [Self.item(5102, "Task", parent: 5101, rank: 4)], board: nil)
        #expect(unread.stories(of: Self.pullRequest, workItems: [5102]) == [
            OrderStory(ref: Self.ref(5101), type: nil, task: Self.ref(5102), rank: 4),
        ])
        // A task with no parent: no story.
        let orphan = WorkItemStories(workItems: [Self.item(5150, "Task")], board: nil)
        #expect(orphan.stories(of: Self.pullRequest, workItems: [5150]).isEmpty)
    }

    @Test func aFeatureOrAnEpicGivesNoneAndAnythingElseIsAStoryItself() {
        let items = [
            Self.item(5001, "Feature"), Self.item(5002, "Epic"), Self.item(5101, "User Story", parent: 5001),
            Self.item(5120, "Product Backlog Item"), Self.item(5130, "Requirement"), Self.item(5140, "Issue"), Self.item(5160, "Bug"),
        ]
        let stories = WorkItemStories(workItems: items, board: nil)
        for id in [5001, 5002] {
            #expect(stories.stories(of: Self.pullRequest, workItems: [id]).isEmpty, "\(id)")
        }
        for item in items.dropFirst(2) {
            // Its own type decides: never its parent's, a feature here.
            #expect(stories.stories(of: Self.pullRequest, workItems: [item.id]) == [OrderStory(ref: Self.ref(item.id), type: item.type)])
        }
    }

    @Test func oneWhoseTypeIsntReadYetGivesNoneUntilItIs() throws {
        let stories = WorkItemStories(workItems: [], board: nil)
        #expect(stories.stories(of: Self.pullRequest, workItems: [5102]).isEmpty)
        #expect(stories.parents(ofTasksIn: [WorkItemKey(Self.organization, 5102)]).isEmpty)
        // One read without its type: the same, never a story itself.
        let dto = try JSONDecoder().decode(
            ADOWorkItem.self, from: Data(#"{"id": 5102, "fields": {"System.Title": "Round coupon totals", "System.Parent": 5101}}"#.utf8)
        )
        let untyped = WorkItem(organization: Self.organization, project: "Storefront", dto)
        #expect(untyped.type == WorkItem.untyped && untyped.parentId == 5101)
        let unknown = WorkItemStories(workItems: [untyped, Self.item(5160, " ")], board: nil)
        #expect(unknown.stories(of: Self.pullRequest, workItems: [5102, 5160]).isEmpty)
        #expect(unknown.parents(ofTasksIn: [WorkItemKey(Self.organization, 5102)]).isEmpty)
    }

    @Test func theTeamsBacklogConfigurationDecidesInItsProjectAndTheSprintsBoardPlacesTasks() {
        let stories = WorkItemStories(workItems: Self.board.rows.flatMap { [$0.parent!] + $0.tasks } + [
            // In the team's project: an initiative is a portfolio backlog's, and a bug a task.
            Self.item(5003, "Initiative"), Self.item(5170, "Bug", parent: 5101, rank: 2),
            // In another project, as every process has them: a bug is a story, and an initiative too.
            Self.item(5180, "Bug", parent: 5101, project: "Payments"), Self.item(5004, "Initiative", project: "Payments"),
        ], board: Self.board)
        #expect(stories.stories(of: Self.pullRequest, workItems: [5111]) == [
            OrderStory(ref: Self.ref(5110), type: "User Story", task: Self.ref(5111), rank: 3),
        ])
        #expect(stories.stories(of: Self.pullRequest, workItems: [5003]).isEmpty)
        #expect(stories.stories(of: Self.pullRequest, workItems: [5170]) == [
            OrderStory(ref: Self.ref(5101), type: "User Story", task: Self.ref(5170), rank: 2),
        ])
        #expect(stories.stories(of: Self.pullRequest, workItems: [5180]) == [OrderStory(ref: Self.ref(5180), type: "Bug")])
        #expect(stories.stories(of: Self.pullRequest, workItems: [5004]) == [OrderStory(ref: Self.ref(5004), type: "Initiative")])
        // The board says which story a task is under, when its parent wasn't read; never what a work item is: a story it
        // shows under another is a story itself.
        #expect(stories.stories(of: Self.pullRequest, workItems: [5103]) == [
            OrderStory(ref: Self.ref(5101), type: "User Story", task: Self.ref(5103), rank: 2),
        ])
        // Its parent, read with it, wins over the board's links, which may be older.
        #expect(stories.stories(of: Self.pullRequest, workItems: [5112]) == [
            OrderStory(ref: Self.ref(5101), type: "User Story", task: Self.ref(5112), rank: 5),
        ])
        #expect(stories.stories(of: Self.pullRequest, workItems: [5121]) == [OrderStory(ref: Self.ref(5121), type: "User Story")])
        #expect(stories.parents(ofTasksIn: [WorkItemKey(Self.organization, 5121)]).isEmpty)
    }

    /// With no sprint today, the task types your work outside the sprint was read with decide in the team's project, as My
    /// Work's cards take them: a bug tracked as a task, or a task of the team's own type, gives its parent. Elsewhere, and
    /// without them, as every process has them.
    @Test func withNoSprintTheTypesYourWorkOutsideItWasReadWithDecideInItsProject() {
        let items = [
            Self.item(5101, "User Story"), Self.item(5170, "Bug", parent: 5101), Self.item(5171, "Dev Task", parent: 5101),
            Self.item(5180, "Bug", parent: 5101, project: "Payments"),
        ]
        let outside = OutsideWork(items: [Self.item(5170, "Bug", parent: 5101)], taskTypes: ["Task", "Bug", "Dev Task"])
        let stories = WorkItemStories(workItems: items, board: nil, outside: outside)
        for id in [5170, 5171] {
            #expect(stories.stories(of: Self.pullRequest, workItems: [id]) == [
                OrderStory(ref: Self.ref(5101), type: "User Story", task: Self.ref(id), rank: nil),
            ])
        }
        #expect(stories.stories(of: Self.pullRequest, workItems: [5180]) == [OrderStory(ref: Self.ref(5180), type: "Bug")])
        let standard = WorkItemStories(workItems: items, board: nil)
        #expect(standard.stories(of: Self.pullRequest, workItems: [5170]) == [OrderStory(ref: Self.ref(5170), type: "Bug")])
        #expect(standard.stories(of: Self.pullRequest, workItems: [5171]) == [OrderStory(ref: Self.ref(5171), type: "Dev Task")])
    }

    @Test func aPullRequestIsForEachStoryOnceWithItsTaskThatComesFirst() {
        let stories = WorkItemStories(workItems: [
            Self.item(5101, "User Story"), Self.item(5102, "Task", parent: 5101, rank: 5), Self.item(5103, "Task", parent: 5101, rank: 2),
            Self.item(5104, "Task", parent: 5101), Self.item(5120, "User Story"), Self.item(5122, "Task", parent: 5120, rank: 1),
        ], board: nil)
        // Linked to the story itself and to its tasks: the story once, at its task that comes first in the backlog.
        #expect(stories.stories(of: Self.pullRequest, workItems: [5104, 5101, 5102, 5103, 5122]) == [
            OrderStory(ref: Self.ref(5101), type: "User Story", task: Self.ref(5103), rank: 2),
            OrderStory(ref: Self.ref(5120), type: "User Story", task: Self.ref(5122), rank: 1),
        ])
        #expect(stories.stories(of: Self.pullRequest, workItems: [5101, 5104]) == [
            OrderStory(ref: Self.ref(5101), type: "User Story", task: Self.ref(5104), rank: nil),
        ])
    }

    @Test func theParentsToReadAreTheTasksStoriesWhetherReadOrNot() {
        let stories = WorkItemStories(workItems: [
            Self.item(5102, "Task", parent: 5101), Self.item(5122, "Task", parent: 5120), Self.item(5120, "User Story"),
            Self.item(5160, "User Story", parent: 5001), Self.item(5150, "Task"),
        ], board: nil)
        let linked = Set([5102, 5122, 5160, 5150, 5199].map { WorkItemKey(Self.organization, $0) })
        // A story's parent, a feature, isn't one.
        #expect(stories.parents(ofTasksIn: linked) == [WorkItemKey(Self.organization, 5101), WorkItemKey(Self.organization, 5120)])
    }

    @Test func theDemosStoryIsForItsPullRequestsOutsideTheSprint() throws {
        let links = DemoData.workLinks()
        let board = DemoData.sprintBoard()
        let stories = WorkItemStories(
            workItems: board.rows.flatMap { ($0.parent.map { [$0] } ?? []) + $0.tasks } + Array(links.workItems.values) + Array(links.parents.values),
            board: board
        )
        var byStory: [ItemRef: [Int]] = [:]
        for (key, ids) in links.workItemsOfPullRequests {
            for story in stories.stories(of: key, workItems: ids) { byStory[story.ref, default: []].append(key.number) }
        }
        let story = try #require(byStory.first { $0.value.count >= 3 })
        #expect(links.parents[WorkItemKey(Self.organization, story.key.number ?? 0)] != nil)
        #expect(!board.rows.contains { $0.parent?.id == story.key.number })
    }
}
