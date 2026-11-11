import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// My Work, with My Work Page on: where it shows, what it reads, and your sprint work as its Board takes it.
@MainActor
@Suite struct MyWorkTests {
    /// It goes before Pull Requests in a window only while My Work Page and Pull Request Order are both on, counting
    /// nothing of its own; and it reads the sprint only while a window shows it on screen with + Sprint Tasks and Show
    /// Links, apart from the Sprint page in the same window. Once My Work goes, no window shows it, whether or not the
    /// window says so: back, it reads nothing until one shows it again.
    @Test func myWorkShowsWithItsSettingAndReadsTheSprintOnlyForSprintTasks() async throws {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = AzureDevOpsSource(services: services, summarizer: .withoutModel)
        source.start()
        defer { source.stop() }
        let order = services.pullRequestOrder
        #expect(source.companionPages().isEmpty)
        order.setMyWorkPage(true)
        #expect(source.companionPages()[.azureDevOpsPullRequests]?.map(\.id) == [.azureDevOpsMyWork])
        #expect(source.info(for: .azureDevOpsMyWork)?.title == "My Work")
        #expect(source.segment(for: .azureDevOpsMyWork).count == 0)

        let sprint = try #require(source.sprint)
        let window = SectionViewer(.window, id: "7")
        source.sectionVisibilityChanged(.azureDevOpsMyWork, isShowing: true, by: window)
        #expect(!sprint.isShowing)
        source.settings.myWorkShows = .sprintTasks
        try await settle { sprint.isShowing }
        services.links.setOn(false)
        try await settle { !sprint.isShowing }
        services.links.setOn(true)
        try await settle { sprint.isShowing }
        source.sectionVisibilityChanged(.azureDevOpsMyWork, isShowing: false, by: window)
        #expect(!sprint.isShowing)

        source.sectionVisibilityChanged(.azureDevOpsMyWork, isShowing: true, by: window)
        source.sectionVisibilityChanged(.azureDevOpsSprint, isShowing: true, by: window)
        source.sectionVisibilityChanged(.azureDevOpsMyWork, isShowing: false, by: window)
        #expect(sprint.isShowing)
        source.sectionVisibilityChanged(.azureDevOpsSprint, isShowing: false, by: window)
        #expect(!sprint.isShowing)

        for turnOff in [{ order.setMyWorkPage(false) }, { order.setOn(false) }] {
            source.sectionVisibilityChanged(.azureDevOpsMyWork, isShowing: true, by: window)
            #expect(sprint.isShowing)
            turnOff()
            #expect(source.companionPages().isEmpty)
            try await settle { !sprint.isShowing }
            order.setMyWorkPage(true)
            order.setOn(true)
            await settled()
            #expect(!sprint.isShowing)
        }
    }

    /// Your work is what the sprint counts as yours left, in its order, each with its story, how far along it is, what Show
    /// Links links it to of pull requests, what those are, and whether Copilot works on it.
    @Test func yourSprintWorkHasItsStoryAndWhatItsPullRequestsAre() {
        let board = DemoData.sprintBoard(now: Date())
        func workItem(_ id: Int) -> ItemRef { .workItem(organization: "contoso", id: id) }
        func pullRequest(_ number: Int, _ status: PullRequest.Status = .active, by author: String = "Sam Rivera") -> PullRequest {
            PullRequest(
                key: PRKey("contoso", number), title: "Change \(number)", status: status, author: Person(id: author, name: author),
                createdAt: Date(), projectId: "p", projectName: "Storefront", repositoryId: "r", repositoryName: "shop-web"
            )
        }
        let github = ItemRef.gitHubPullRequest(repository: "contoso/shop-web", number: 12)
        let links: [ItemRef: [ItemRef]] = [
            workItem(5103): [github],
            workItem(5104): [.pullRequest(organization: "contoso", number: 4120), workItem(5101)],
            workItem(5112): [.pullRequest(organization: "contoso", number: 4091)],
            workItem(5150): [4130, 4131, 4132, 4133].map { .pullRequest(organization: "contoso", number: $0) },
        ]
        let known: [PRKey: MyWorkFacts.KnownPullRequest] = [
            PRKey("contoso", 4120): (pullRequest(4120), false),
            PRKey("contoso", 4130): (pullRequest(4130, .completed), false),
            PRKey("contoso", 4131): (pullRequest(4131, .abandoned), false),
            PRKey("contoso", 4132): (pullRequest(4132, by: "Robin Ray"), true),
        ]
        let work = MyWorkFacts.work(in: board, linked: { links[$0] ?? [] }, pullRequest: { known[$0] }, copilotWorks: { $0.id == 5103 })
        #expect(work.map(\.ref) == [5103, 5112, 5104, 5150].map(workItem))
        #expect(work.map(\.story) == [workItem(5101), workItem(5110), workItem(5101), nil])
        #expect(work.map(\.progress) == [.inProgress, .inProgress, .toDo, .toDo])
        #expect(work.map(\.copilotWorks) == [true, false, false, false])
        #expect(work[0].pullRequests == [LinkedPullRequest(ref: github, state: .open(author: nil))])
        #expect(work[1].pullRequests.map(\.state) == [.unknown])
        #expect(work[2].pullRequests == [LinkedPullRequest(ref: .pullRequest(organization: "contoso", number: 4120), state: .open(author: "Sam"))])
        #expect(work[3].pullRequests.map(\.state) == [.merged, .abandoned, .open(author: nil), .unknown])
    }

