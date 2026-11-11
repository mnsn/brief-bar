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
