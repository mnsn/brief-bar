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

    /// Your work is what the sprint counts as yours left, then what it counts as yours done, each in its order, with its
    /// story, how far along it is, what Show Links links it to of pull requests, what those are, and whether Copilot works on
    /// it.
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
        #expect(work.map(\.ref) == [5103, 5112, 5104, 5150, 5102].map(workItem))
        #expect(work.map(\.story) == [workItem(5101), workItem(5110), workItem(5101), nil, workItem(5101)])
        #expect(work.map(\.progress) == [.inProgress, .inProgress, .toDo, .toDo, .completed])
        #expect(work.map(\.copilotWorks) == [true, false, false, false, false])
        #expect(work[0].pullRequests == [LinkedPullRequest(ref: github, state: .open(author: nil))])
        #expect(work[1].pullRequests.map(\.state) == [.unknown])
        #expect(work[2].pullRequests == [LinkedPullRequest(ref: .pullRequest(organization: "contoso", number: 4120), state: .open(author: "Sam"))])
        #expect(work[3].pullRequests.map(\.state) == [.merged, .abandoned, .open(author: nil), .unknown])
        #expect(work[4].pullRequests.isEmpty)
    }

    /// One of your merged pull requests is out once BriefBar follows its pipelines after the merge no more and none failed or
    /// waits; or where it follows none. Until then its card says why it's in Merged, and after that, the work of yours on it
    /// that's still open.
    @Test func aMergedPullRequestIsOutOnceBriefBarFollowsItsPipelinesNoMore() throws {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let demo = try #require(DemoData.records(now: now).first { $0.pullRequest.status == .completed })
        func merged(at minutes: Double, _ runs: [(PipelineRun.Status, PipelineStage?)]?, following: Bool = false) -> PRRecord {
            var record = demo
            record.pullRequest.closedAt = ago(minutes)
            record.pullRequest.mergeCommit = "m1"
            record.merge = runs.map { runs in
                MergePipelines(
                    pullRequest: demo.id, title: "Badges", targetBranch: "main", mergedAt: ago(minutes), url: demo.pullRequest.webURL,
                    pipelines: runs.enumerated().map { index, run in
                        let (status, stage) = run
                        let pipeline = PipelineRef(
                            organization: "contoso", projectId: "p", projectName: "Storefront", definitionId: index, name: "Pipeline \(index)"
                        )
                        let latest = PipelineRun(
                            id: index, organization: "contoso", projectName: "Storefront", number: "1", status: status, trigger: .push,
                            branch: "main", queuedAt: ago(minutes), startedAt: ago(minutes), finishedAt: status.isFinished ? ago(1) : nil
                        )
                        return PipelineStatus(pipeline: pipeline, runs: [latest], stages: stage.map { [$0] } ?? [])
                    },
                    isFollowing: following
                )
            }
            return record
        }
        func out(_ record: PRRecord, follows: Bool = true) -> Bool {
            MyWorkFacts.isOut(record, followsMerges: follows, now: now)
        }
        func held(_ record: PRRecord, open: [String] = []) -> String? {
            MyWorkFacts.held(record, open: open, followsMerges: true, now: now)
        }
        let production = PipelineStage(id: "s1", name: "Production", state: .waiting)

        // Its pipelines run, wait or failed: Merged, saying why but for a failure, which its mark says.
        let running = merged(at: 40, [(.succeeded, nil), (.running, nil)], following: true)
        #expect(!out(running))
        #expect(held(running) == "1 pipeline running")
        let waiting = merged(at: 40, [(.running, production)], following: true)
        #expect(held(waiting) == "Production waits for approval")
        let failed = merged(at: 90, [(.failed, nil)])
        #expect(!out(failed))
        #expect(held(failed) == nil)
        #expect(held(failed, open: ["Task 5112"]) == "Task 5112 still open")
        // They passed, but more may start: still Merged, rather than back to it from Completed.
        let passing = merged(at: 40, [(.succeeded, nil)], following: true)
        #expect(!out(passing))
        #expect(held(passing, open: ["Task 5112", "Bug 5110"]) == "Its pipelines finished · more may start · Task 5112, Bug 5110 still open")
        // No run yet: for half an hour after the merge.
        #expect(held(merged(at: 10, nil)) == "No pipeline has started yet")
        #expect(out(merged(at: 31, nil)))

        // Out: they passed, or one was canceled, and BriefBar follows them no more; or it follows none.
        #expect(out(merged(at: 90, [(.succeeded, nil), (.succeeded, nil)])))
        #expect(out(merged(at: 90, [(.succeeded, nil), (.canceled, nil)])))
        #expect(held(merged(at: 90, [(.succeeded, nil)])) == nil)
        #expect(out(running, follows: false))
        #expect(MyWorkFacts.held(running, open: [], followsMerges: false, now: now) == nil)
        var open = running
        open.pullRequest.status = .active
        #expect(out(open))
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