    /// Your open tasks and bugs outside the sprint are read while My Work shows + Sprint Tasks, for its line, or + All My Tasks,
    /// whose cards have Show Links read their pull requests; with neither, or without Show Links, or once My Work goes, not.
    @Test func itReadsYourWorkOutsideTheSprintForItsLineAndItsCardsForAllMyTasks() async throws {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = AzureDevOpsSource(services: services, summarizer: .withoutModel)
        source.start()
        defer { source.stop() }
        services.pullRequestOrder.setMyWorkPage(true)
        let sprint = try #require(source.sprint)
        let window = SectionViewer(.window, id: "7")
        source.sectionVisibilityChanged(.azureDevOpsMyWork, isShowing: true, by: window)
        #expect(!sprint.readsOutside && !sprint.showsOutside)

        source.settings.myWorkShows = .sprintTasks
        try await settle { sprint.readsOutside }
        #expect(!sprint.showsOutside)
        source.settings.myWorkShows = .allTasks
        try await settle { sprint.showsOutside }
        #expect(sprint.readsOutside && sprint.isShowing)
        services.links.setOn(false)
        try await settle { !sprint.readsOutside }
        #expect(!sprint.showsOutside)
        services.links.setOn(true)
        try await settle { sprint.showsOutside }
        source.settings.myWorkShows = .pullRequests
        try await settle { !sprint.readsOutside }
        #expect(!sprint.showsOutside)

        source.settings.myWorkShows = .allTasks
        try await settle { sprint.showsOutside }
        source.sectionVisibilityChanged(.azureDevOpsMyWork, isShowing: false, by: window)
        #expect(!sprint.readsOutside && !sprint.showsOutside)
    }

    /// Your work outside the sprint goes on the Board as the sprint's does: a task with its parent's story, a bug as its own,
    /// with what Show Links links it to.
    @Test func yourWorkOutsideTheSprintHasItsStoryAsTheSprintsDoes() throws {
        let outside = DemoData.outsideWork(now: Date())
        func workItem(_ id: Int) -> ItemRef { .workItem(organization: "contoso", id: id) }
        let links: [ItemRef: [ItemRef]] = [workItem(5181): [.pullRequest(organization: "contoso", number: 4113)]]
        let work = MyWorkFacts.work(outside: outside, linked: { links[$0] ?? [] }, pullRequest: { _ in nil }, copilotWorks: { _ in false })
        #expect(work.map(\.ref) == outside.items.map(\.linkRef))
        #expect(try #require(work.first { $0.ref == workItem(4990) }).story == workItem(4990))
        let task = try #require(work.first { $0.ref == workItem(5181) })
        #expect(task.story == workItem(5180))
        #expect(task.pullRequests.map(\.state) == [.unknown])
        #expect(work.first { $0.ref == workItem(4870) }?.progress == .toDo)
    }

    /// The line under the header counts tasks and bugs apart, in the singular for one, and says when there may be more; with
    /// no sprint going on, how many are open.
    @Test func theLineCountsYourTasksAndBugsOutsideTheSprint() {
        #expect(MyWorkText.outside(tasks: 5, bugs: 1, sprint: "Sprint 42", partial: false) == "5 tasks and 1 bug of yours aren't in Sprint 42.")
        #expect(MyWorkText.outside(tasks: 1, bugs: 0, sprint: "Sprint 42", partial: false) == "1 task of yours isn't in Sprint 42.")
        #expect(MyWorkText.outside(tasks: 0, bugs: 2, sprint: "Sprint 42", partial: true) == "At least 2 bugs of yours aren't in Sprint 42.")
        #expect(MyWorkText.outside(tasks: 0, bugs: 0, sprint: "Sprint 42", partial: false) == "All your open tasks and bugs are in Sprint 42.")
        #expect(MyWorkText.outside(tasks: 5, bugs: 1, sprint: nil, partial: false) == "5 tasks and 1 bug of yours are open.")
        #expect(MyWorkText.outside(tasks: 0, bugs: 1, sprint: nil, partial: false) == "1 bug of yours is open.")
        #expect(MyWorkText.outside(tasks: 0, bugs: 0, sprint: nil, partial: false) == "You have no open tasks or bugs.")
    }

    /// A story or bug of yours in the sprint with no tasks there is a card of its own, but for once tasks of yours under it
    /// outside the sprint show: they're its work then, in its lane. A task in the sprint stays, and a bug outside it, its own
    /// story, takes no card from one.
    @Test func aStoryInTheSprintIsNoCardOnceItsTasksOutsideItShow() {
        func ref(_ id: Int) -> ItemRef { .workItem(organization: "contoso", id: id) }
        func work(_ id: Int, story: Int?) -> SprintWork {
            SprintWork(ref: ref(id), story: story.map(ref), progress: .toDo, pullRequests: [], copilotWorks: false)
        }
        let sprint = [work(1, story: 1), work(2, story: 2), work(3, story: 9), work(4, story: 4)]
        let outside = [work(10, story: 1), work(11, story: 11), work(12, story: 3)]
        #expect(MyWorkFacts.work(sprint: sprint, outside: outside).map(\.ref) == [2, 3, 4, 10, 11, 12].map(ref))
        #expect(MyWorkFacts.work(sprint: sprint, outside: []).map(\.ref) == [1, 2, 3, 4].map(ref))
    }

    /// Show Them takes the Board to the first card of its own of your work outside the sprint, lanes from the top, To start
    /// before In progress, whatever the sprint's work there; else to the first pull request's card that names one.
    @Test func showThemTakesTheBoardToTheFirstCardOfYourWorkOutsideTheSprint() {
        func ref(_ id: Int) -> ItemRef { .workItem(organization: "contoso", id: id) }
        let onBoard = ItemRef.pullRequest(organization: "contoso", number: 4113)
        func work(_ id: Int, _ progress: SprintWork.Progress, story: Int? = nil, linked: [ItemRef] = []) -> SprintWork {
            SprintWork(
                ref: ref(id), story: story.map(ref), progress: progress,
                pullRequests: linked.map { LinkedPullRequest(ref: $0, state: .open(author: nil)) }, copilotWorks: false
            )
        }
        let pullRequests = PullRequestBoard.make(
            stages: [onBoard: StageReading(stage: .inProgress, why: .draft)], missions: [], kinds: PullRequestsByMission.kinds
        )
        func card(sprint: [SprintWork], outside: [SprintWork]) -> ItemRef? {
            let board = pullRequests.withWork(sprint + outside, missions: [], stories: [ref(100)])
            return MyWorkFacts.card(of: Set(outside.map(\.ref)), on: board)
        }
        // Story 100's lane comes before Not in a mission: its In progress before a later lane's To start.
        #expect(card(sprint: [work(1, .toDo, story: 100)], outside: [work(11, .toDo), work(10, .inProgress, story: 100)]) == ref(10))
        #expect(card(sprint: [], outside: [work(10, .inProgress), work(11, .toDo)]) == ref(11))
        #expect(card(sprint: [work(1, .toDo)], outside: [work(12, .toDo, linked: [onBoard])]) == onBoard)
        #expect(card(sprint: [work(1, .toDo)], outside: []) == nil)
    }

    /// A work item's details show while you clicked its card last, though the pull requests' store, which every page and
    /// window shares, shows one since: that pull request's card isn't marked, and while the details cover the Board, ⌘→ and
    /// ⌘← don't move it. A pull request's card clicked last, its details show and the keys move it; with none, a work item's
    /// show, as the Sprint page showed it.
    @Test func theBoardsKeysMoveOnlyAPullRequestWhoseDetailsShow() throws {
        let now = Date()
        let record = try #require(DemoData.records(now: now).first { $0.role == .author })
        let pullRequest = try #require(
            PRClassifier.snapshot(for: record, seenCutoff: .distantPast, dismissedCutoff: .distantPast, now: now)
        )
        let task = WorkItem(
            id: 5112, organization: "contoso", project: "Storefront", type: "Task", title: "Totals", state: "Active",
            category: .inProgress
        )
        let details = PullRequestDetailsStore()
        details.show(pullRequest)

        let taskClicked = MyWorkDetails(workItem: task, showsWorkItem: true, pullRequest: details)
        #expect(taskClicked.workItem == task)
        #expect(taskClicked.pullRequest == nil)
        #expect(taskClicked.pullRequestOnTop == nil)

        let pullRequestClicked = MyWorkDetails(workItem: task, showsWorkItem: false, pullRequest: details)
        #expect(pullRequestClicked.workItem == nil)
        #expect(pullRequestClicked.pullRequest?.key == pullRequest.key)
        #expect(pullRequestClicked.pullRequestOnTop == pullRequest.key.linkRef)

        details.close()
        let fromSprint = MyWorkDetails(workItem: task, showsWorkItem: false, pullRequest: details)
        #expect(fromSprint.workItem == task)
        #expect(fromSprint.pullRequestOnTop == nil)
    }

    /// Once what waits on the main queue ran, as the source's sinks do.
    private func settled() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Waits for the source's work, which runs on the main actor between this test's awaits, for as long as a busy machine
    /// could need (`waitLimit`), failing the test if it doesn't happen.
    private func settle(until done: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !done() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
